module wheatley.server.turns.text.pi_events;

import core.time : MonoTime;
import std.algorithm : sort;
import std.algorithm.searching : canFind;
import std.array : Appender, appender;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip, toLower;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.tools.progress : ToolProgress, toolProgress;
import wheatley.server.tools.types : ExecutedTool, ToolCall, ToolResult;
import wheatley.common.conversation.events : ConversationToolEvent;
import wheatley.server.conversation.agent_runtime : AgentContentEvent;
import wheatley.server.conversation.event_stream : ConversationEventStream;
import wheatley.server.turns.text.pi_runtime : safeId;
import wheatley.server.turns.text.pi_compaction : PiCompactionEvent, PiCompactionSink;
import wheatley.server.turns.text.profile_runtime_settings : ProfileRuntimeSettings;
import wheatley.server.turns.text.pi_event_sink : PiWorkerEventSink;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.api.generated_image :
    GeneratedImageArtifact,
    generatedImageArtifactFromJson;

private struct PiToolState
{
    string toolCallId;
    string toolName;
    string startedAt;
    MonoTime startedMono;
    string argumentsJson;
    string presentationJson;
    int callIndex;
    string itemId;
}

struct PiProviderUsage
{
    long inputTokens;
    long outputTokens;
    long cacheReadTokens;
    long cacheWriteTokens;
    long reasoningTokens;
    long totalTokens;
    long latestContextTokens;

    bool available() const
    {
        return totalTokens > 0 || inputTokens > 0 || outputTokens > 0
            || cacheReadTokens > 0 || cacheWriteTokens > 0 || reasoningTokens > 0;
    }
}

final class PiEventCollector : PiWorkerEventSink
{
    private string profileId;
    private ConversationEventStream eventStream;
    private Appender!string rawEvents;
    private Appender!string assistant;
    private Appender!string reasoning;
    private PiToolState[string] activeTools;
    private ExecutedTool[] completedTools;
    private ProfileRuntimeSettings settings;
    private void delegate(ExecutedTool[] tools) toolsChanged;
    private void delegate(AgentContentEvent event) contentChanged;
    private PiCompactionSink compactionChanged;
    private long startedToolCount;
    private long assistantMessageIndex = -1;
    private bool hasFirstAssistantDeltaValue;
    private MonoTime firstAssistantDeltaValue;
    private bool assistantGenerationOpen;
    private MonoTime assistantGenerationStartedMono;
    private long assistantGenerationDurationMsValue;
    private bool hasLatestAssistantStartValue;
    private MonoTime latestAssistantStartValue;
    private string latestAssistantItemId;
    private bool reasoningOpen;
    private string activeReasoningItemId;
    private MonoTime reasoningStartedMono;
    private long[string] reasoningDurationsMs;
    private string[] reasoningItemIds;
    private string[string] toolItemIds;
    private bool compactionOpen;
    private string compactionId;
    private string compactionReason;
    private string compactionStartedAt;
    private MonoTime compactionStartedMono;
    private PiCompactionEvent[] compactionEvents;
    private int publicToolOffset;
    private PiProviderUsage providerUsageValue;
    private string providerErrorValue;

    this(
        string profileId,
        ProfileRuntimeSettings settings,
        ConversationEventStream eventStream = null,
        void delegate(ExecutedTool[] tools) toolsChanged = null,
        void delegate(AgentContentEvent event) contentChanged = null,
        PiCompactionSink compactionChanged = null,
        ExecutedTool[] prefixTools = [],
    )
    {
        this.profileId = profileId;
        this.settings = settings;
        this.eventStream = eventStream;
        this.toolsChanged = toolsChanged;
        this.contentChanged = contentChanged;
        this.compactionChanged = compactionChanged;
        this.completedTools = prefixTools.dup;
        this.publicToolOffset = cast(int) prefixTools.length;
        this.rawEvents = appender!string;
        this.assistant = appender!string;
        this.reasoning = appender!string;
    }

