module wheatley.server.history.store.views;

import std.algorithm : canFind, sort;
import std.array : appender;
import std.exception : enforce;
import std.file : exists, readText;
import std.path : buildPath, dirName;
import std.string : endsWith, splitLines, strip;
import std.json : JSONType, JSONValue, parseJSON;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.api.reasoning : reasoningModeText;
import wheatley.common.api.text_turn : textTurnMetricsJson;
import wheatley.server.history.store.turn_metrics : inspectionMetrics;
import wheatley.server.history.store.locations : HistoryStoreLocations;
import wheatley.server.history.store.model_input : ModelInput, loadModelInput;
import wheatley.server.history.store.llm_requests : loadLlmRequests;
import wheatley.server.history.store.paths : piSessionJsonlPath;
import wheatley.server.history.store.paths : toolsJsonPath;
import wheatley.server.history.store.tool_json : turnToolArray;
import wheatley.server.history.store.pi_session :
    PiTurnTranscript,
    loadPiSessionTranscript;
import wheatley.server.history.store.reader : HistoryStoreReader;
import wheatley.server.history.store.types : StoredTurn;
import wheatley.server.tools.progress : loadToolProgressMessages, toolProgress;
import wheatley.common.api.generated_image :
    GeneratedImageArtifact,
    generatedImageArtifactFromJson,
    generatedImageArtifactJson;
import wheatley.common.json.read : Json;
import wheatley.common.api.conversation_events : conversationEventFromJson;
import wheatley.common.conversation.events : ConversationEventKind;

