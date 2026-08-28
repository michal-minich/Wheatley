module wheatley.server.conversation.runtime;

import core.time : MonoTime, dur;

import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.file : exists, getSize;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.string : strip;

import vibe.core.sync : TaskMutex, scopedMutexLock;
import vibe.core.core : Timer, runTask, setTimer, sleep;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.reasoning :
    ReasoningMode,
    parseReasoningMode,
    nearestReasoningMode,
    reasoningModeText;
import wheatley.common.api.text_turn : TextTurnRequest;
import wheatley.common.prompt_text : promptStartsWithThink;
import wheatley.common.conversation.events :
    ConversationEventKind,
    ConversationEventSink,
    ConversationToolEvent;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.object : jsonUlongField;
import wheatley.common.json.read : Json;
import wheatley.server.client_tools.store : ClientToolStore;
import wheatley.server.conversation.agent_runtime :
    AgentContentEvent,
    AgentRuntime,
    AgentRuntimeFailure,
    AgentSteeredTurnResult,
    AgentUserImage,
    AgentTurnInput,
    AgentTurnResult;
import wheatley.server.conversation.event_stream : ConversationEventStream;
import wheatley.server.conversation.port :
    ConversationPort,
    ConversationPreparationPort,
    ConversationPromptPrewarm;
import wheatley.server.conversation.preparation :
    ConversationPreparation,
    ConversationPreparationGate;
import wheatley.server.conversation.turn_request :
    ConversationTurnRequest,
    conversationTurnRequest,
    conversationSubmissionId,
    conversationTurnSource;
import wheatley.server.conversation.turn_response :
    conversationTurnResponse,
    storedConversationTurnResponse;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.history.rows.image_artifact_record : UserImageArtifactRecord;
import wheatley.server.history.rows.text_turn_record : TextTurnRecord;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.types : StoredTurn;
import wheatley.server.pi.models : PiModels;
import wheatley.server.profile.runtime : ProfileRuntime;
import wheatley.server.tools.types : ExecutedTool, ToolCall, ToolResult;
import wheatley.server.tts.turn_speech_registry : TurnSpeechRegistry, TurnSpeechTurn;
import wheatley.server.turns.text.session_work_lanes :
    SessionWorkLanes;
import wheatley.server.turns.text.profile_runtime_settings : loadProfileRuntimeSettings;
import wheatley.server.turns.text.turn_stop_registry : TurnStopRegistry;
import wheatley.server.queue.session_queue :
    QueueReservation,
    QueueMutation,
    QueueItem,
    QueueItemState,
    queueItemStateText;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.queue.session_queue_projection : projectQueueMutation;

private enum interruptedExecutionMessage =
    "Conversation execution was interrupted; it was not run again automatically.";

final class ConversationRuntime : ConversationPort, ConversationPreparationPort
{
    private HistoryStore store;
    private ProfileRuntime profiles;
    private TurnStopRegistry stops;
    private AgentRuntime agent;
    private ConversationPreparationGate preparations;
    private TurnSpeechRegistry speechTurns;
    private SessionWorkLanes lanes;
    private SessionWorkLanes admissionLanes;
    private TaskMutex dispatcherMutex;
    private bool[string] dispatching;
    private TaskMutex promptMutex;
    private ConversationPromptPrewarm[string] pendingPromptPrewarms;
    private Timer preparationWatchdog;
    private PiModels models;
    private bool delegate() imageGenerationAvailable;
    private ClientToolStore clientTools;

    this(
        HistoryStore store,
        ProfileRuntime profiles,
        AgentRuntime agent,
        TurnSpeechRegistry speechTurns,
        SessionWorkLanes lanes,
        PiModels models,
        ClientToolStore clientTools,
        bool delegate() imageGenerationAvailable,
    )
    {
        this.store = store;
        this.profiles = profiles;
        enforce(agent !is null, "Agent Runtime is required");
        this.agent = agent;
        this.stops = new TurnStopRegistry;
        this.preparations = new ConversationPreparationGate;
        this.speechTurns = speechTurns;
        this.lanes = lanes;
        this.admissionLanes = new SessionWorkLanes;
        this.dispatcherMutex = new TaskMutex;
        this.promptMutex = new TaskMutex;
        this.models = models;
        enforce(clientTools !is null, "Client tool store is required");
        this.clientTools = clientTools;
        enforce(imageGenerationAvailable !is null, "Image generation availability is required");
        this.imageGenerationAvailable = imageGenerationAvailable;
    }

    void recoverInterruptedTurns()
    {
        foreach (session; store.sessionKeys()) {
            auto queue = store.sessionQueue(session);
            auto recovered = queue.snapshot();
            bool hasTerminalPrefix;
            bool terminalPrefixProjected = true;
            foreach (item; recovered.items) {
                if (item.state != QueueItemState.completed
                    && item.state != QueueItemState.failed
                    && item.state != QueueItemState.cancelled
                    && item.state != QueueItemState.interrupted) break;
                hasTerminalPrefix = true;
                if (item.state == QueueItemState.cancelled) {
                    auto turn = store.findTurnBySubmission(session, item.id);
                    if (turn.id.length && turn.status == "pending")
                        store.cancelPendingConversationTurn(session, turn.id, nowIso());
                } else if (item.state == QueueItemState.failed
                    || item.state == QueueItemState.interrupted) {
                    auto turn = store.findTurnBySubmission(session, item.id);
                    if (turn.id.length && (turn.status == "pending" || turn.status == "running"))
                        store.failInterruptedConversationTurn(
                            session,
                            turn.id,
                            nowIso(),
                            item.failure.length ? item.failure : interruptedExecutionMessage,
                        );
                }
                terminalPrefixProjected = projectQueueMutation(
                    store,
                    session,
                    QueueMutation(item, recovered.revision, true),
                ) && terminalPrefixProjected;
            }
            if (hasTerminalPrefix && terminalPrefixProjected)
                queue.compactTerminalPrefix();
            foreach (item; queue.snapshot().items) {
                if (item.state == QueueItemState.running) {
                    auto mutation = queue.interrupt(item.id, interruptedExecutionMessage);
                    auto turn = store.findTurnBySubmission(session, item.id);
                    if (turn.id.length && (turn.status == "pending" || turn.status == "running")) {
                        store.failInterruptedConversationTurn(
                            session,
                            turn.id,
                            nowIso(),
                            interruptedExecutionMessage,
                        );
                    }
                    if (projectQueueMutation(store, session, mutation))
                        queue.compactTerminalPrefix();
                    continue;
                }
                if (item.state == QueueItemState.preparing) {
                    auto failure = "Conversation preparation was interrupted by daemon restart.";
                    auto mutation = queue.fail(item.id, failure);
                    auto turn = store.findTurnBySubmission(session, item.id);
                    if (turn.id.length && (turn.status == "pending" || turn.status == "running"))
                        store.failInterruptedConversationTurn(session, turn.id, nowIso(), failure);
                    if (projectQueueMutation(store, session, mutation))
                        queue.compactTerminalPrefix();
                    continue;
                }
            }
            // The durable queue owns recovery order. The dispatcher claims
            // only its earliest ready item and wakes the next one after the
            // current item reaches a terminal state.
            wakeQueue(session);
        }
    }

