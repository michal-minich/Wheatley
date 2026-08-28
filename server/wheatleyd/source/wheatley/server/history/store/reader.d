module wheatley.server.history.store.reader;

import std.algorithm : endsWith, sort;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isDir, isFile, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName;
import std.string : split, strip;

import wheatley.common.json.read : Json;
import wheatley.common.api.reasoning : parseReasoningMode;
import wheatley.server.history.documents.profile_auto_memory_types :
    SessionAutoMemoryMessage;
import wheatley.server.history.store.json :
    jsonLong,
    jsonFieldJson,
    jsonText,
    objectField,
    valueOr;
import wheatley.server.history.store.locations : HistoryStoreLocations;
import wheatley.server.history.store.markdown : readTurnMarkdown;
import wheatley.server.history.store.paths :
    errorsJsonPath,
    isoDate,
    piSessionJsonlPath,
    sessionRootFromTurnRoot,
    sessionStartFromPath,
    toolsJsonPath,
    turnStartFromFolder;
import wheatley.server.history.store.tool_json :
    toolEventCount,
    turnToolArray;
import wheatley.server.history.store.types :
    SessionMetadata,
    StoredTurn,
    TurnText;

package(wheatley.server.history) final class HistoryStoreReader
{
    private HistoryStoreLocations locations;

    this(HistoryStoreLocations locations)
    {
        this.locations = locations;
    }

    bool profileExists(string profileId)
    {
        auto root = locations.profileRoot(profileId);
        return exists(root) && isDir(root);
    }

    string[] listProfiles()
    {
        string[] profiles;
        if (!exists(locations.profilesRoot)) return profiles;
        foreach (entry; dirEntries(locations.profilesRoot, SpanMode.shallow)) {
            if (entry.isDir) profiles ~= baseName(entry.name);
        }
        sort(profiles);
        return profiles;
    }

    StoredTurn[] loadTurns(string profileId, bool includeText)
    {
        StoredTurn[] turns;
        string[] paths;
        if (profileId.length) {
            auto root = buildPath(locations.profileRoot(profileId), "sessions");
            if (!exists(root)) return turns;
            paths = turnJsonPaths(root);
        } else {
            foreach (profile; listProfiles()) {
                auto root = buildPath(locations.profileRoot(profile), "sessions");
                if (exists(root)) paths ~= turnJsonPaths(root);
            }
        }
        sort(paths);
        SessionMetadata[string] sessionCache;
        string[string] modelCache;
        foreach (path; paths) {
            auto turnRoot = dirName(path);
            auto sessionRoot = sessionRootFromTurnRoot(turnRoot);
            auto session = sessionRoot in sessionCache;
            if (session is null) {
                sessionCache[sessionRoot] = loadSessionMetadata(sessionRoot);
                session = sessionRoot in sessionCache;
            }
            auto model = sessionRoot in modelCache;
            if (model is null) {
                modelCache[sessionRoot] = sessionModelName(sessionRoot);
                model = sessionRoot in modelCache;
            }
            turns ~= loadTurn(turnRoot, includeText, *session, *model);
        }
        return turns;
    }

    StoredTurn[] loadSessionTurns(string sessionRoot, bool includeText)
    {
        StoredTurn[] turns;
        auto turnsRoot = buildPath(sessionRoot, "turns");
        if (!exists(turnsRoot)) return turns;
        auto paths = turnJsonPaths(turnsRoot);
        sort(paths);
        auto session = loadSessionMetadata(sessionRoot);
        auto model = sessionModelName(sessionRoot);
        foreach (path; paths)
            turns ~= loadTurn(dirName(path), includeText, session, model);
        return turns;
    }

    string latestSessionRoot(string profileId)
    {
        auto root = buildPath(locations.profileRoot(profileId), "sessions");
        if (!exists(root)) return "";
        auto paths = sessionJsonPaths(root);
        if (!paths.length) return "";
        sort(paths);
        return dirName(paths[$ - 1]);
    }

    SessionMetadata loadSessionMetadata(string sessionRoot)
    {
        auto path = buildPath(sessionRoot, "session.json");
        return exists(path)
            ? sessionMetadata(sessionRoot, parseJSON(readText(path)))
            : SessionMetadata();
    }

    StoredTurn loadTurn(string turnRoot, bool includeText)
    {
        auto sessionRoot = sessionRootFromTurnRoot(turnRoot);
        return loadTurn(
            turnRoot,
            includeText,
            loadSessionMetadata(sessionRoot),
            sessionModelName(sessionRoot),
        );
    }

    private StoredTurn loadTurn(
        string turnRoot,
        bool includeText,
        SessionMetadata session,
        string sessionModel,
    )
    {
        auto payload = parseJSON(readText(buildPath(turnRoot, "turn.json")));
        auto text = includeText ? readTurnMarkdown(buildPath(turnRoot, "turn.md")) : TurnText();
        auto toolsPath = toolsJsonPath(turnRoot);
        auto language = jsonText(payload, "language");
        if (!language.length) language = session.language;
        auto userImage = objectField(payload, "user_image");
        auto userImageFilename = jsonText(userImage, "filename");
        return StoredTurn(
            valueOr(jsonText(payload, "id"), locations.turnIdFromTurnRoot(turnRoot)),
            valueOr(jsonText(payload, "profile"), locations.profileIdFromTurnRoot(turnRoot)),
            jsonText(payload, "device_id"),
            jsonText(payload, "source"),
            turnStatus(turnRoot, payload, text),
            valueOr(jsonText(payload, "started_at"), turnStartFromPath(turnRoot)),
            jsonText(payload, "completed_at"),
            valueOr(jsonText(payload, "model_name"), sessionModel),
            language,
            parseReasoningMode(Json.object(payload).text("reasoning_mode")),
            text.prompt,
            text.response,
            turnRoot,
            exists(buildPath(turnRoot, "user.opus")),
            exists(toolsPath),
            activityDurationMs(payload),
            reasoningDurations(payload),
            jsonText(payload, "submission_id"),
            jsonText(payload, "execution_id"),
            jsonFieldJson(payload, "submission", ""),
            userImageFilename.length > 0,
            userImageFilename,
            jsonText(userImage, "media_type"),
            cast(ulong) jsonLong(userImage, "bytes"),
            userImageFilename.length
                ? buildPath(turnRoot, "images", userImageFilename)
                : "",
            branchInherited(payload),
            jsonFieldJson(payload, "metrics", "{}"),
        );
    }

    private bool branchInherited(JSONValue payload)
    {
        auto value = Json.object(payload).opt.boolean("branch_inherited");
        return !value.isNull && value.get;
    }

    private long activityDurationMs(JSONValue payload)
    {
        auto metrics = objectField(payload, "metrics");
        auto turn = objectField(metrics, "turn");
        auto explicitDuration = jsonLong(turn, "activity_ms");
        if (explicitDuration > 0) return explicitDuration;

        auto endpointDuration = jsonLong(turn, "endpoint_to_first_token_ms");
        if (endpointDuration > 0) return endpointDuration;

        auto llm = objectField(metrics, "llm");
        auto total = jsonLong(turn, "total_ms");
        auto generation = jsonLong(llm, "generation_ms");
        if (total > generation && generation > 0) return total - generation;

        auto ttft = jsonLong(llm, "ttft_ms");
        return ttft > 0 ? ttft : -1;
    }

    long toolCount(string turnRoot)
    {
        return toolEventCount(turnRoot);
    }

    SessionAutoMemoryMessage[] normalUserMessages(
        string profileId,
        string sessionRoot,
        string sessionId,
    )
    {
        SessionAutoMemoryMessage[] messages;
        auto turnsRoot = buildPath(sessionRoot, "turns");
        if (!exists(turnsRoot)) return messages;

        auto paths = turnJsonPaths(turnsRoot);
        sort(paths);
        foreach (path; paths) {
            auto turn = loadTurn(dirName(path), true);
            if (turn.profileId != profileId) continue;
            if (turn.source == "memory_consolidation") continue;
            if (turn.branchInherited) continue;
            if (!turn.userText.strip.length) continue;
            messages ~= SessionAutoMemoryMessage(
                sessionId,
                turn.id,
                turn.startedAt,
                turn.userText.strip,
            );
        }
        return messages;
    }


    string[] turnJsonPaths(string root)
    {
        string[] paths;
        foreach (entry; dirEntries(root, SpanMode.depth)) {
            if (entry.isFile && baseName(entry.name) == "turn.json") paths ~= entry.name;
        }
        return paths;
    }

    string[] sessionJsonPaths(string root)
    {
        string[] paths;
        foreach (entry; dirEntries(root, SpanMode.depth)) {
            if (entry.isFile && baseName(entry.name) == "session.json") paths ~= entry.name;
        }
        return paths;
    }

    string latestPiSessionJsonl(string sessionDir, bool includePiSessionNamed = false)
    {
        if (!sessionDir.length || !exists(sessionDir) || !isDir(sessionDir)) return "";
        auto named = buildPath(sessionDir, "pi_session.jsonl");
        if (includePiSessionNamed && exists(named) && isFile(named)) return named;
        string[] candidates;
        foreach (entry; dirEntries(sessionDir, SpanMode.shallow)) {
            if (!entry.isFile) continue;
            auto name = baseName(entry.name);
            if (name == "pi_session.jsonl" || name == "presentation.jsonl") continue;
            if (name.endsWith(".jsonl")) candidates ~= entry.name;
        }
        if (!candidates.length) return "";
        sort(candidates);
        return candidates[$ - 1];
    }

    bool piSessionHasConversation(string sessionRoot)
    {
        auto path = piSessionJsonlPath(sessionRoot);
        if (!exists(path)) return false;
        foreach (line; readText(path).split("\n")) {
            auto clean = line.strip;
            if (!clean.length) continue;
            auto event = parseJSON(clean);
            if (jsonText(event, "type") != "message") continue;
            auto message = objectField(event, "message");
            auto role = jsonText(message, "role").strip;
            if (role == "user" || role == "assistant") return true;
        }
        return false;
    }

    string turnStartFromPath(string turnRoot)
    {
        auto sessionRoot = sessionRootFromTurnRoot(turnRoot);
        auto day = isoDate(sessionStartFromPath(sessionRoot));
        auto parsed = turnStartFromFolder(day, baseName(turnRoot));
        return parsed.length ? parsed : sessionStartFromPath(sessionRoot);
    }

    private SessionMetadata sessionMetadata(string sessionRoot, JSONValue payload)
    {
        auto json = Json.object(payload);
        return SessionMetadata(
            sessionClient(payload),
            json.text("language"),
            json.text("model"),
            parseReasoningMode(json.text("reasoning_mode")),
        );
    }

    private string sessionClient(JSONValue payload)
    {
        auto value = "client" in payload.objectNoRef;
        if (value is null || value.type == JSONType.null_) return "";
        if (value.type == JSONType.string) return value.str;

        enforce(value.type == JSONType.object, "client must be a string or object");
        auto command = "command" in value.objectNoRef;
        if (command is null || command.type == JSONType.null_) return "";
        enforce(command.type == JSONType.string, "client.command must be a string");
        return command.str;
    }

    private string sessionModelName(string sessionRoot)
    {
        auto piModel = piSessionModelId(sessionRoot);
        if (piModel.length) return "pi:" ~ piModel;
        auto path = buildPath(sessionRoot, "session.json");
        if (!exists(path)) return "";
        auto payload = parseJSON(readText(path));
        auto runtime = objectField(payload, "runtime");
        auto engine = jsonText(runtime, "assistant_engine");
        auto pi = objectField(runtime, "pi");
        auto modelName = jsonText(pi, "model_name");
        if (modelName.length) return modelName;
        auto model = jsonText(pi, "model");
        if (engine == "pi" && model.length) return "pi:" ~ model;
        return model;
    }

    private string piSessionModelId(string sessionRoot)
    {
        auto path = piSessionJsonlPath(sessionRoot);
        if (!exists(path)) return "";
        string model;
        foreach (line; readText(path).split("\n")) {
            auto clean = line.strip;
            if (!clean.length) continue;
            auto event = parseJSON(clean);
            if (jsonText(event, "type") == "model_change") {
                auto value = jsonText(event, "modelId");
                if (value.length) model = value;
            }
        }
        return model;
    }

    private string turnStatus(string turnRoot, JSONValue payload, TurnText text)
    {
        auto stored = jsonText(payload, "status");
        if (stored.length) return stored;
        if (exists(errorsJsonPath(turnRoot))) return "failed";
        if (hasJsonField(payload, "pi_exit_status")) return "failed";
        if (jsonText(payload, "source") == "memory_consolidation" && jsonText(payload, "completed_at").length)
            return "completed";
        return text.response.strip.length ? "completed" : "";
    }

    private bool hasJsonField(JSONValue payload, string name)
    {
        if (payload.type != JSONType.object) return false;
        return (name in payload.objectNoRef) !is null;
    }

}

