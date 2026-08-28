module wheatley.server.conversation.pi_agent_runtime;

import core.time : MonoTime;
import core.sync.mutex : Mutex;

import std.base64 : Base64;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file : read;
import std.string : strip;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.api.reasoning : piThinkingLevel, ReasoningMode;
import wheatley.common.api.session : SessionKey;
import wheatley.common.conversation.events : ConversationToolEvent;
import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.conversation.agent_runtime :
    AgentRuntime,
    AgentRuntimeFailure,
    AgentSteerInput,
    AgentSteeredTurnResult,
    AgentTurnInput,
    AgentTurnResult;
import wheatley.server.conversation.event_stream : ConversationEventStream;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.turns.text.pi_events : PiEventCollector;
import wheatley.server.turns.text.pi_event_router :
    PiEventRouter,
    PiEventTarget;
import wheatley.server.turns.text.pi_compaction : PiCompactionEvent;
import wheatley.server.turns.text.pi_runtime : checkPiAvailability, safeId;
import wheatley.server.presentation.store : appendPresentation;
import wheatley.server.turns.text.pi_prompt :
    buildPiContext;
import wheatley.server.turns.text.pi_invocation :
    PiInvocationRuntime,
    piWorkerCommand,
    piWorkerEnvironment,
    piWorkerFingerprint,
    preparePiInvocationRuntime,
    recordPiInvocationSession,
    writePiWorkerTurnContext;
import wheatley.server.turns.text.llm_metrics : llmMetricsJson;
import wheatley.server.turns.text.pi_run_gate : PiRunGate;
import wheatley.server.turns.text.pi_worker :
    PiWorker,
    PiWorkerProcessFailure,
    PiWorkerRegistry,
    PiWorkerTurnResult;
import wheatley.server.turns.text.profile_runtime_settings : ProfileRuntimeSettings;
import wheatley.server.turns.image.inference_image :
    InferenceImage,
    prepareInferenceImage;
import wheatley.common.runtime.now_iso : nowIso;

private struct ActivePiRun
{
    string parentTurnId;
    string modelName;
    ReasoningMode reasoningMode;
    bool allowSteering;
    string runtimeSessionId;
    string workingRoot;
    ProfileRuntimeSettings settings;
    PiInvocationRuntime runtime;
    string parentClientId;
    string systemPrompt;
    PiWorker worker;
    PiEventRouter router;
}

final class PiAgentRuntime : AgentRuntime
{
    private ServerConfig config;
    private HistoryStore store;
    private PiRunGate runs;
    private PiWorkerRegistry workers;
    private Mutex activeMutex;
    private ActivePiRun[string] activeRuns;

    this(ServerConfig config, HistoryStore store, PiRunGate runs)
    {
        this.config = config;
        this.store = store;
        this.runs = runs;
        this.workers = new PiWorkerRegistry;
        this.activeMutex = new Mutex;
    }

    void stop(SessionKey session, string turnId)
    {
        synchronized (activeMutex) {
            if (auto active = session.value in activeRuns) {
                workers.stop(session, active.parentTurnId);
                return;
            }
        }
        workers.stop(session, turnId);
    }

    bool available(ProfileRuntimeSettings settings)
    {
        return checkPiAvailability(settings.piCommand).available;
    }