    void wake(SessionKey session)
    {
        wakeQueue(session);
    }

    /** Starts the preparation watchdog after queue migration and recovery have
        made the durable queue the canonical startup view. Deadlines are
        producer-published; the watchdog never invents a generic STT timeout. */
    void startPreparationWatchdog()
    {
        if (preparationWatchdog) return;
        preparationWatchdog = setTimer(dur!"seconds"(1), () {
            watchPreparations();
        }, true);
    }

    private void watchPreparations()
    {
        auto at = nowIso();
        foreach (session; store.sessionKeys()) {
            auto queue = store.sessionQueue(session);
            foreach (item; queue.snapshot().items) {
                if (item.state != QueueItemState.preparing
                    || !item.preparationDeadlineAt.length) continue;
                QueueMutation mutation;
                try {
                    mutation = queue.expirePreparation(
                        item.id,
                        at,
                        "Conversation preparation exceeded its producer-published deadline.",
                    );
                } catch (Exception) {
                    continue;
                }
                if (!mutation.changed) continue;
                auto turn = store.findTurnBySubmission(session, item.id);
                if (turn.id.length && (turn.status == "pending" || turn.status == "running")) {
                    store.failInterruptedConversationTurn(
                        session,
                        turn.id,
                        at,
                        mutation.item.failure,
                    );
                }
                if (projectQueueMutation(store, session, mutation))
                    queue.compactTerminalPrefix();
                wakeQueue(session);
            }
            // Also retry a ready item after a transient Pi launch failure.
            // The queue remains ready until the external execution boundary
            // is actually claimed.
            wakeQueue(session);
        }
    }

    private void wakeQueue(SessionKey session)
    {
        {
            auto guard = scopedMutexLock(dispatcherMutex);
            if (dispatching.get(session.value, false)) return;
            dispatching[session.value] = true;
        }
        auto sessionValue = session.value;
        runTask(() nothrow {
            scope(exit) {
                auto guard = scopedMutexLock(dispatcherMutex);
                dispatching.remove(sessionValue);
            }
            try {
                while (true) {
                    auto queue = store.sessionQueue(session);
                    auto snapshot = queue.snapshot();
                    bool running;
                    QueueItem first;
                    bool found;
                    foreach (item; snapshot.items) {
                        if (item.state == QueueItemState.running) running = true;
                        if (found) continue;
                        if (item.state == QueueItemState.completed
                            || item.state == QueueItemState.failed
                            || item.state == QueueItemState.cancelled
                            || item.state == QueueItemState.interrupted) continue;
                        first = item;
                        found = true;
                    }
                    if (running || !found || first.state != QueueItemState.ready) return;

                    auto turn = store.findTurnBySubmission(session, first.id);
                    if (!turn.id.length || (turn.status != "pending" && turn.status != "running")) {
                        auto mutation = queue.fail(
                            first.id,
                            "Queue item has no recoverable pending turn.",
                        );
                        if (projectQueueMutation(store, session, mutation))
                            queue.compactTerminalPrefix();
                        continue;
                    }
                    auto request = conversationTurnRequest(TextTurnRequest(
                        session.sessionId,
                        first.text,
                        first.id,
                        first.deviceId,
                        first.language,
                        first.source,
                        first.loadMemory,
                        parseReasoningMode(first.reasoningMode),
                        first.model,
                        0,
                    ));
                    request.startedAtOverride = turn.startedAt;
                    request.hasUserImage = turn.hasUserImage;
                    request.userImage = UserImageArtifactRecord(
                        turn.userImageFilename,
                        turn.userImageMediaType,
                        turn.userImagePath,
                        "",
                        turn.userImageBytes,
                    );
                    auto promptPrewarm = takePromptPrewarm(first.id);
                    auto audio = recoveredUserAudio(session, first, turn);
                    auto executed = runReportingFailures(
                        session,
                        request,
                        audio.artifactKey.length > 0,
                        audio,
                        (_) {},
                        first.source,
                        promptPrewarm,
                        true,
                    );
                    if (!executed) return;
                }
            } catch (Throwable) {
                // A dispatcher failure must not terminate the daemon. The
                // durable item remains inspectable and the next wake/restart
                // can retry it according to its persisted state.
            }
        });
    }

    private ConversationPromptPrewarm takePromptPrewarm(string submissionId)
    {
        auto guard = scopedMutexLock(promptMutex);
        auto value = submissionId in pendingPromptPrewarms;
        if (value is null) return null;
        auto result = *value;
        pendingPromptPrewarms.remove(submissionId);
        return result;
    }

    private UserAudioArtifactRecord recoveredUserAudio(
        SessionKey session,
        QueueItem item,
        StoredTurn turn,
    )
    {
        if (!turn.hasUserAudio || !turn.turnRoot.length) return UserAudioArtifactRecord();
        auto path = buildPath(turn.turnRoot, "user.opus");
        if (!exists(path)) return UserAudioArtifactRecord();
        return UserAudioArtifactRecord(
            item.artifactReference,
            session.profileId,
            turn.startedAt,
            path,
            cast(ulong) getSize(path),
            0,
            false,
            0,
            false,
        );
    }

    void stop(SessionKey session, string turnId)
    {
        enforce(store.findTurn(session, turnId).id.length, "Turn not found");
        stops.stop(turnId);
        agent.stop(session, turnId);
    }