package(wheatley.server.history) final class HistoryStoreViews
{
    private HistoryStoreLocations locations;
    private HistoryStoreReader reader;
    private string resourcesRoot;

    this(HistoryStoreLocations locations, HistoryStoreReader reader, string resourcesRoot)
    {
        this.locations = locations;
        this.reader = reader;
        this.resourcesRoot = resourcesRoot;
    }

    string profilesJson()
    {
        auto output = appender!string;
        output.put("[");
        foreach (index, profileId; reader.listProfiles()) {
            if (index) output.put(",");
            output.put(jsonObject([
                jsonStringField("profile_id", profileId),
            ]));
        }
        output.put("]");
        return output.data;
    }

    string sessionTurnsJson(
        string sessionRoot,
        GeneratedImageArtifact[] sessionImages,
    )
    {
        auto turnsRoot = buildPath(sessionRoot, "turns");
        StoredTurn[] turns;
        if (exists(turnsRoot)) {
            foreach (path; reader.turnJsonPaths(turnsRoot)) {
                auto turn = reader.loadTurn(dirName(path), true);
                if (turn.source == "memory_consolidation") continue;
                turns ~= turn;
            }
        }
        if (!turns.length) return "[]";
        sort!((a, b) => a.startedAt < b.startedAt)(turns);
        auto pi = loadPiSessionTranscript(piSessionJsonlPath(sessionRoot));
        auto output = appender!string;
        output.put("[");
        foreach (index, turn; turns) {
            if (index) output.put(",");
            output.put(sessionTurnJson(turn, pi.turn(turn), sessionImages, index == 0));
        }
        output.put("]");
        return output.data;
    }

    private string sessionTurnJson(
        StoredTurn turn,
        PiTurnTranscript transcript,
        GeneratedImageArtifact[] sessionImages,
        bool showModelContext,
    )
    {
        auto streamingAssistantItemId = assistantStreamingItemId(turn);
        return jsonObject([
            jsonStringField("turn_id", turn.id),
            jsonStringField("submission_id", turn.submissionId),
            jsonStringField("started_at", turn.startedAt),
            jsonStringField("completed_at", turn.completedAt),
            jsonStringField("model_name", turn.modelName),
            jsonLongField("activity_duration_ms", turn.activityDurationMs >= 0 ? turn.activityDurationMs : 0),
            jsonRawField(
                "metrics",
                textTurnMetricsJson(inspectionMetrics(
                    turn.metricsJson,
                    turn.startedAt,
                    turn.completedAt,
                )),
            ),
            jsonStringField("user_text", turn.userText),
            jsonBoolField("scheduled_task", turn.source == "scheduled_task"),
            jsonStringField("reasoning_mode", reasoningModeText(turn.reasoningMode)),
            jsonBoolField("processing", turn.status == "pending" || turn.status == "running"),
            jsonBoolField("assistant_streaming", streamingAssistantItemId.length > 0),
            jsonStringField("assistant_streaming_item_id", streamingAssistantItemId),
            jsonBoolField("has_user_audio", turn.hasUserAudio),
            turn.hasUserImage ? jsonRawField("user_image", jsonObject([
                jsonStringField("filename", turn.userImageFilename),
                jsonStringField("media_type", turn.userImageMediaType),
            ])) : "",
            jsonRawField(
                "items",
                presentationItemsJson(turn, transcript, sessionImages, showModelContext),
            ),
        ]);
    }

    private string assistantStreamingItemId(StoredTurn turn)
    {
        if (turn.status != "pending" && turn.status != "running") return "";
        auto path = buildPath(turn.turnRoot, "conversation.events.jsonl");
        if (!exists(path)) return "";
        string itemId;
        foreach (line; readText(path).splitLines) {
            if (!line.strip.length) continue;
            auto event = conversationEventFromJson(parseJSON(line));
            if (event.kind != ConversationEventKind.status) continue;
            if (event.status.code == "assistant_item_started")
                itemId = Json.parse(event.status.detailsJson).text("item_id");
            if (event.status.code == "assistant_item_finished") itemId = "";
        }
        return itemId;
    }

    private string presentationItemsJson(
        StoredTurn turn,
        PiTurnTranscript transcript,
        GeneratedImageArtifact[] sessionImages = [],
        bool showModelContext = true,
    )
    {
        auto output = appender!string;
        output.put("[");
        bool hasItem;
        if (showModelContext && hasInspectableModelContext(turn, transcript)) {
            hasItem = true;
            auto messages = loadToolProgressMessages(resourcesRoot, turn.language);
            auto progress = toolProgress("model_context", parseJSON("{}"), messages);
            output.put(jsonObject([
                jsonStringField("kind", "tool"),
                jsonStringField("item_id", "model-context"),
                jsonLongField("call_index", -1),
                jsonStringField("name", "model_context"),
                jsonStringField("stage", "end"),
                jsonStringField("message", progress.displayMessage),
                jsonStringField("spoken_message", ""),
                jsonStringField("status", "succeeded"),
                jsonLongField("duration_ms", 0),
            ]));
        }
        foreach (tool; schedulerTools(turn)) {
            if (hasItem) output.put(",");
            hasItem = true;
            auto json = Json.object(tool);
            auto arguments = json.object("args");
            output.put(jsonObject([
                jsonStringField("kind", "tool"),
                jsonStringField("item_id", json.text("id")),
                jsonLongField("call_index", json.integer("index")),
                jsonStringField("name", json.text("name")),
                jsonStringField("stage", "end"),
                jsonStringField(
                    "message",
                    "Scheduled task: " ~ arguments.opt.textOrEmpty("display_text"),
                ),
                jsonStringField("spoken_message", ""),
                jsonStringField("status", json.boolean("ok") ? "succeeded" : "failed"),
                jsonLongField("duration_ms", json.integer("duration_ms")),
            ]));
        }
        foreach (item; transcript.items) {
            if (item.kind == "tool" && !item.hasResult
                && turn.status != "pending" && turn.status != "running") continue;
            if (hasItem) output.put(",");
            hasItem = true;
            if (item.kind == "reasoning") {
                auto tail = textTail(item.text, 4_096);
                auto storedDuration = item.id in turn.reasoningDurationsMs;
                auto durationMs = storedDuration is null ? item.durationMs : *storedDuration;
                if (turn.activityDurationMs >= 0 && durationMs > turn.activityDurationMs)
                    durationMs = turn.activityDurationMs;
                output.put(jsonObject([
                    jsonStringField("kind", item.kind),
                    jsonStringField("item_id", item.id),
                    jsonStringField("text_tail", tail.text),
                    jsonBoolField("truncated", tail.truncated),
                    jsonLongField("duration_ms", durationMs >= 0 ? durationMs : 0),
                ]));
            } else if (item.kind == "assistant") {
                output.put(jsonObject([
                    jsonStringField("kind", item.kind),
                    jsonStringField("item_id", item.id),
                    jsonStringField("text", item.text),
                    jsonStringField("completed_at", item.timestamp),
                ]));
            } else {
                auto messages = loadToolProgressMessages(resourcesRoot, turn.language);
                auto progress = toolProgress(item.toolName, item.arguments, messages);
                output.put(jsonObject([
                    jsonStringField("kind", item.kind),
                    jsonStringField("item_id", item.id),
                    jsonLongField("call_index", item.callIndex + schedulerTools(turn).length),
                    jsonStringField("name", item.toolName),
                    jsonStringField("stage", "end"),
                    jsonStringField("message", progress.displayMessage),
                    jsonStringField("spoken_message", progress.spokenMessage),
                    jsonStringField(
                        "status",
                        !item.hasResult ? "running" : item.isError ? "failed" : "succeeded",
                    ),
                    jsonLongField("duration_ms", item.durationMs >= 0 ? item.durationMs : 0),
                ]));
                if ((item.toolName == "generate_image" || item.toolName == "capture_screen")
                    && item.details.type == JSONType.object
                    && (Json.object(item.details).opt.textOrEmpty("kind") == "generated_image"
                        || Json.object(item.details).opt.textOrEmpty("kind") == "screen_capture")) {
                    output.put(",");
                    output.put(generatedImageArtifactJson(
                        presentationImage(turn, item.details, sessionImages),
                    ));
                }
            }
        }
        output.put("]");
        return output.data;
    }

    private bool hasInspectableModelContext(
        StoredTurn turn,
        PiTurnTranscript transcript,
    )
    {
        auto captured = loadLlmRequests(turn.turnRoot);
        if (captured.type == JSONType.object
            && Json.object(captured).array("requests").value.array.length)
            return true;
        auto stored = loadModelInput(turn.turnRoot);
        if (stored.prompt.length)
            return stored.startingContext;
        if (!transcript.prompt.length || transcript.prompt.strip == turn.userText.strip)
            return false;
        auto recovered = ModelInput(
            transcript.prompt,
            transcript.promptTimestamp.length ? transcript.promptTimestamp : turn.startedAt,
            transcript.workingDirectory,
            transcript.prompt.canFind("# Current User Request"),
            turn.source == "scheduled_task",
        );
        return recovered.startingContext;
    }

    private JSONValue[] schedulerTools(StoredTurn turn)
    {
        auto path = toolsJsonPath(turn.turnRoot);
        if (!exists(path)) return [];
        JSONValue[] output;
        foreach (tool; turnToolArray(parseJSON(readText(path))).array)
            if (Json.object(tool).text("source") == "scheduler") output ~= tool;
        return output;
    }

    private GeneratedImageArtifact presentationImage(
        StoredTurn turn,
        JSONValue details,
        GeneratedImageArtifact[] sessionImages,
    )
    {
        auto artifact = generatedImageArtifactFromJson(Json.object(details));
        if (artifact.kind == "screen_capture" && artifact.modelWidth <= 0) {
            auto stem = artifact.filename.endsWith(".png")
                ? artifact.filename[0 .. $ - 4]
                : artifact.filename;
            auto metadataPath = buildPath(turn.turnRoot, "images", stem ~ ".json");
            if (exists(metadataPath))
                artifact = generatedImageArtifactFromJson(Json.parse(readText(metadataPath)));
        }
        if (artifact.kind == "generated_image") {
            foreach (candidate; sessionImages) {
                if (candidate.path != artifact.path) continue;
                artifact.generatedImageId = candidate.generatedImageId;
                break;
            }
            enforce(artifact.generatedImageId > 0, "Generated image ID could not be resolved");
        }
        return artifact;
    }

    private struct TextTail
    {
        string text;
        bool truncated;
    }

    private TextTail textTail(string text, size_t maxBytes)
    {
        if (text.length <= maxBytes) return TextTail(text.strip, false);
        size_t start = text.length - maxBytes;
        while (start < text.length && (cast(ubyte) text[start] & 0xc0) == 0x80) start++;
        return TextTail(text[start .. $].strip, true);
    }
}

unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import wheatley.server.history.store.model_input : ModelInput, writeModelInput;

    auto view = new HistoryStoreViews(null, null, "");
    StoredTurn failed;
    failed.status = "failed";
    auto transcript = PiTurnTranscript([
        parseJSON(`{
            "type":"message",
            "timestamp":"2026-08-12T11:56:47Z",
            "message":{"role":"assistant","content":[
                {"type":"text","text":"Let me search for that."},
                {"type":"toolCall","id":"bad-search","name":"web_search","arguments":{"queries":["example"]}}
            ]}
        }`),
    ]);

    auto json = view.presentationItemsJson(failed, transcript);
    assert(json.canFind("Let me search for that."));
    assert(!json.canFind("web_search"));

    auto root = buildPath(tempDir(), "wheatley-scheduled-view-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    writeModelInput(
        root,
        ModelInput("Private\n\nTask", "now", "/work", false, true),
    );
    StoredTurn scheduled;
    scheduled.turnRoot = root;
    scheduled.source = "scheduled_task";
    auto scheduledJson = view.presentationItemsJson(scheduled, PiTurnTranscript.init);
    assert(!scheduledJson.canFind("model_context"));

    auto legacyImageDetails = parseJSON(`{
        "item_id":"generated-image:1",
        "kind":"generated_image",
        "filename":"generated-01.png",
        "media_type":"image/png",
        "url":"",
        "path":"profiles/atom/sessions/old/turns/one/images/generated-01.png",
        "sha256":"abc",
        "byte_count":1,
        "width":1,
        "height":1,
        "seed":0,
        "quality":"high",
        "aspect":"square",
        "prompt":"legacy"
    }`);
    auto normalizedImage = generatedImageArtifactFromJson(Json.object(legacyImageDetails));
    normalizedImage.generatedImageId = 1;
    assert(view.presentationImage(
        failed,
        legacyImageDetails,
        [normalizedImage],
    ).generatedImageId == 1);
}