private long[string] reasoningDurations(JSONValue payload)
{
    long[string] durations;
    if (payload.type != JSONType.object) return durations;
    auto metricsField = "metrics" in payload.objectNoRef;
    // Metrics were optional in older, otherwise valid sessions. Inspection
    // and one-time queue migration must not make those sessions unloadable.
    if (metricsField is null || metricsField.type != JSONType.object)
        return durations;
    auto metricsValue = *metricsField;
    auto reasoningField = "reasoning" in metricsValue.objectNoRef;
    if (reasoningField is null) return durations;
    auto reasoning = Json.object(*reasoningField, "metrics.reasoning");
    auto items = reasoning.array("items");
    foreach (item; items.value.array) {
        auto itemJson = Json.object(item);
        auto itemId = itemJson.text("item_id");
        enforce(itemId.length, "Reasoning metric item_id is required");
        auto durationMs = itemJson.integer("duration_ms", 0);
        enforce((itemId in durations) is null, "Duplicate reasoning metric item_id");
        durations[itemId] = durationMs;
    }
    return durations;
}

unittest
{
    assert(reasoningDurations(parseJSON(`{}`)).length == 0);
    assert(reasoningDurations(parseJSON(`{"metrics":null}`)).length == 0);
    assert(reasoningDurations(parseJSON(`{"metrics":"legacy"}`)).length == 0);

    auto durations = reasoningDurations(parseJSON(
        `{"metrics":{"reasoning":{"items":[{"item_id":"reasoning-1","duration_ms":125}]}}}`,
    ));
    assert(durations["reasoning-1"] == 125);
}