    void handleLine(string line)
    {
        if (!line.length) return;
        rawEvents.put(line);
        rawEvents.put("\n");

        JSONValue event;
        try {
            event = parseJSON(line);
            if (event.type != JSONType.object) throw new Exception("not object");
        } catch (Exception) {
            return;
        }

        auto eventJson = Json.object(event);
        auto type = eventJson.opt.textOrEmpty("type");
        if (type == "compaction_start") {
            beginCompaction(eventJson);
            return;
        }
        if (type == "compaction_end") {
            endCompaction(event, eventJson);
            return;
        }
        if (type == "message_start") {
            auto message = eventJson.object("message");
            auto role = message.opt.text("role");
            if (!role.isNull && role.get == "assistant") assistantMessageIndex++;
            return;
        }
        if (type == "message_end") {
            finishAssistantGeneration(eventJson);
            recordProviderUsage(eventJson);
            recordProviderError(eventJson);
            return;
        }
        if (type == "tool_execution_start") {
            finishReasoning();
            enforce(
                startedToolCount < settings.maxToolCallsPerTurn,
                "Maximum number of tool calls",
            );
            auto toolCallId = eventJson.text("toolCallId");
            auto itemId = toolCallId in toolItemIds;
            enforce(itemId !is null, "Pi tool execution has no presentation item");
            auto state = piToolStartState(event, startedToolCount + publicToolOffset, *itemId, settings);
            activeTools[state.toolCallId] = state;
            startedToolCount++;
            emitToolsChanged();
            emitProfileProgress(
                state,
                toolProgress(state.toolName, eventJson.object("args").value, settings.toolProgress),
            );
            return;
        }
        if (type == "tool_execution_end") {
            auto toolCallId = eventJson.text("toolCallId");
            auto storedState = toolCallId in activeTools;
            enforce(storedState !is null, "Pi completed a tool that was not running");
            auto state = *storedState;
            auto tool = piExecutedTool(event, state);
            completedTools ~= tool;
            activeTools.remove(toolCallId);
            // Persist the completed result before advertising it. Live clients
            // resolve image-search previews from the tool-detail endpoint as
            // soon as they receive this end event.
            emitToolsChanged();
            emitTool(ConversationToolEvent(
                "end",
                state.itemId,
                state.toolName,
                state.callIndex,
                tool.result.ok ? "succeeded" : "failed",
                profileId,
                "",
                false,
                "",
                scheduledTaskPresentation(state, event, tool.result.ok),
                cast(long) (MonoTime.currTime - state.startedMono).total!"msecs",
            ));
            auto artifact = piImageArtifact(event, state);
            if (artifact.itemId.length && eventStream !is null)
                eventStream.artifact(artifact);
            return;
        }
        if (type == "message_update") {
            auto updateType = assistantUpdateType(event);
            if ((updateType == "thinking_delta" || updateType == "text_delta"
                || updateType == "toolcall_delta")
                && assistantUpdateDelta(event).length)
                rememberAssistantGenerationDelta();
            if (updateType == "toolcall_end") {
                finishReasoning();
                auto update = eventJson.object("assistantMessageEvent");
                auto toolCall = update.object("toolCall");
                toolItemIds[toolCall.text("id")] = contentItemId(event);
                return;
            }
            if (updateType == "thinking_start") {
                beginReasoning(contentItemId(event));
                return;
            }
            if (updateType == "thinking_delta") {
                auto delta = assistantUpdateDelta(event);
                if (delta.length) {
                    auto itemId = contentItemId(event);
                    beginReasoning(itemId);
                    reasoning.put(delta);
                    notifyContent("reasoning", "delta", itemId, delta);
                    emitReasoning("delta", itemId, reasoningDurationMs(itemId), delta);
                }
                return;
            }
            if (updateType == "thinking_end") {
                endReasoning(contentItemId(event));
                return;
            }
            if (updateType == "text_start") {
                finishReasoning();
                auto itemId = contentItemId(event);
                rememberAssistantStart(itemId);
                notifyContent("assistant", "start", itemId, "");
                if (eventStream !is null) eventStream.assistantStart(itemId);
                return;
            }
            if (updateType == "text_end") {
                auto itemId = contentItemId(event);
                notifyContent("assistant", "end", itemId, "");
                if (eventStream !is null) eventStream.assistantEnd(itemId);
                return;
            }
            auto delta = textDelta(event);
            if (delta.length) {
                auto itemId = contentItemId(event);
                rememberAssistantStart(itemId);
                assistant.put(delta);
                notifyContent("assistant", "delta", itemId, delta);
                if (eventStream !is null) eventStream.assistantDelta(itemId, delta);
            }
            return;
        }
        if (type == "agent_end") {
            finishAssistantGeneration();
            auto finalText = finalAssistantText(event);
            if (finalText.length && !assistant.data.strip.length) {
                auto itemId = fallbackItemId();
                rememberAssistantStart(itemId);
                rememberAssistantGenerationDelta();
                finishAssistantGeneration();
                assistant.put(finalText);
                notifyContent("assistant", "start", itemId, "");
                if (eventStream !is null) eventStream.assistantStart(itemId);
                notifyContent("assistant", "delta", itemId, finalText);
                notifyContent("assistant", "end", itemId, "");
                if (eventStream !is null) eventStream.assistantDelta(itemId, finalText);
                if (eventStream !is null) eventStream.assistantEnd(itemId);
            }
            auto finalReasoning = finalAssistantReasoning(event);
            if (finalReasoning.length && !reasoning.data.strip.length) {
                auto itemId = fallbackItemId();
                beginReasoning(itemId);
                reasoning.put(finalReasoning);
                notifyContent("reasoning", "delta", itemId, finalReasoning);
                emitReasoning("delta", itemId, reasoningDurationMs(itemId), finalReasoning);
            }
            if (reasoningOpen) endReasoning(activeReasoningItemId);
        }
    }

    string assistantText()
    {
        return assistant.data.strip;
    }

    string rawJsonl()
    {
        return rawEvents.data;
    }

    long toolCount() const
    {
        return startedToolCount;
    }

    ExecutedTool[] tools()
    {
        return currentTools();
    }

    string reasoningMetricsJson()
    {
        if (!reasoningItemIds.length) return "";
        auto items = appender!string;
        items.put("[");
        foreach (index, itemId; reasoningItemIds) {
            if (index) items.put(",");
            items.put(jsonObject([
                jsonStringField("item_id", itemId),
                jsonLongField("duration_ms", reasoningDurationsMs[itemId]),
            ]));
        }
        items.put("]");
        return jsonObject([jsonRawField("items", items.data)]);
    }