    string compact(SessionKey session)
    {
        enforce(store.profileExists(session.profileId), "Profile not found");
        store.requireSession(session);
        preparations.wait(session);
        auto model = models.chatModel(store.sessionModel(session));
        auto resolved = profiles.resolveSession(
            session.profileId,
            store.sessionLanguage(session),
        );
        auto settings = loadProfileRuntimeSettings(
            resolved,
            model,
            imageGenerationAvailable(),
            ReasoningMode.off,
        );
        auto lane = lanes.get(session);
        auto laneGuard = scopedMutexLock(lane);
        return agent.compact(session, settings);
    }

    void shutdown()
    {
        if (preparationWatchdog) preparationWatchdog.stop();
        agent.shutdown();
    }

    bool performsLocalAgentStartup()
    {
        return true;
    }

    ConversationPreparation beginSessionPreparation(SessionKey session)
    {
        return preparations.begin(session);
    }

    void finishSessionPreparation(
        SessionKey session,
        ConversationPreparation preparation,
        string error = "",
    )
    {
        preparations.finish(session, preparation, error);
    }

    ConversationPromptPrewarm startPromptPrewarm(
        SessionKey session,
        string language,
        bool loadMemory,
        bool _prewarmExistingSession,
    )
    {
        // Pi has no supported context-prefill RPC. The first real turn owns
        // context construction and presentation in its physical Pi order.
        return null;
    }

    string queueSnapshotJson(SessionKey session)
    {
        return store.sessionQueue(session).snapshot().json();
    }

    QueueMutation reserveQueueItem(SessionKey session, QueueReservation reservation)
    {
        return store.sessionQueue(session).reserve(reservation);
    }

    QueueMutation touchQueuePreparation(
        SessionKey session,
        string itemId,
        string progressAt,
        string deadlineAt = "",
    )
    {
        return store.sessionQueue(session).touchPreparation(itemId, progressAt, deadlineAt);
    }

    QueueMutation failQueuePreparation(SessionKey session, string itemId, string failure)
    {
        return store.sessionQueue(session).fail(itemId, failure);
    }

    QueueMutation cancelQueueItem(SessionKey session, string itemId)
    {
        return store.sessionQueue(session).cancel(itemId);
    }

    void compactQueue(SessionKey session)
    {
        store.sessionQueue(session).compactTerminalPrefix();
    }

    void run(
        SessionKey session,
        ConversationTurnRequest request,
        ConversationEventSink sink,
        string fallbackSource = "api_text",
        ConversationPromptPrewarm promptPrewarm = null,
    )
    {
        runQueued(
            session,
            request,
            false,
            UserAudioArtifactRecord(),
            sink,
            fallbackSource,
            promptPrewarm,
        );
    }

    void runWithUserAudio(
        SessionKey session,
        ConversationTurnRequest request,
        UserAudioArtifactRecord userAudio,
        ConversationEventSink sink,
        string fallbackSource = "api_text",
        ConversationPromptPrewarm promptPrewarm = null,
    )
    {
        runQueued(
            session,
            request,
            true,
            userAudio,
            sink,
            fallbackSource,
            promptPrewarm,
        );
    }

    /** Admits through the durable queue, then follows the persisted turn while
        the daemon-owned dispatcher executes it. The observer is not the owner
        of the accepted work and can disappear without cancelling execution. */
    private void runQueued(
        SessionKey session,
        ConversationTurnRequest request,
        bool hasUserAudio,
        UserAudioArtifactRecord userAudio,
        ConversationEventSink sink,
        string fallbackSource,
        ConversationPromptPrewarm promptPrewarm,
    )
    {
        auto admitted = runReportingFailures(
            session,
            request,
            hasUserAudio,
            userAudio,
            sink,
            fallbackSource,
            promptPrewarm,
            false,
            true,
        );
        if (!admitted) return;

        auto turn = store.findTurnBySubmission(session, conversationSubmissionId(request));
        if (!turn.id.length) return;
        if (promptPrewarm !is null) {
            auto guard = scopedMutexLock(promptMutex);
            pendingPromptPrewarms[conversationSubmissionId(request)] = promptPrewarm;
        }
        auto afterSequence = cast(long) store.conversationEventSequence(session, turn.id);
        wakeQueue(session);
        ConversationEventStream follow;
        replayExistingSubmission(session, turn, afterSequence, sink, follow);
    }

    private bool runReportingFailures(
        SessionKey session,
        ConversationTurnRequest request,
        bool hasUserAudio,
        UserAudioArtifactRecord userAudio,
        ConversationEventSink sink,
        string fallbackSource,
        ConversationPromptPrewarm promptPrewarm,
        bool recoverExisting,
        bool admitOnly = false,
    )
    {
        auto submissionId = conversationSubmissionId(request);
        ConversationEventStream events;
        try {
            return runInternal(
                session,
                request,
                hasUserAudio,
                userAudio,
                sink,
                events,
                fallbackSource,
                promptPrewarm,
                recoverExisting,
                admitOnly,
            );
        } catch (Exception error) {
            if (admitOnly)
                failAdmissionQueueItem(session, submissionId, error.msg);
            if (events is null)
                events = new ConversationEventStream(session, submissionId, sink);
            events.fail("turn", error.msg);
            return false;
        }
    }

    private void failAdmissionQueueItem(
        SessionKey session,
        string submissionId,
        string failure,
    )
    {
        try {
            auto queue = store.sessionQueue(session);
            auto item = queue.snapshot().find(submissionId);
            if (item is null
                || (item.state != QueueItemState.preparing
                    && item.state != QueueItemState.ready)) return;

            auto mutation = queue.fail(submissionId, failure);
            auto turn = store.findTurnBySubmission(session, submissionId);
            if (turn.id.length && (turn.status == "pending" || turn.status == "running")) {
                store.failInterruptedConversationTurn(
                    session,
                    turn.id,
                    nowIso(),
                    failure,
                );
            }
            if (projectQueueMutation(store, session, mutation))
                queue.compactTerminalPrefix();
            wakeQueue(session);
        } catch (Exception) {
            // Preserve the original admission failure. Startup recovery or the
            // preparation watchdog can reconcile an unavailable queue store.
        }
    }