    bool steer(AgentSteerInput input)
    {
        synchronized (activeMutex) {
            auto active = input.session.value in activeRuns;
            if (active is null || !active.allowSteering
                || active.modelName != input.modelName
                || active.reasoningMode != input.reasoningMode) return false;
            auto activeSettings = active.settings;
            auto activeRuntimeSessionId = active.runtimeSessionId;
            auto activeWorkingRoot = active.workingRoot;
            auto target = PiEventTarget(
                input.turnId,
                input.userText,
                input.events,
                (tools) { store.saveRuntimeToolEvents(
                    input.session.profileId,
                    input.turnId,
                    tools,
                ); },
                input.contentChanged,
                (event) => recordCompaction(input.session, input.turnId, event),
                () {
                    input.events.status(
                        "api_text_pi_started",
                        activeSettings.thinkingMessage,
                        jsonObject([
                            jsonStringField("model", activeSettings.assistantModel),
                            jsonBoolField("load_memory", false),
                        ]),
                    );
                    emitTurnStarted(
                        input.session.profileId,
                        activeRuntimeSessionId,
                        activeWorkingRoot,
                        activeSettings,
                        input.events,
                    );
                },
            );
            active.router.queueSteer(target);
            try {
                if (active.worker.steer(
                    active.parentTurnId,
                    input.turnId ~ "-steer",
                    input.userText,
                    () {
                        input.admitted();
                        writePiWorkerTurnContext(
                            active.runtime,
                            input.turnId,
                            input.reasoningMode,
                            input.clientId,
                            activeSettings,
                        );
                    },
                )) return true;
            } catch (Exception error) {
                active.router.removeQueued(input.turnId);
                writePiWorkerTurnContext(
                    active.runtime,
                    active.parentTurnId,
                    active.reasoningMode,
                    active.parentClientId,
                    activeSettings,
                    active.systemPrompt,
                );
                throw error;
            }
            active.router.removeQueued(input.turnId);
            return false;
        }
    }

    void recycle(SessionKey session)
    {
        workers.recycle(session);
    }

    void shutdown()
    {
        workers.shutdown();
    }

    string compact(SessionKey session, ProfileRuntimeSettings settings)
    {
        auto runtime = preparePiInvocationRuntime(config, store, session);
        recordPiInvocationSession(store, session, runtime, settings);
        auto startedAt = nowIso();
        auto startedMono = MonoTime.currTime;
        auto commandId = "manual-compaction-" ~ safeId(startedAt);
        writePiWorkerTurnContext(
            runtime,
            commandId,
            ReasoningMode.off,
            "wheatley-maintenance",
            settings,
        );
        auto events = new PiEventCollector(
            session.profileId,
            settings,
            null,
            null,
            null,
            (event) => recordCompaction(session, "", event),
        );
        PiWorker worker;
        try {
            runs.lock();
            scope(exit) runs.unlock();
            worker = workers.workerFor(
                session,
                piWorkerFingerprint(runtime, settings),
                piWorkerCommand(runtime, settings),
                piWorkerEnvironment(config, session, runtime),
                runtime.workingRoot,
            );
            worker.compact(commandId, events);
            events.finish();
            store.savePiSessionJsonl(session, runtime.sessionDir);
        } catch (Exception error) {
            if (worker !is null) workers.discard(session, worker);
            store.savePiSessionJsonl(session, runtime.sessionDir);
            auto noOp = manualCompactionNoOp(error.msg);
            if (noOp.length) return PiCompactionEvent(
                commandId,
                "manual",
                "skipped",
                startedAt,
                nowIso(),
                cast(long) (MonoTime.currTime - startedMono).total!"msecs",
                "",
                noOp,
                0,
                0,
                false,
                "{}",
                "{}",
            ).json();
            throw error;
        }
        enforce(events.compactions.length, "Pi compacted without a compaction event");
        auto result = events.compactions[$ - 1];
        return result.json();
    }