    string compactionMetricsJson()
    {
        if (!compactionEvents.length) return "";
        auto output = appender!string;
        output.put("[");
        foreach (index, event; compactionEvents) {
            if (index) output.put(",");
            output.put(event.json());
        }
        output.put("]");
        return output.data;
    }

    PiCompactionEvent[] compactions()
    {
        return compactionEvents;
    }

    PiProviderUsage providerUsage() const
    {
        return providerUsageValue;
    }

    string providerError() const
    {
        return providerErrorValue;
    }

    void finish()
    {
        finishReasoning();
        foreach (state; activeTools) completedTools ~= ExecutedTool(
            "pi-tool:" ~ safeId(state.startedAt) ~ ":" ~ state.callIndex.to!string,
            state.startedAt,
            ToolCall(state.toolName, state.argumentsJson),
            ToolResult(state.toolName, false, jsonObject([
                jsonStringField("text", "Tool execution ended before a result was recorded."),
            ])),
            (MonoTime.currTime - state.startedMono).total!"msecs" / 1_000.0,
            state.callIndex,
            "pi",
            "failed",
        );
        activeTools = null;
        emitToolsChanged();
    }

    bool hasFirstAssistantDelta() const
    {
        return hasFirstAssistantDeltaValue;
    }

    MonoTime firstAssistantDeltaMono() const
    {
        return firstAssistantDeltaValue;
    }

    long assistantGenerationDurationMs() const
    {
        if (!assistantGenerationOpen) return assistantGenerationDurationMsValue;
        return assistantGenerationDurationMsValue
            + cast(long) (MonoTime.currTime - assistantGenerationStartedMono).total!"msecs";
    }

    bool hasLatestAssistantStart() const
    {
        return hasLatestAssistantStartValue;
    }

    MonoTime latestAssistantStartMono() const
    {
        return latestAssistantStartValue;
    }

    private void emitProfileProgress(PiToolState state, ToolProgress progress)
    {
        if (progress.spokenMessage.length) {
            notifyContent("tool", "delta", state.itemId, progress.spokenMessage);
        }
        emitTool(ConversationToolEvent(
            "start",
            state.itemId,
            state.toolName,
            state.callIndex,
            "running",
            profileId,
            progress.displayMessage,
            false,
            progress.spokenMessage,
            state.presentationJson,
        ));
    }

    private void beginCompaction(Json event)
    {
        enforce(!compactionOpen, "Pi opened overlapping compactions");
        compactionOpen = true;
        compactionReason = event.choice!("manual", "threshold", "overflow")("reason");
        compactionStartedAt = nowIso();
        compactionStartedMono = MonoTime.currTime;
        compactionId = "pi-compaction:" ~ safeId(compactionStartedAt);
        if (eventStream !is null) eventStream.status(
            "pi_compaction_started",
            "Compacting context.",
            jsonObject([
                jsonStringField("id", compactionId),
                jsonStringField("reason", compactionReason),
                jsonStringField("started_at", compactionStartedAt),
            ]),
        );
    }

    private void endCompaction(JSONValue raw, Json event)
    {
        enforce(compactionOpen, "Pi ended a compaction that was not running");
        auto completedAt = nowIso();
        auto result = objectField(raw, "result");
        auto aborted = event.opt.boolean("aborted");
        auto retry = event.opt.boolean("willRetry");
        auto error = event.opt.textOrEmpty("errorMessage");
        auto reason = event.choice!("manual", "threshold", "overflow")("reason");
        auto skipped = reason == "manual"
            && (error.canFind("Already compacted") || error.canFind("Nothing to compact"));
        auto item = PiCompactionEvent(
            compactionId,
            reason,
            skipped ? "skipped" : result !is null ? "completed"
                : (!aborted.isNull && aborted.get ? "aborted" : "failed"),
            compactionStartedAt,
            completedAt,
            cast(long) (MonoTime.currTime - compactionStartedMono).total!"msecs",
            result is null ? "" : Json.object(*result).text("summary"),
            error,
            result is null ? 0 : Json.object(*result).integer("tokensBefore", 0),
            result is null ? 0 : Json.object(*result).integer("estimatedTokensAfter", 0),
            !retry.isNull && retry.get,
            resultFieldJson(result, "usage"),
            resultFieldJson(result, "details"),
        );
        long sequence;
        if (!skipped && compactionChanged !is null) sequence = compactionChanged(item);
        compactionEvents ~= item;
        if (eventStream !is null) eventStream.status(
            item.status == "completed" ? "pi_compaction_completed"
                : item.status == "skipped" ? "pi_compaction_skipped"
                : "pi_compaction_failed",
            item.status == "completed" ? "Context compacted · " ~ compactDuration(item.durationMs)
                : item.status == "skipped" ? error
                : "Context compaction failed · " ~ compactDuration(item.durationMs),
            item.json(sequence),
        );
        compactionOpen = false;
        compactionId = "";
        compactionReason = "";
        compactionStartedAt = "";
    }

    private void rememberAssistantGenerationDelta()
    {
        auto now = MonoTime.currTime;
        if (!hasFirstAssistantDeltaValue) {
            hasFirstAssistantDeltaValue = true;
            firstAssistantDeltaValue = now;
        }
        if (assistantGenerationOpen) return;
        assistantGenerationOpen = true;
        assistantGenerationStartedMono = now;
    }