    private bool runInternal(
        SessionKey session,
        ConversationTurnRequest request,
        bool hasUserAudio,
        UserAudioArtifactRecord userAudio,
        ConversationEventSink sink,
        ref ConversationEventStream events,
        string fallbackSource,
        ConversationPromptPrewarm promptPrewarm,
        bool recoverExisting,
        bool admitOnly,
    )
    {
        enforce(store.profileExists(session.profileId), "Profile not found");
        auto userText = request.text.strip;
        enforce(userText.length > 0 || request.hasUserImage,
            "Turn requires text, voice, or an image");
        auto source = conversationTurnSource(request, fallbackSource);
        auto submissionId = conversationSubmissionId(request);
        auto model = models.chatModel(
            request.model.length ? request.model : store.sessionModel(session),
        );
        auto admittedReasoningMode = request.reasoningMode;
        auto oneShotHighestReasoning = source != "scheduled_task" && promptStartsWithThink(userText);
        if (oneShotHighestReasoning)
            request.reasoningMode = model.reasoningModes[$ - 1];
        else if (source == "scheduled_task") {
            auto exactReasoning = scheduledTaskUsesNewSession(request);
            if (exactReasoning) enforce(
                model.reasoningModes.canFind(request.reasoningMode),
                "Scheduled task model " ~ model.key ~ " does not support reasoning effort "
                    ~ reasoningModeText(request.reasoningMode),
            );
            else request.reasoningMode = nearestReasoningMode(
                model.reasoningModes,
                request.reasoningMode,
            );
        }
        else enforce(
            model.reasoningModes.canFind(request.reasoningMode),
            "Selected model does not support reasoning mode "
                ~ reasoningModeText(request.reasoningMode) ~ ": " ~ model.key,
        );
        enforce(
            model.vision || (!request.hasUserImage && !store.sessionHasUserImage(session)),
            "A model with image support is required for this session: " ~ model.key,
        );
        auto startedAt = request.startedAtOverride.strip.length ? request.startedAtOverride.strip : nowIso();
        auto sessionLanguage = store.sessionLanguage(session);
        preparations.wait(session);

        auto resolved = profiles.resolveSession(
            session.profileId,
            sessionLanguage.length ? sessionLanguage : request.language,
        );
        auto settings = loadProfileRuntimeSettings(
            resolved,
            model,
            imageGenerationAvailable(),
            request.reasoningMode,
        );
        settings.screenCaptureScope = clientTools.captureScreenScope(
            session.profileId,
            request.deviceId,
        );
        settings.tools.captureScreen = settings.tools.captureScreen
            && model.vision
            && settings.screenCaptureScope.length > 0;
        auto submissionJson = conversationSubmissionJson(
            request,
            source,
            settings.language,
            model.key,
            userText,
            hasUserAudio,
            request.hasUserImage,
            request.userImage,
        );
        auto queue = store.sessionQueue(session);
        auto schedulerTools = scheduledTriggerTool(request, startedAt, "queued");
        StoredTurn existing;
        string turnId;
        QueueMutation queueMutation;
        {
            // Acceptance has its own short lane. The execution lane may be held
            // by an older turn for minutes, but that must not prevent a newer
            // request from becoming durable and visibly queued.
            auto admissionLane = admissionLanes.get(session);
            auto admissionGuard = scopedMutexLock(admissionLane);
            existing = store.findTurnBySubmission(session, submissionId);
            if (!existing.id.length) {
                // Queue admission is the only ordering boundary. Pi steering
                // cannot safely claim around an earlier durable queue item,
                // so execution uses the ordinary dispatcher path below.
                enforce(request.afterSequence == 0, "New submission replay cursor must be zero");
                store.setSessionLanguage(session, settings.language);
                if (source != "scheduled_task")
                    store.setSessionModel(session, model.key);
                if (source != "scheduled_task" && !oneShotHighestReasoning)
                    store.setSessionReasoningMode(session, request.reasoningMode);
                auto initialAudio = userAudioForSave(hasUserAudio, userAudio);
                auto queueSnapshot = queue.snapshot();
                auto reservedQueueItem = queueSnapshot.find(submissionId);
                if (reservedQueueItem !is null) {
                    enforce(reservedQueueItem.fingerprint.length,
                        "Session queue item has no admission fingerprint");
                    enforce(reservedQueueItem.source == source,
                        "Prepared submission source changed after queue admission");
                    enforce(reservedQueueItem.deviceId == request.deviceId,
                        "Prepared submission device changed after queue admission");
                    enforce(reservedQueueItem.model == model.key,
                        "Prepared submission model changed after queue admission");
                    enforce(
                        reservedQueueItem.reasoningMode
                            == reasoningModeText(admittedReasoningMode),
                        "Prepared submission reasoning mode changed after queue admission",
                    );
                    enforce(reservedQueueItem.language == settings.language,
                        "Prepared submission language changed after queue admission");
                    enforce(reservedQueueItem.loadMemory == request.loadMemory,
                        "Prepared submission memory policy changed after queue admission");
                    queueMutation = queue.prepare(
                        submissionId,
                        userText,
                        initialAudio.hasUserAudio ? initialAudio.userAudio.artifactKey : "",
                        initialAudio.hasUserAudio ? initialAudio.userAudio.artifactKey : "",
                        reasoningModeText(request.reasoningMode),
                    );
                } else {
                    queueMutation = queue.reserve(QueueReservation(
                        submissionId,
                        session.sessionId,
                        source == "scheduled_task" ? "scheduled" : "user",
                        source,
                        request.deviceId,
                        startedAt,
                        userText,
                        model.key,
                        reasoningModeText(request.reasoningMode),
                        settings.language,
                        initialAudio.hasUserAudio ? initialAudio.userAudio.artifactKey : "",
                        initialAudio.hasUserAudio ? initialAudio.userAudio.artifactKey : "",
                        submissionJson,
                        true,
                        "",
                        request.loadMemory,
                    ));
                }
                enforce(queueMutation.item.id == submissionId
                    && queueMutation.item.state == QueueItemState.ready,
                    "Session queue changed the accepted item ID");
                turnId = store.beginTextTurn(TextTurnRecord(
                    submissionId,
                    session.profileId,
                    session.sessionId,
                    request.deviceId,
                    source,
                    "pending",
                    startedAt,
                    "",
                    settings.assistantModel,
                    settings.language,
                    userText,
                    "",
                    "",
                    false,
                    0,
                    "",
                    initialAudio.hasUserAudio,
                    initialAudio.userAudio,
                    request.reasoningMode,
                    hasUserAudio,
                    submissionId,
                    "",
                    submissionJson,
                    request.hasUserImage,
                    request.userImage,
                ));
                if (userText.length) {
                    if (!request.scheduledTriggerJson.length) store.appendSessionAutoMemoryTodoOnce(
                        session,
                        turnId,
                        startedAt,
                        settings.language,
                        userText,
                    );
                }
                events = new ConversationEventStream(
                    session,
                    turnId,
                    durableEventSink(sink),
                );
                events.status(
                    "conversation_accepted",
                    "Conversation turn accepted.",
                    jsonObject([
                        jsonStringField("user_text", userText),
                        jsonStringField("model", settings.assistantModel),
                        jsonStringField(
                            "reasoning_mode",
                            reasoningModeText(request.reasoningMode),
                        ),
                        jsonStringField("source", source),
                        jsonStringField("submission_id", submissionId),
                        jsonStringField("device_id", request.deviceId),
                        jsonUlongField("queue_sequence", queueMutation.item.sequence),
                        jsonStringField("queue_state", queueItemStateText(queueMutation.item.state)),
                        jsonUlongField("queue_revision", queueMutation.revision),
                    ]),
                );
                if (schedulerTools.length) {
                    store.saveRuntimeToolEvents(session.profileId, turnId, schedulerTools);
                }
            }
        }
        if (existing.id.length && !recoverExisting) {
            enforce(
                parseJSON(existing.submissionJson) == parseJSON(submissionJson),
                "Submission ID was reused with a different payload",
            );
            replayExistingSubmission(
                session,
                existing,
                request.afterSequence,
                sink,
                events,
            );
            return false;
        }
        if (admitOnly) return true;
        if (existing.id.length) {
            turnId = existing.id;
            auto previousEvents = store.conversationEvents(session, turnId);
            events = new ConversationEventStream(
                session,
                turnId,
                durableEventSink((_) {}),
                cast(ulong) previousEvents.length + 1,
            );
        }
        auto initialAudio = userAudioForSave(hasUserAudio, userAudio);
        QueueMutation queueClaim;
        if (!agent.available(settings)) return false;
        try {
            queueClaim = queue.claim(submissionId);
        } catch (Exception error) {
            auto cancelled = queue.snapshot().find(submissionId);
                if (cancelled !is null && cancelled.state == QueueItemState.cancelled) {
                    auto cancelledTurn = store.findTurnBySubmission(session, submissionId);
                    if (cancelledTurn.id.length && cancelledTurn.status == "pending")
                        store.cancelPendingConversationTurn(
                            session,
                            cancelledTurn.id,
                            nowIso(),
                        );
                }
            throw error;
        }
        enforce(queueClaim.item.id == submissionId && queueClaim.item.state == QueueItemState.running,
            "Session queue did not claim the earliest ready item");
        auto executionId = store.claimConversationTurn(session, turnId);
        // The scheduler trigger is a durable admission record, not a Pi tool
        // result. Persist the running marker only after the queue claim.
        if (schedulerTools.length) {
            schedulerTools = scheduledTriggerTool(request, startedAt, "running");
            store.saveRuntimeToolEvents(session.profileId, turnId, schedulerTools);
            emitScheduledTrigger(events, request, "start", "running", "is running");
        }
        scope(exit) stops.clear(turnId);
        auto speechSource = speechTurns.begin(session, turnId, settings.language);
        scope(exit) speechTurns.finish(turnId);
        AgentTurnResult result;
        string prewarmMetricsJson;
        long toolCount;
        bool stopped;
        auto turnStartedMono = request.hasAcceptedTurnStartMono
            ? request.acceptedTurnStartMono
            : MonoTime.currTime;
        scope(exit) if (promptPrewarm !is null) promptPrewarm.stop();

        try {
            if (promptPrewarm !is null) prewarmMetricsJson = promptPrewarm.waitMetricsJson();
            events.status(
                "api_text_pi_started",
                settings.thinkingMessage,
                jsonObject([
                    jsonStringField("model", settings.assistantModel),
                    jsonBoolField("load_memory", request.loadMemory),
                ]),
            );
            result = agent.run(AgentTurnInput(
                session,
                turnId,
                userText,
                request.deviceId,
                startedAt,
                settings,
                request.reasoningMode,
                request.loadMemory,
                events,
                (event) => updateSpeechSource(
                    speechSource,
                    event,
                    settings.reasoningWaitMessage,
                ),
                () => stops.stopped(turnId),
                request.hasUserImage,
                agentUserImage(store.findTurn(session, turnId)),
                schedulerTools,
                request.scheduledPrivatePrompt,
            ));
            toolCount = result.toolCount;
            stopped = stops.stopped(turnId);
        } catch (Exception error) {
            if (!stops.stopped(turnId)) {
                auto agentFailure = cast(AgentRuntimeFailure) error;
                ExecutedTool[] failureTools;
                long failureToolCount;
                string failureMetrics;
                string failureReasoningMetrics;
                string failureErrors;
                string failureAssistantText;
                bool hasPiExitStatus;
                int piExitStatus;
                if (agentFailure !is null) {
                    failureTools = agentFailure.tools;
                    failureToolCount = agentFailure.toolCount;
                    failureMetrics = agentFailure.metricsJson;
                    failureReasoningMetrics = agentFailure.reasoningMetricsJson;
                    failureErrors = agentFailure.errorsJson;
                    failureAssistantText = agentFailure.assistantText.strip;
                    hasPiExitStatus = agentFailure.hasExitStatus;
                    piExitStatus = agentFailure.exitStatus;
                }
                auto failedAt = nowIso();
                auto saveAudio = finalUserAudioForSave(hasUserAudio, userAudio, initialAudio);
                if (schedulerTools.length) {
                    auto failedScheduler = scheduledTriggerTool(
                        request,
                        startedAt,
                        "failed",
                        false,
                        cast(double) (MonoTime.currTime - turnStartedMono).total!"msecs" / 1_000,
                        reasoningModeText(request.reasoningMode),
                        error.msg,
                    );
                    failureTools = replaceScheduledTrigger(failureTools, failedScheduler[0]);
                    emitScheduledTrigger(
                        events,
                        request,
                        "end",
                        "failed",
                        "failed",
                        cast(long) (MonoTime.currTime - turnStartedMono).total!"msecs",
                    );
                }
                store.saveRuntimeToolEvents(session.profileId, turnId, failureTools);
                auto storedTurnId = store.saveTextTurn(TextTurnRecord(
                    turnId,
                    session.profileId,
                    session.sessionId,
                    request.deviceId,
                    source,
                    "failed",
                    startedAt,
                    failedAt,
                    settings.assistantModel,
                    settings.language,
                    userText,
                    failureAssistantText,
                    turnMetricsJson(
                        failureMetrics,
                        failureReasoningMetrics,
                        prewarmMetricsJson,
                        request,
                        turnStartedMono,
                        saveAudio,
                        agentFailure !is null && agentFailure.hasFirstAssistantDelta,
                        agentFailure is null ? MonoTime.init : agentFailure.firstAssistantDeltaMono,
                        agentFailure !is null && agentFailure.hasProcessEnd,
                        agentFailure is null ? MonoTime.init : agentFailure.processEndMono,
                        agentFailure !is null && agentFailure.hasLatestAssistantStart,
                        agentFailure is null ? MonoTime.init : agentFailure.latestAssistantStartMono,
                    ),
                    hasPiExitStatus,
                    piExitStatus,
                    failureErrors.length ? failureErrors : turnErrorJson("pi_process", error.msg),
                    saveAudio.hasUserAudio,
                    saveAudio.userAudio,
                    request.reasoningMode,
                    hasUserAudio,
                    submissionId,
                    executionId,
                    submissionJson,
                    request.hasUserImage,
                    request.userImage,
                ));
                QueueMutation terminalQueueMutation;
                if (agentFailure !is null && agentFailure.hasProcessStart) {
                    terminalQueueMutation = queue.interrupt(
                        submissionId,
                        "Pi execution became uncertain after the external process started.",
                    );
                } else {
                    terminalQueueMutation = queue.fail(submissionId, error.msg);
                }
                if (projectQueueMutation(store, session, terminalQueueMutation))
                    queue.compactTerminalPrefix();
                events.status(
                    "api_text_pi_failed",
                    "Pi turn failed.",
                    jsonObject([jsonStringField("error", error.msg)]),
                );
                if (agentFailure !is null) finishSteeredTurns(
                    session,
                    agentFailure.steeredTurns,
                    "failed",
                    error.msg,
                );
                throw error;
            }
            stopped = true;
        }

        auto finalText = result.assistantText.strip;
        auto completedAt = nowIso();
        auto status = stopped ? "stopped" : "completed";
        auto saveAudio = finalUserAudioForSave(hasUserAudio, userAudio, initialAudio);
        if (schedulerTools.length) {
            auto terminalStatus = stopped ? "failed" : "completed";
            auto terminalScheduler = scheduledTriggerTool(
                request,
                startedAt,
                terminalStatus,
                !stopped,
                cast(double) (MonoTime.currTime - turnStartedMono).total!"msecs" / 1_000,
                reasoningModeText(request.reasoningMode),
                stopped ? "Scheduled task run was stopped." : "",
            );
            result.tools = replaceScheduledTrigger(result.tools, terminalScheduler[0]);
            emitScheduledTrigger(
                events,
                request,
                "end",
                stopped ? "failed" : "succeeded",
                stopped ? "failed" : "completed",
                cast(long) (MonoTime.currTime - turnStartedMono).total!"msecs",
            );
        }
        store.saveRuntimeToolEvents(session.profileId, turnId, result.tools);
        auto metricsJson = turnMetricsJson(
            result.metricsJson,
            result.reasoningMetricsJson,
            prewarmMetricsJson,
            request,
            turnStartedMono,
            saveAudio,
            result.hasFirstAssistantDelta,
            result.firstAssistantDeltaMono,
            result.hasProcessEnd,
            result.processEndMono,
            result.hasLatestAssistantStart,
            result.latestAssistantStartMono,
        );
        auto storedTurnId = store.saveTextTurn(TextTurnRecord(
            turnId,
            session.profileId,
            session.sessionId,
            request.deviceId,
            source,
            status,
            startedAt,
            completedAt,
            settings.assistantModel,
            settings.language,
            userText,
            finalText,
            metricsJson,
            false,
            0,
            "",
            saveAudio.hasUserAudio,
            saveAudio.userAudio,
            request.reasoningMode,
            hasUserAudio,
            submissionId,
            executionId,
            submissionJson,
            request.hasUserImage,
            request.userImage,
        ));
        auto terminalQueueMutation = stopped
            ? queue.fail(submissionId, "Conversation turn stopped.")
            : queue.complete(submissionId, "turn:" ~ turnId);
        if (projectQueueMutation(store, session, terminalQueueMutation))
            queue.compactTerminalPrefix();

        finishSteeredTurns(
            session,
            result.steeredTurns,
            stopped ? "stopped" : "completed",
        );

        if (stopped) {
            events.status(
                "api_text_stopped",
                "Text turn stopped.",
                "{}",
            );
        }

        events.complete(conversationTurnResponse(
            storedTurnId,
            session.profileId,
            request.deviceId,
            source,
            startedAt,
            completedAt,
            settings,
            userText,
            finalText,
            status,
            stopped,
            toolCount,
            saveAudio.hasUserAudio ? 1 : 0,
            (saveAudio.hasUserAudio ? 1 : 0)
                + (request.hasUserImage ? 1 : 0)
                + store.generatedImageCount(session, turnId),
            metricsJson,
        ));
        return true;
    }