    AgentTurnResult run(AgentTurnInput input)
    {
        auto session = input.session;
        auto turnId = input.turnId;
        auto userText = input.userText;
        auto startedAt = input.startedAt;
        auto settings = input.settings;
        auto reasoningMode = input.reasoningMode;
        auto loadMemory = input.loadMemory;
        auto eventStream = input.events;
        auto contentChanged = input.contentChanged;
        auto stopped = input.stopped;
        auto runtime = preparePiInvocationRuntime(config, store, session);
        recordPiInvocationSession(store, session, runtime, settings);
        auto hasConversation = store.sessionPiSessionHasConversation(session);
        auto presentModelContext = !store.sessionHasPresentedModelContext(session);
        string context;
        if (store.hasSessionContext(session)) {
            context = store.sessionContext(session);
        } else if (!hasConversation) {
            context = buildPiContext(
                store,
                session,
                runtime.workingRoot,
                runtime.workspaceFile,
                settings,
                loadMemory,
            );
            store.saveSessionContext(session, context);
        }
        auto systemPrompt = context.strip;
        if (input.privatePrompt.strip.length)
            systemPrompt ~= "\n\n" ~ input.privatePrompt.strip;
        auto prompt = userText.strip;
        auto hasModelContext = presentModelContext && context.strip.length > 0;
        auto events = new PiEventRouter(
            session.profileId,
            settings,
            PiEventTarget(
                turnId,
                prompt,
                eventStream,
                (tools) { store.saveRuntimeToolEvents(session.profileId, turnId, tools); },
                contentChanged,
                (event) => recordCompaction(session, turnId, event),
                null,
                input.prefixTools,
            ),
        );
        bool hasProcessStart;
        MonoTime processStarted;
        MonoTime processEnded;
        bool hasProcessEnd;
        PiWorker worker;
        PiWorkerTurnResult workerRun;
        InferenceImage inferenceImage;
        scope(exit) inferenceImage.removeTemporary();

        emitTurnStarted(
            session.profileId,
            runtime.sessionId,
            runtime.workingRoot,
            settings,
            eventStream,
        );
        if (hasModelContext) eventStream.tool(ConversationToolEvent(
            "start",
            "model-context",
            "model_context",
            -1,
            "succeeded",
            session.profileId,
            settings.toolProgress.modelContext,
            false,
            "",
            "{}",
        ));

        try {
            runs.lock();
            scope(exit) runs.unlock();
            if (stopped !is null && stopped()) return AgentTurnResult();
            if (input.hasUserImage) {
                inferenceImage = prepareInferenceImage(
                    config,
                    turnId,
                    input.userImage.path,
                    input.userImage.mediaType,
                    settings.piImageLongEdgePx,
                );
            }
            processStarted = MonoTime.currTime;
            hasProcessStart = true;
            writePiWorkerTurnContext(
                runtime,
                turnId,
                reasoningMode,
                input.clientId,
                settings,
                systemPrompt,
            );
            auto scheduledTaskRun = input.clientId == "scheduler";
            worker = workers.workerFor(
                session,
                piWorkerFingerprint(runtime, settings, scheduledTaskRun),
                piWorkerCommand(runtime, settings, scheduledTaskRun),
                piWorkerEnvironment(config, session, runtime),
                runtime.workingRoot,
            );
            synchronized (activeMutex) activeRuns[session.value] = ActivePiRun(
                turnId,
                settings.assistantModel,
                reasoningMode,
                !scheduledTaskRun,
                runtime.sessionId,
                runtime.workingRoot,
                settings,
                runtime,
                input.clientId,
                systemPrompt,
                worker,
                events,
            );
            scope(exit) synchronized (activeMutex) {
                auto active = session.value in activeRuns;
                if (active !is null && active.router is events)
                    activeRuns.remove(session.value);
            }
            workerRun = worker.run(
                turnId,
                prompt,
                piThinkingLevel(reasoningMode),
                events,
                stopped,
                input.hasUserImage
                    ? piUserImagesJson(inferenceImage.path, inferenceImage.mediaType)
                    : "",
            );
            events.finish();
            processEnded = MonoTime.currTime;
            hasProcessEnd = true;
            store.savePiSessionJsonl(session, runtime.sessionDir);
            // A steer accepted just as Pi emits its final boundary remains a
            // normal durable turn. Recycle the worker before that turn runs so
            // Pi cannot retain and later replay the stale RPC steer internally.
            if (events.hasUndeliveredSteers) workers.discard(session, worker);
        } catch (Exception error) {
            if (worker !is null) workers.discard(session, worker);
            events.finish();
            processEnded = MonoTime.currTime;
            hasProcessEnd = hasProcessStart;
            store.savePiSessionJsonl(session, runtime.sessionDir);
            auto processError = cast(PiWorkerProcessFailure) error;
            auto initial = events.initialSegment().collector;
            throw piFailure(
                error.msg,
                prompt,
                initial,
                events.rawJsonl,
                processError is null ? -1 : processError.exitStatus,
                processError !is null && processError.hasExitStatus,
                hasProcessStart,
                processStarted,
                hasProcessEnd,
                processEnded,
                workerRun,
                settings.piContextWindow,
                steeredTurnResults(events, hasProcessStart, settings.piContextWindow),
            );
        }

        auto initialSegment = events.initialSegment();
        auto initial = initialSegment.collector;
        auto steeredTurns = steeredTurnResults(
            events,
            hasProcessStart,
            settings.piContextWindow,
        );
        auto finalText = initial.assistantText;
        auto metricsJson = llmMetricsJson(
            prompt,
            finalText,
            initial,
            hasProcessStart,
            processStarted,
            initialSegment.endedMono,
            workerRun.workerStarted,
            workerRun.workerStartedMono,
            workerRun.workerReadyMono,
            settings.piContextWindow,
        );
        if (stopped !is null && stopped()) {
            return AgentTurnResult(
                finalText,
                initial.toolCount,
                initial.tools,
                metricsJson,
                initial.reasoningMetricsJson,
                initial.hasFirstAssistantDelta,
                initial.firstAssistantDeltaMono,
                hasProcessEnd,
                processEnded,
                initial.hasLatestAssistantStart,
                initial.latestAssistantStartMono,
                steeredTurns,
            );
        }
        if (!finalText.length && (!steeredTurns.length
            || !steeredTurns[$ - 1].assistantText.length)) {
            throw piFailure(
                initial.providerError.length
                    ? initial.providerError
                    : "Pi completed without a final response",
                prompt,
                initial,
                events.rawJsonl,
                -1,
                false,
                hasProcessStart,
                processStarted,
                hasProcessEnd,
                processEnded,
                workerRun,
                settings.piContextWindow,
                steeredTurns,
            );
        }

        return AgentTurnResult(
            finalText,
            initial.toolCount,
            initial.tools,
            metricsJson,
            initial.reasoningMetricsJson,
            initial.hasFirstAssistantDelta,
            initial.firstAssistantDeltaMono,
            hasProcessEnd,
            processEnded,
            initial.hasLatestAssistantStart,
            initial.latestAssistantStartMono,
            steeredTurns,
        );
    }