    private void finishAssistantGeneration()
    {
        if (!assistantGenerationOpen) return;
        assistantGenerationDurationMsValue += cast(long) (
            MonoTime.currTime - assistantGenerationStartedMono
        ).total!"msecs";
        assistantGenerationOpen = false;
    }

    private void finishAssistantGeneration(Json event)
    {
        auto message = event.opt.object("message");
        if (message.isNull || message.get.opt.textOrEmpty("role") != "assistant") return;
        finishAssistantGeneration();
    }

    private void rememberAssistantStart(string itemId)
    {
        if (hasLatestAssistantStartValue && latestAssistantItemId == itemId) return;
        hasLatestAssistantStartValue = true;
        latestAssistantStartValue = MonoTime.currTime;
        latestAssistantItemId = itemId;
    }

    private void emitToolsChanged()
    {
        if (toolsChanged is null) return;
        toolsChanged(currentTools());
    }

    private ExecutedTool[] currentTools()
    {
        auto result = completedTools.dup;
        foreach (state; activeTools) result ~= ExecutedTool(
            "pi-tool:" ~ safeId(state.startedAt) ~ ":" ~ state.callIndex.to!string,
            state.startedAt,
            ToolCall(state.toolName, state.argumentsJson),
            ToolResult(state.toolName, true, jsonObject([
                jsonStringField("text", "Tool is running."),
            ])),
            (MonoTime.currTime - state.startedMono).total!"msecs" / 1_000.0,
            state.callIndex,
            "pi",
            "running",
        );
        sort!((left, right) => left.callIndex < right.callIndex)(result);
        return result;
    }

    private void recordProviderUsage(Json event)
    {
        auto message = event.opt.object("message");
        if (message.isNull || message.get.opt.textOrEmpty("role") != "assistant") return;
        auto usage = message.get.opt.object("usage");
        if (usage.isNull) return;
        auto input = optionalNonNegative(usage.get, "input");
        auto output = optionalNonNegative(usage.get, "output");
        auto cacheRead = optionalNonNegative(usage.get, "cacheRead");
        auto cacheWrite = optionalNonNegative(usage.get, "cacheWrite");
        auto reasoning = optionalNonNegative(usage.get, "reasoning");
        auto total = optionalNonNegative(usage.get, "totalTokens");
        providerUsageValue.inputTokens += input;
        providerUsageValue.outputTokens += output;
        providerUsageValue.cacheReadTokens += cacheRead;
        providerUsageValue.cacheWriteTokens += cacheWrite;
        providerUsageValue.reasoningTokens += reasoning;
        providerUsageValue.totalTokens += total > 0
            ? total : input + output + cacheRead + cacheWrite;
        auto context = input + cacheRead + cacheWrite;
        if (context > 0) providerUsageValue.latestContextTokens = context;
    }

    private void recordProviderError(Json event)
    {
        auto message = event.opt.object("message");
        if (message.isNull || message.get.opt.textOrEmpty("role") != "assistant") return;
        if (message.get.opt.textOrEmpty("stopReason") != "error") return;
        auto error = message.get.opt.textOrEmpty("errorMessage").strip;
        if (error.length) providerErrorValue = error;
    }

    private void notifyContent(string kind, string phase, string itemId, string text)
    {
        if (contentChanged !is null)
            contentChanged(AgentContentEvent(kind, phase, itemId, text));
    }

    private void beginReasoning(string itemId)
    {
        if (reasoningOpen) {
            enforce(activeReasoningItemId == itemId, "Pi opened overlapping reasoning items");
            return;
        }
        reasoningOpen = true;
        activeReasoningItemId = itemId;
        reasoningStartedMono = MonoTime.currTime;
        if ((itemId in reasoningDurationsMs) is null) {
            reasoningDurationsMs[itemId] = 0;
            reasoningItemIds ~= itemId;
        }
        notifyContent("reasoning", "start", itemId, "");
        emitReasoning("start", itemId, reasoningDurationMs(itemId), "");
    }

    private void endReasoning(string itemId)
    {
        if (!reasoningOpen) return;
        enforce(activeReasoningItemId == itemId, "Pi closed the wrong reasoning item");
        reasoningDurationsMs[itemId] = reasoningDurationMs(itemId);
        reasoningOpen = false;
        activeReasoningItemId = "";
        notifyContent("reasoning", "end", itemId, "");
        emitReasoning("end", itemId, reasoningDurationsMs[itemId], "");
    }

    private void finishReasoning()
    {
        if (reasoningOpen) endReasoning(activeReasoningItemId);
    }

    private void emitReasoning(string phase, string itemId, long durationMs, string text)
    {
        if (eventStream !is null) eventStream.reasoning(phase, itemId, durationMs, text);
    }

    private void emitTool(ConversationToolEvent event)
    {
        if (eventStream !is null) eventStream.tool(event);
    }

    private long reasoningDurationMs(string itemId)
    {
        auto duration = itemId in reasoningDurationsMs;
        auto completed = duration is null ? 0 : *duration;
        if (!reasoningOpen || activeReasoningItemId != itemId) return completed;
        return completed + cast(long) (MonoTime.currTime - reasoningStartedMono).total!"msecs";
    }