    private void finishSteeredTurns(
        SessionKey session,
        AgentSteeredTurnResult[] turns,
        string status,
        string errorMessage = "",
    )
    {
        foreach (turn; turns) {
            auto completedAt = nowIso();
            auto stored = store.finishSteeredConversationTurn(
                session,
                turn.turnId,
                status,
                completedAt,
                turn.assistantText,
                turn.metricsJson,
                status == "failed" ? turnErrorJson("pi_process", errorMessage) : "",
            );
            if (status == "stopped") turn.events.status(
                "api_text_stopped",
                "Text turn stopped.",
                "{}",
            );
            if (status == "failed")
                turn.events.fail("turn", errorMessage);
            else turn.events.complete(storedConversationTurnResponse(stored));
        }
    }

    private void replayExistingSubmission(
        SessionKey session,
        StoredTurn turn,
        long afterSequence,
        ConversationEventSink sink,
        ref ConversationEventStream stream,
    )
    {
        enforce(afterSequence >= 0, "Conversation replay cursor cannot be negative");
        auto follower = store.followConversationEvents(
            session,
            turn.id,
            cast(ulong) afterSequence,
        );
        uint terminalWithoutEventPolls;
        while (true) {
            auto events = follower.readAvailable();
            foreach (event; events) sink(event);
            if (events.length) {
                auto kind = events[$ - 1].kind;
                if (kind == ConversationEventKind.completed
                    || kind == ConversationEventKind.failed)
                    return;
            }

            // A repeated request is an observer, never a second executor. The
            // original server-side owner keeps running and appending events even
            // when every HTTP/WebSocket client has disconnected.
            auto current = store.findTurn(session, turn.id);
            enforce(current.id.length, "Conversation turn disappeared during replay");
            auto queued = store.sessionQueue(session).snapshot().find(turn.submissionId);
            if (queued !is null && queued.state == QueueItemState.cancelled) {
                stream = new ConversationEventStream(
                    session,
                    turn.id,
                    sink,
                    follower.sequence + 1,
                );
                stream.fail("cancelled", "Conversation turn was cancelled before execution.");
                return;
            }
            auto terminal = current.status == "completed"
                || current.status == "stopped"
                || current.status == "failed";
            if (terminal) {
                ++terminalWithoutEventPolls;
                if (terminalWithoutEventPolls >= 5) {
                    // The turn record is committed before its terminal journal
                    // event. Normally the next poll observes that event. If a
                    // process/storage interruption left only the turn record,
                    // finish this observer without claiming journal ownership.
                    stream = new ConversationEventStream(
                        session,
                        turn.id,
                        sink,
                        follower.sequence + 1,
                    );
                    if (current.status == "failed")
                        stream.fail(
                            "turn",
                            "Conversation failed before its terminal event was recorded.",
                        );
                    else
                        stream.complete(storedConversationTurnResponse(current));
                    return;
                }
            } else {
                enforce(
                    current.status == "pending" || current.status == "running",
                    "Unsupported persisted Conversation state: " ~ current.status,
                );
                terminalWithoutEventPolls = 0;
            }
            sleep(dur!"msecs"(50));
        }
    }