    private AgentSteeredTurnResult[] steeredTurnResults(
        PiEventRouter events,
        bool hasProcessStart,
        long contextWindowTokens,
    )
    {
        AgentSteeredTurnResult[] results;
        foreach (segment; events.steeringSegments) {
            auto collector = segment.collector;
            auto llm = llmMetricsJson(
                segment.target.userText,
                collector.assistantText,
                collector,
                hasProcessStart,
                segment.startedMono,
                segment.endedMono,
                false,
                MonoTime.init,
                MonoTime.init,
                contextWindowTokens,
            );
            auto activityMs = hasProcessStart
                ? cast(long) (segment.endedMono - segment.startedMono).total!"msecs" : 0;
            results ~= AgentSteeredTurnResult(
                segment.target.turnId,
                collector.assistantText,
                collector.toolCount,
                collector.tools,
                jsonObject([
                    jsonRawField("llm", llm),
                    collector.reasoningMetricsJson.length
                        ? jsonRawField("reasoning", collector.reasoningMetricsJson) : "",
                    jsonRawField("turn", jsonObject([
                        jsonLongField("activity_ms", activityMs),
                    ])),
                ]),
                collector.reasoningMetricsJson,
                collector.hasFirstAssistantDelta,
                collector.firstAssistantDeltaMono,
                collector.hasLatestAssistantStart,
                collector.latestAssistantStartMono,
                segment.target.eventStream,
            );
        }
        return results;
    }