    private string contentItemId(JSONValue event)
    {
        if (assistantMessageIndex < 0) assistantMessageIndex = 0;
        auto update = Json.object(event).object("assistantMessageEvent");
        return "assistant:" ~ assistantMessageIndex.to!string ~ ":"
            ~ update.integer("contentIndex").to!string;
    }

    private string fallbackItemId()
    {
        if (assistantMessageIndex < 0) assistantMessageIndex = 0;
        return "assistant:" ~ assistantMessageIndex.to!string ~ ":0";
    }
}

private long optionalNonNegative(Json json, string name)
{
    auto value = json.opt.integer(name, 0);
    if (value.isNull || value.get < 0) return 0;
    return value.get;
}

private string compactDuration(long durationMs)
{
    auto seconds = (durationMs + 500) / 1_000;
    if (seconds < 60) return seconds.to!string ~ " s";
    return (seconds / 60).to!string ~ " min " ~ (seconds % 60).to!string ~ " s";
}

private string resultFieldJson(JSONValue* result, string name)
{
    if (result is null) return "{}";
    auto value = field(*result, name);
    return value is null ? "{}" : (*value).toString();
}

/** A successful create result carries the durable task identity in its
    extension-only details. Expose that identity as presentation metadata so
    the initiating client can offer immediate user review without making a
    second model-visible tool result or inferring from task-list ordering. */
private string scheduledTaskPresentation(
    PiToolState state,
    JSONValue event,
    bool succeeded,
)
{
    if (!succeeded || state.toolName != "create_scheduled_task")
        return state.presentationJson;
    auto result = field(event, "result");
    if (result is null || result.type != JSONType.object) return state.presentationJson;
    auto details = field(*result, "details");
    if (details is null || details.type != JSONType.object) return state.presentationJson;
    auto task = field(*details, "task");
    if (task is null || task.type != JSONType.object) return state.presentationJson;
    auto id = Json.object(*task).opt.textOrEmpty("id");
    return id.length
        ? jsonObject([jsonStringField("scheduled_task_id", id)])
        : state.presentationJson;
}

private GeneratedImageArtifact piImageArtifact(JSONValue event, PiToolState state)
{
    if (state.toolName != "generate_image" && state.toolName != "capture_screen")
        return GeneratedImageArtifact();
    auto result = field(event, "result");
    if (result is null || result.type != JSONType.object) return GeneratedImageArtifact();
    auto details = field(*result, "details");
    if (details is null || details.type != JSONType.object) return GeneratedImageArtifact();
    auto json = Json.object(*details);
    auto kind = json.opt.textOrEmpty("kind");
    if (kind != "generated_image" && kind != "screen_capture")
        return GeneratedImageArtifact();
    return generatedImageArtifactFromJson(json);
}

private PiToolState piToolStartState(
    JSONValue event,
    long toolCount,
    string itemId,
    ProfileRuntimeSettings settings,
)
{
    auto eventJson = Json.object(event);
    auto toolName = eventJson.text("toolName");
    auto arguments = eventJson.object("args");
    return PiToolState(
        eventJson.text("toolCallId"),
        toolName,
        nowIso(),
        MonoTime.currTime,
        arguments.value.toString(),
        imageGenerationPresentation(toolName, arguments, settings),
        cast(int) toolCount,
        itemId,
    );
}

private string imageGenerationPresentation(
    string toolName,
    Json arguments,
    ProfileRuntimeSettings settings,
)
{
    if (toolName != "generate_image") return "{}";
    auto prompt = arguments.nonEmpty("prompt").strip;
    auto aspect = arguments.choice!("square", "portrait", "landscape")("aspect");
    auto quality = arguments.opt.choice!("low", "medium", "high")("quality");
    auto qualityName = quality.isNull ? "medium" : quality.get;
    auto preset = settings.imageGenerationPresets[qualityName ~ "." ~ aspect];
    enforce(preset.width > 0 && preset.height > 0,
        "Image generation preview preset is unavailable");
    return jsonObject([
        jsonStringField("kind", "generated_image_pending"),
        jsonStringField("prompt", prompt),
        jsonStringField("quality", qualityName),
        jsonStringField("aspect", aspect),
        jsonLongField("width", preset.width),
        jsonLongField("height", preset.height),
    ]);
}

private ExecutedTool piExecutedTool(JSONValue event, PiToolState state)
{
    auto toolName = Json.object(event).text("toolName");
    auto elapsed = MonoTime.currTime - state.startedMono;
    auto ok = !boolField(event, "isError");
    return ExecutedTool(
        "pi-tool:" ~ safeId(state.startedAt) ~ ":" ~ state.callIndex.to!string,
        state.startedAt,
        ToolCall(toolName, state.argumentsJson),
        ToolResult(toolName, ok, piToolResultContentJson(toolName, event)),
        elapsed.total!"msecs" / 1000.0,
        state.callIndex,
        "pi",
    );
}