    private ConversationEventSink durableEventSink(ConversationEventSink sink)
    {
        return (event) {
            event.presentationSequence = store.appendConversationEvent(event);
            sink(event);
        };
    }
}

private ExecutedTool[] scheduledTriggerTool(
    ConversationTurnRequest request,
    string startedAt,
    string lifecycleStatus,
    bool ok = true,
    double durationSeconds = 0,
    string effectiveReasoningMode = "",
    string errorMessage = "",
)
{
    if (!request.scheduledTriggerJson.length) return [];
    auto details = parseJSON(request.scheduledTriggerDetailsJson);
    details.object["lifecycle_status"] = JSONValue(lifecycleStatus);
    if (effectiveReasoningMode.length)
        details.object["effective_reasoning_mode"] = JSONValue(effectiveReasoningMode);
    if (errorMessage.length) details.object["error_message"] = JSONValue(errorMessage);
    return [ExecutedTool(
        "scheduled-task:" ~ Json.object(parseJSON(request.scheduledTriggerJson)).text("occurrence_id"),
        startedAt,
        ToolCall("scheduled_task_trigger", request.scheduledTriggerJson),
        ToolResult("scheduled_task_trigger", ok, jsonObject([
            jsonStringField("text", scheduledTriggerMessage(request, lifecycleStatus)),
            jsonRawField("details", details.toString()),
        ])),
        durationSeconds,
        0,
        "scheduler",
    )];
}