    private long recordCompaction(
        SessionKey session,
        string turnId,
        PiCompactionEvent event,
    )
    {
        auto sessionRoot = store.requireSession(session);
        return appendPresentation(
            sessionRoot,
            "pi",
            "compaction",
            turnId,
            event.id,
            (long sequence) => event.json(sequence),
        );
    }

    private void emitTurnStarted(
        string profileId,
        string sessionId,
        string profileFilesRoot,
        ProfileRuntimeSettings settings,
        ConversationEventStream events,
    )
    {
        events.status(
            "pi_turn_started",
            settings.thinkingMessage,
            jsonObject([
                jsonStringField("model", settings.piModel),
                jsonStringField("session_id", sessionId),
                jsonStringField("files_root", profileFilesRoot),
            ]),
        );
        events.tool(ConversationToolEvent(
            "start",
            "",
            "pi",
            0,
            "running",
            profileId,
            "",
            true,
            "",
        ));
    }

    private AgentRuntimeFailure piFailure(
        string message,
        string prompt,
        PiEventCollector events,
        string rawJsonl,
        int exitStatus,
        bool hasPiExitStatus,
        bool hasProcessStart,
        MonoTime processStarted,
        bool hasProcessEnd,
        MonoTime processEnded,
        PiWorkerTurnResult workerRun,
        long contextWindowTokens,
        AgentSteeredTurnResult[] steeredTurns = [],
    )
    {
        return new AgentRuntimeFailure(
            message,
            events.assistantText,
            events.tools,
            events.toolCount,
            llmMetricsJson(
                prompt,
                events.assistantText,
                events,
                hasProcessStart,
                processStarted,
                processEnded,
                workerRun.workerStarted,
                workerRun.workerStartedMono,
                workerRun.workerReadyMono,
                contextWindowTokens,
            ),
            events.reasoningMetricsJson,
            piProcessErrorsJson(message, exitStatus, hasPiExitStatus, rawJsonl),
            hasPiExitStatus,
            exitStatus,
            events.hasFirstAssistantDelta,
            events.firstAssistantDeltaMono,
            hasProcessEnd,
            processEnded,
            events.hasLatestAssistantStart,
            events.latestAssistantStartMono,
            steeredTurns,
            hasProcessStart,
        );
    }
}

private string manualCompactionNoOp(string message)
{
    if (message.canFind("Nothing to compact"))
        return "Nothing to compact (session too small)";
    if (message.canFind("Already compacted"))
        return "Context is already compacted";
    return "";
}

unittest
{
    assert(manualCompactionNoOp(
        "Pi RPC request compact failed: Nothing to compact (session too small)",
    ) == "Nothing to compact (session too small)");
    assert(manualCompactionNoOp("Pi RPC request compact failed: Already compacted")
        == "Context is already compacted");
    assert(!manualCompactionNoOp("provider failed").length);
}

private string piUserImagesJson(string path, string mediaType)
{
    auto data = Base64.encode(cast(ubyte[]) read(path));
    return "[" ~ jsonObject([
        jsonStringField("type", "image"),
        jsonStringField("data", data.idup),
        jsonStringField("mimeType", mediaType),
    ]) ~ "]";
}

private string piProcessErrorsJson(string message, int exitStatus, bool hasPiExitStatus, string output)
{
    auto tail = outputTail(output, 16_384);
    return jsonObject([
        jsonRawField("errors", "[" ~ jsonObject([
            jsonStringField("stage", "pi_process"),
            jsonStringField("recorded_at", nowIso()),
            jsonStringField("message", message),
            hasPiExitStatus ? jsonLongField("pi_exit_status", exitStatus) : "",
            tail.text.length ? jsonStringField("output_tail", tail.text) : "",
            tail.truncated ? jsonBoolField("output_truncated", true) : "",
        ]) ~ "]"),
    ]);
}

private struct OutputTail
{
    string text;
    bool truncated;
}

private OutputTail outputTail(string text, size_t maxBytes)
{
    if (text.length <= maxBytes) return OutputTail(text, false);
    return OutputTail(text[$ - maxBytes .. $], true);
}