private string piToolResultContentJson(string toolName, JSONValue event)
{
    auto result = field(event, "result");
    auto rawText = result is null ? "" : piResultText(*result).strip;
    auto processResult = result is null ? JSONValue(null) : processResultObject(toolName, *result, rawText);
    auto hasProcessResult = processResult.type == JSONType.object;
    auto stdoutText = hasProcessResult ? firstString(processResult, ["stdout", "out", "output"]) : "";
    auto stderrText = hasProcessResult ? firstString(processResult, ["stderr", "err"]) : "";
    long exitStatus;
    auto hasExitStatus = hasProcessResult && firstLong(processResult, ["exit_status", "exitCode", "exit_code", "status"], exitStatus);
    return jsonObject([
        jsonStringField("text", hasProcessResult ? "" : rawText),
        jsonLongField("exit_status", hasExitStatus ? exitStatus : 0),
        jsonStringField("stdout", stdoutText),
        jsonStringField("stderr", stderrText),
        jsonRawField("artifacts", "[]"),
        jsonBoolField("truncated", false),
    ]);
}

private string piResultText(JSONValue result)
{
    auto content = field(result, "content");
    if (content is null) return "";
    if (content.type == JSONType.string) return content.str;
    if (content.type != JSONType.array) return "";

    auto output = appender!string;
    foreach (part; content.array) {
        if (part.type == JSONType.string) {
            output.put(part.str);
        } else if (part.type == JSONType.object) {
            auto text = Json.object(part).opt.textOrEmpty("text");
            if (text.length) output.put(text);
        }
    }
    return output.data;
}

private JSONValue processResultObject(string toolName, JSONValue result, string extractedText)
{
    if (looksProcessShaped(toolName, result)) return result;

    auto content = field(result, "content");
    if (content !is null) {
        if (looksProcessShaped(toolName, *content)) return *content;
        if (content.type == JSONType.array) {
            foreach (part; content.array) {
                if (looksProcessShaped(toolName, part)) return part;
                string text = "";
                if (part.type == JSONType.object) {
                    text = Json.object(part).opt.textOrEmpty("text");
                }
                auto parsedPart = parseJsonObject(text);
                if (looksProcessShaped(toolName, parsedPart)) return parsedPart;
            }
        }
    }

    auto parsed = parseJsonObject(extractedText);
    return looksProcessShaped(toolName, parsed) ? parsed : JSONValue(null);
}

private bool looksProcessShaped(string toolName, JSONValue value)
{
    if (value.type != JSONType.object) return false;
    if (field(value, "stdout") !is null || field(value, "stderr") !is null) return true;
    if (field(value, "exit_status") !is null || field(value, "exitCode") !is null || field(value, "exit_code") !is null) return true;
    auto lowerTool = toolName.toLower;
    if (lowerTool == "bash" || lowerTool.canFind("python")) {
        return field(value, "output") !is null && (field(value, "status") !is null || field(value, "code") !is null);
    }
    return false;
}

private JSONValue parseJsonObject(string value)
{
    if (!value.strip.length) return JSONValue(null);
    try {
        auto parsed = parseJSON(value);
        return parsed.type == JSONType.object ? parsed : JSONValue(null);
    } catch (Exception) {
        return JSONValue(null);
    }
}

private string firstString(JSONValue value, string[] names)
{
    if (value.type != JSONType.object) return "";
    foreach (name; names) {
        auto item = field(value, name);
        if (item is null) continue;
        if (item.type == JSONType.string) return item.str;
        if (item.type == JSONType.integer) return item.integer.to!string;
        if (item.type == JSONType.uinteger) return item.uinteger.to!string;
        if (item.type == JSONType.float_) return item.floating.to!string;
    }
    return "";
}

private bool firstLong(JSONValue value, string[] names, ref long output)
{
    if (value.type != JSONType.object) return false;
    foreach (name; names) {
        auto item = field(value, name);
        if (item is null) continue;
        if (item.type == JSONType.integer) {
            output = item.integer;
            return true;
        }
        if (item.type == JSONType.uinteger) {
            output = cast(long) item.uinteger;
            return true;
        }
    }
    return false;
}

private bool boolField(JSONValue event, string name)
{
    auto item = field(event, name);
    return item !is null && item.type == JSONType.true_;
}

private string textDelta(JSONValue event)
{
    auto update = objectField(event, "assistantMessageEvent");
    if (update is null) return "";
    auto updateJson = Json.object(*update);
    if (updateJson.opt.textOrEmpty("type") != "text_delta") return "";
    return updateJson.opt.textOrEmpty("delta");
}

private string assistantUpdateType(JSONValue event)
{
    auto update = objectField(event, "assistantMessageEvent");
    if (update is null) return "";
    return Json.object(*update).opt.textOrEmpty("type");
}

private string assistantUpdateDelta(JSONValue event)
{
    auto update = objectField(event, "assistantMessageEvent");
    if (update is null) return "";
    return Json.object(*update).opt.textOrEmpty("delta");
}

private string finalAssistantText(JSONValue event)
{
    auto messages = field(event, "messages");
    if (messages is null || messages.type != JSONType.array) return "";
    string result;
    foreach (message; messages.array) {
        if (message.type != JSONType.object) continue;
        auto role = Json.object(message).opt.text("role");
        if (role.isNull || role.get != "assistant") continue;
        auto text = messageText(message).strip;
        if (text.length) result = text;
    }
    return result;
}