private void emitScheduledTrigger(
    ConversationEventStream events,
    ConversationTurnRequest request,
    string stage,
    string status,
    string verb,
    long durationMs = 0,
)
{
    auto trigger = Json.object(parseJSON(request.scheduledTriggerJson));
    events.tool(ConversationToolEvent(
        stage,
        "scheduled-task:" ~ trigger.text("occurrence_id"),
        "scheduled_task_trigger",
        0,
        status,
        "scheduler",
        "Scheduled task " ~ trigger.text("display_text") ~ " " ~ verb ~ ".",
        false,
        "",
        jsonObject([
            jsonStringField("scheduled_task_id", trigger.text("task_id")),
            jsonStringField("occurrence_id", trigger.text("occurrence_id")),
        ]),
        durationMs,
    ));
}

private string scheduledTriggerMessage(ConversationTurnRequest request, string lifecycleStatus)
{
    auto trigger = Json.object(parseJSON(request.scheduledTriggerJson));
    auto verb = lifecycleStatus == "queued" ? "will run"
        : lifecycleStatus == "running" ? "is running"
        : lifecycleStatus == "completed" ? "completed"
        : "failed";
    return "Scheduled task " ~ trigger.text("display_text") ~ " " ~ verb ~ ".";
}

private ExecutedTool[] replaceScheduledTrigger(ExecutedTool[] tools, ExecutedTool replacement)
{
    foreach (ref tool; tools) {
        if (tool.source != "scheduler") continue;
        tool = replacement;
        return tools;
    }
    return replacement ~ tools;
}

private bool scheduledTaskUsesNewSession(ConversationTurnRequest request)
{
    if (!request.scheduledTriggerDetailsJson.length) return false;
    auto details = Json.object(parseJSON(request.scheduledTriggerDetailsJson));
    return details.object("target").text("kind") == "new_session";
}

private string conversationSubmissionJson(
    ConversationTurnRequest request,
    string source,
    string language,
    string model,
    string userText,
    bool userAudioRequired,
    bool hasUserImage,
    UserImageArtifactRecord userImage,
)
{
    return jsonObject([
        jsonStringField("device_id", request.deviceId),
        jsonStringField("source", source),
        jsonStringField("language", language),
        jsonStringField("model", model),
        jsonStringField("reasoning_mode", reasoningModeText(request.reasoningMode)),
        jsonBoolField("load_memory", request.loadMemory),
        jsonStringField("user_text", userText),
        jsonBoolField("user_audio_required", userAudioRequired),
        hasUserImage ? jsonRawField("user_image", jsonObject([
            jsonStringField("filename", userImage.filename),
            jsonStringField("media_type", userImage.mediaType),
            jsonLongField("bytes", cast(long) userImage.bytes),
        ])) : "",
    ]);
}

private AgentUserImage agentUserImage(StoredTurn turn)
{
    return turn.hasUserImage
        ? AgentUserImage(turn.userImagePath, turn.userImageMediaType)
        : AgentUserImage();
}