private string finalAssistantReasoning(JSONValue event)
{
    auto messages = field(event, "messages");
    if (messages is null || messages.type != JSONType.array) return "";
    string result;
    foreach (message; messages.array) {
        if (message.type != JSONType.object) continue;
        auto role = Json.object(message).opt.text("role");
        if (role.isNull || role.get != "assistant") continue;
        auto thinking = messageReasoning(message).strip;
        if (thinking.length) result = thinking;
    }
    return result;
}

private string messageText(JSONValue message)
{
    auto content = field(message, "content");
    if (content is null) return "";
    if (content.type == JSONType.string) return content.str;
    if (content.type != JSONType.array) return "";

    auto output = appender!string;
    foreach (part; content.array) {
        if (part.type == JSONType.string) {
            output.put(part.str);
        } else if (part.type == JSONType.object) {
            auto text = Json.object(part).opt.textOrEmpty("text");
            if (text.length) output.put(text);
        }
    }
    return output.data;
}

private string messageReasoning(JSONValue message)
{
    auto content = field(message, "content");
    if (content is null || content.type != JSONType.array) return "";

    auto output = appender!string;
    foreach (part; content.array) {
        if (part.type != JSONType.object) continue;
        auto partJson = Json.object(part);
        if (partJson.opt.textOrEmpty("type") != "thinking") continue;
        auto text = partJson.opt.textOrEmpty("thinking");
        if (!text.length)
            text = partJson.opt.textOrEmpty("text");
        if (text.length) output.put(text);
    }
    return output.data;
}

private JSONValue* objectField(JSONValue value, string name)
{
    auto item = field(value, name);
    if (item is null || item.type != JSONType.object) return null;
    return item;
}

private JSONValue* field(JSONValue value, string name)
{
    if (value.type != JSONType.object) return null;
    auto object = value.objectNoRef;
    return name in object;
}

unittest
{
    ProfileRuntimeSettings settings;
    settings.toolProgress.search = "I'm searching.";
    settings.toolProgress.searchFor = "I'm searching for {query}.";
    settings.toolProgress.readWebPageDisplay = "I'm reading web page {url}.";
    settings.toolProgress.readWebPageSpoken = "I'm reading web page {domain}.";
    settings.toolProgress.readFiles = "I'm reading files.";
    settings.toolProgress.readNamedFile = "I'm reading {name}.";
    settings.toolProgress.readPath = "I'm reading {path}.";
    settings.toolProgress.updateFiles = "I'm updating files.";
    settings.toolProgress.updateNamedFile = "I'm updating {name}.";
    settings.toolProgress.updatePath = "I'm updating {path}.";
    settings.toolProgress.pythonStart = "I'm running Python.";
    settings.toolProgress.localCommandDisplay = "I'm running {command}.";
    settings.toolProgress.localCommandSpoken = "I'm running a command.";

    enum longQuery = "current research into reasoning and tool use in language models "
        ~ "with one billion parameters or fewer, including newly released models";
    auto searchProgress = toolProgress(
        "web_search",
        parseJSON(`{"query":"` ~ longQuery ~ `"}`),
        settings.toolProgress,
    );
    assert(searchProgress.displayMessage == "I'm searching for `" ~ longQuery ~ "`.");
    assert(searchProgress.spokenMessage == "I'm searching.");

    auto fetchProgress = toolProgress(
        "fetch_content",
        parseJSON(`{"url":"https://example.com/foo/bar"}`),
        settings.toolProgress,
    );
    assert(fetchProgress.displayMessage == "I'm reading web page https://example.com/foo/bar.");
    assert(fetchProgress.spokenMessage == "I'm reading web page example.com.");

    auto readProgress = toolProgress(
        "read",
        parseJSON(`{"path":"/profiles/tester/files/WHEATLEY.md"}`),
        settings.toolProgress,
    );
    assert(readProgress.displayMessage == "I'm reading `/profiles/tester/files/WHEATLEY.md`.");
    assert(readProgress.spokenMessage == "I'm reading WHEATLEY.");

    auto naturalReadProgress = toolProgress(
        "read",
        parseJSON(`{"path":"/profiles/tester/files/some_file-name.md"}`),
        settings.toolProgress,
    );
    assert(naturalReadProgress.displayMessage ==
        "I'm reading `/profiles/tester/files/some_file-name.md`.");
    assert(naturalReadProgress.spokenMessage == "I'm reading some file name.");

    auto writeProgress = toolProgress(
        "write",
        parseJSON(`{"path":"/profiles/tester/files/saved_file.txt"}`),
        settings.toolProgress,
    );
    assert(writeProgress.displayMessage ==
        "I'm updating `/profiles/tester/files/saved_file.txt`.");
    assert(writeProgress.spokenMessage == "I'm updating saved file.");

    auto commandProgress = toolProgress(
        "bash",
        parseJSON(`{"command":"ls /profiles/tester/files"}`),
        settings.toolProgress,
    );
    assert(commandProgress.displayMessage == "I'm running `ls /profiles/tester/files`.");
    assert(commandProgress.spokenMessage == "I'm running a command.");

    auto pythonProgress = toolProgress(
        "bash",
        parseJSON(`{"command":"python check.py"}`),
        settings.toolProgress,
    );
    assert(pythonProgress.displayMessage == "I'm running `python check.py`.");
    assert(pythonProgress.spokenMessage == "I'm running Python.");

    enum longPython = "python3 << 'EOF'\nprint('hello')\nprint('world')\nEOF";
    auto longPythonProgress = toolProgress(
        "bash",
        parseJSON(`{"command":` ~ JSONValue(longPython).toString() ~ `}`),
        settings.toolProgress,
    );
    assert(longPythonProgress.displayMessage == "I'm running `" ~ longPython ~ "`.");
    assert(longPythonProgress.spokenMessage == "I'm running Python.");
}