private string turnMetricsJson(
    string llmMetricsJson,
    string reasoningMetricsJson,
    string prewarmMetricsJson,
    ConversationTurnRequest request,
    MonoTime turnStartedMono,
    SaveUserAudio audio,
    bool hasFirstAssistantDelta,
    MonoTime firstAssistantDeltaMono,
    bool hasProcessEnd,
    MonoTime processEndMono,
    bool hasLatestAssistantStart,
    MonoTime latestAssistantStartMono,
)
{
    auto totalMs = cast(long) (MonoTime.currTime - turnStartedMono).total!"msecs";
    auto activityMs = hasLatestAssistantStart
        ? cast(long) (latestAssistantStartMono - turnStartedMono).total!"msecs"
        : -1;
    auto audioMetrics = audioMetricsJson(request.audioMetricsJson, audio);
    auto turnMetrics = turnMetricsGroupJson(
        request.turnMetricsJson,
        totalMs,
        request.hasAcceptedTurnStartMono,
        request.acceptedTurnStartMono,
        hasFirstAssistantDelta,
        firstAssistantDeltaMono,
        hasProcessEnd,
        processEndMono,
        activityMs,
    );
    return jsonObject([
        llmMetricsJson.length ? jsonRawField("llm", jsonObjectRaw(llmMetricsJson)) : "",
        reasoningMetricsJson.length
            ? jsonRawField("reasoning", jsonObjectRaw(reasoningMetricsJson))
            : "",
        prewarmMetricsJson.length
            ? jsonRawField("prewarm", jsonObjectRaw(prewarmMetricsJson))
            : "",
        audioMetrics.length ? jsonRawField("audio", audioMetrics) : "",
        request.sttMetricsJson.length
            ? jsonRawField("stt", jsonObjectRaw(request.sttMetricsJson))
            : "",
        jsonRawField("turn", turnMetrics),
    ]);
}

private void updateSpeechSource(
    TurnSpeechTurn source,
    AgentContentEvent event,
    string reasoningWaitMessage,
)
{
    if (event.kind == "tool") {
        enforce(event.phase == "delta", "Unknown tool speech phase");
        source.feedProgress(event.text);
        return;
    }
    if (event.phase == "start") return;
    if (event.phase == "end") {
        source.finishItem(event.kind == "assistant" ? "answer" : "reasoning", event.itemId);
        return;
    }
    enforce(event.phase == "delta", "Unknown Pi content phase");
    if (event.kind == "assistant") {
        source.feedAnswer(event.itemId, event.text);
    } else {
        enforce(event.kind == "reasoning", "Unknown Pi content kind");
        source.feedReasoning(event.itemId, event.text, reasoningWaitMessage);
    }
}

private string audioMetricsJson(string existingJson, SaveUserAudio audio)
{
    string[] fields;
    JSONValue existingObject = existingJson.length
        ? parseJSON(jsonObjectRaw(existingJson))
        : parseJSON("{}");
    if (audio.hasUserAudio && audio.userAudio.hasDuration && !hasField(existingObject, "accepted_seconds")) {
        fields ~= jsonRawField("accepted_seconds", format!"%.3f"(audio.userAudio.durationSeconds));
    }
    if (audio.hasUserAudio && audio.userAudio.hasOpusEncodeMs && !hasField(existingObject, "opus_encode_ms")) {
        fields ~= jsonLongField("opus_encode_ms", audio.userAudio.opusEncodeMs);
    }
    return appendJsonObjectFields(existingJson.length ? existingJson : "{}", fields);
}

private string turnMetricsGroupJson(
    string existingJson,
    long totalMs,
    bool hasAcceptedTurnStartMono,
    MonoTime acceptedTurnStartMono,
    bool hasFirstAssistantDelta,
    MonoTime firstAssistantDeltaMono,
    bool hasProcessEnd,
    MonoTime processEndMono,
    long activityMs,
)
{
    string[] fields;
    fields ~= jsonLongField("total_ms", totalMs);
    if (activityMs >= 0) fields ~= jsonLongField("activity_ms", activityMs);
    if (hasAcceptedTurnStartMono && hasFirstAssistantDelta) {
        fields ~= jsonLongField(
            "endpoint_to_first_token_ms",
            cast(long) (firstAssistantDeltaMono - acceptedTurnStartMono).total!"msecs",
        );
    }
    if (hasAcceptedTurnStartMono && hasProcessEnd) {
        fields ~= jsonLongField(
            "endpoint_to_response_done_ms",
            cast(long) (processEndMono - acceptedTurnStartMono).total!"msecs",
        );
    }
    return appendJsonObjectFields(existingJson.length ? existingJson : "{}", fields);
}

private string appendJsonObjectFields(string objectJson, string[] fields)
{
    auto addition = joinFields(fields);
    if (!objectJson.length && !addition.length) return "";

    auto object = parseJSON(jsonObjectRaw(objectJson));
    if (addition.length) {
        auto additions = parseJSON("{" ~ addition ~ "}");
        foreach (name, value; additions.objectNoRef) {
            object.object[name] = value;
        }
    }
    return object.toString();
}

private string joinFields(string[] fields)
{
    string output;
    foreach (field; fields) {
        if (!field.length) continue;
        if (output.length) output ~= ",";
        output ~= field;
    }
    return output;
}

private bool hasField(T)(T payload, string name)
{
    return (name in payload.objectNoRef) !is null;
}

private string turnErrorJson(string stage, string message)
{
    return jsonObject([
        jsonRawField("errors", "[" ~ jsonObject([
            jsonStringField("stage", stage.length ? stage : "unknown"),
            jsonStringField("recorded_at", nowIso()),
            jsonStringField("message", message),
        ]) ~ "]"),
    ]);
}

private struct SaveUserAudio
{
    bool hasUserAudio;
    UserAudioArtifactRecord userAudio;
}

private SaveUserAudio userAudioForSave(
    bool hasUserAudio,
    UserAudioArtifactRecord userAudio,
)
{
    if (hasUserAudio && userAudio.artifactKey.length) {
        return SaveUserAudio(true, userAudio);
    }
    return SaveUserAudio(false, UserAudioArtifactRecord());
}

private SaveUserAudio finalUserAudioForSave(
    bool hasUserAudio,
    UserAudioArtifactRecord userAudio,
    SaveUserAudio initialAudio,
)
{
    if (initialAudio.hasUserAudio) return initialAudio;
    return userAudioForSave(hasUserAudio, userAudio);
}