unittest
{
    import wheatley.common.api.session : SessionKey;
    import wheatley.common.conversation.events : ConversationEventKind;

    ProfileRuntimeSettings settings;
    string[] statusCodes;
    auto stream = new ConversationEventStream(
        SessionKey("tester", "2026/08/16/12_00_00"),
        "turn-compact",
        (event) {
            if (event.kind == ConversationEventKind.status)
                statusCodes ~= event.status.code;
        },
    );
    PiCompactionEvent recorded;
    auto collector = new PiEventCollector(
        "tester",
        settings,
        stream,
        null,
        null,
        (event) {
            recorded = event;
            return 17;
        },
    );
    collector.handleLine(`{"type":"compaction_start","reason":"threshold"}`);
    collector.handleLine(`{"type":"compaction_end","reason":"threshold","result":{`
        ~ `"summary":"Kept the durable plan.","firstKeptEntryId":"entry-1",`
        ~ `"tokensBefore":90000,"estimatedTokensAfter":21000,"usage":{},"details":{}},`
        ~ `"aborted":false,"willRetry":false}`);

    assert(statusCodes == ["pi_compaction_started", "pi_compaction_completed"]);
    assert(recorded.reason == "threshold");
    assert(recorded.status == "completed");
    assert(recorded.summary == "Kept the durable plan.");
    assert(recorded.tokensBefore == 90_000);
    assert(recorded.estimatedTokensAfter == 21_000);
    assert(collector.compactions.length == 1);
    assert(collector.compactionMetricsJson.length);
}

unittest
{
    ProfileRuntimeSettings settings;
    long recordedCount;
    auto collector = new PiEventCollector(
        "tester",
        settings,
        null,
        null,
        null,
        (event) {
            recordedCount++;
            return 1;
        },
    );
    collector.handleLine(`{"type":"compaction_start","reason":"manual"}`);
    collector.handleLine(`{"type":"compaction_end","reason":"manual",`
        ~ `"errorMessage":"Already compacted","aborted":false,"willRetry":false}`);

    assert(recordedCount == 0);
    assert(collector.compactions.length == 1);
    assert(collector.compactions[0].status == "skipped");
    assert(collector.compactions[0].errorMessage == "Already compacted");
}

unittest
{
    import wheatley.common.api.session : SessionKey;
    import wheatley.common.conversation.events : ConversationEventKind;

    ProfileRuntimeSettings settings;
    settings.maxToolCallsPerTurn = 1;
    settings.toolProgress.imageSearch = "I'm searching.";
    settings.toolProgress.imageSearchFor = "I'm searching for {query}.";

    string[] order;
    auto stream = new ConversationEventStream(
        SessionKey("tester", "2026/08/13/12_00_00"),
        "turn-1",
        (event) {
            if (event.kind == ConversationEventKind.tool && event.tool.stage == "end")
                order ~= "emit";
        },
    );
    auto collector = new PiEventCollector(
        "tester",
        settings,
        stream,
        (tools) {
            assert(tools.length == 1);
            order ~= "persist";
        },
    );

    collector.handleLine(
        `{"type":"message_update","assistantMessageEvent":{`
        ~ `"type":"toolcall_end","contentIndex":0,"toolCall":{"id":"call-1"}}}`,
    );
    collector.handleLine(
        `{"type":"tool_execution_start","toolCallId":"call-1",`
        ~ `"toolName":"image_search","args":{"query":"drone"}}`,
    );
    collector.handleLine(
        `{"type":"tool_execution_end","toolCallId":"call-1",`
        ~ `"toolName":"image_search","isError":false,"result":{"content":[]}}`,
    );

    assert(order == ["persist", "persist", "emit"]);
}

unittest
{
    ProfileRuntimeSettings settings;
    auto events = new PiEventCollector("tester", settings);
    events.handleLine(
        `{"type":"message_end","message":{"role":"assistant","usage":{"input":11,"output":7,"cacheRead":13,"cacheWrite":2,"reasoning":3,"totalTokens":36}}}`,
    );
    auto usage = events.providerUsage;
    assert(usage.available);
    assert(usage.inputTokens == 11);
    assert(usage.outputTokens == 7);
    assert(usage.cacheReadTokens == 13);
    assert(usage.cacheWriteTokens == 2);
    assert(usage.reasoningTokens == 3);
    assert(usage.totalTokens == 36);
    assert(usage.latestContextTokens == 26);
}

unittest
{
    ProfileRuntimeSettings settings;
    auto events = new PiEventCollector("tester", settings);
    events.handleLine(
        `{"type":"message_end","message":{"role":"assistant",`
        ~ `"stopReason":"error","errorMessage":"Request timed out."}}`,
    );
    assert(events.providerError == "Request timed out.");
}
