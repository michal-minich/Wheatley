module wheatley.server.conversation.remote_http_port;

import std.exception : enforce;
import std.file : exists, remove;

import wheatley.common.api.accepted_voice_artifact : AcceptedVoiceArtifact;
import wheatley.common.api.session : SessionKey;
import wheatley.common.conversation.events : ConversationEventSink;
import wheatley.server.conversation.port :
    ConversationPort,
    ConversationPreparationPort,
    ConversationPromptPrewarm;
import wheatley.server.conversation.preparation :
    ConversationPreparation,
    ConversationPreparationGate;
import wheatley.server.conversation.remote_delivery : RemoteConversationDelivery;
import wheatley.server.conversation.remote_http_peer : RemoteConversationHttpPeer;
import wheatley.server.conversation.remote_peer : RemoteConversationPeer;
import wheatley.server.conversation.turn_request :
    ConversationTurnRequest,
    conversationTurnSource;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.queue.session_queue :
    QueueItemState,
    QueueMutation,
    QueueReservation,
    SessionQueue;
import wheatley.server.sync.remote_turn_placement : RemoteTurnPlacementGate;
import wheatley.server.tts.turn_speech_registry : TurnSpeechRegistry;
import wheatley.server.voice.accepted_manifest :
    acceptedVoiceArtifact,
    acceptedVoiceManifest,
    acceptedVoiceManifestPath,
    loadAcceptedVoiceManifest,
    writeAcceptedVoiceManifest;

/// Complete remote Conversation placement: execution stays authoritative on
/// one paired server while voice capture, narration, and TTS remain local.
final class RemoteConversationHttpPort : ConversationPort, ConversationPreparationPort
{
    private RemoteTurnPlacementGate gate;
    private RemoteConversationPeer peer;
    private TurnSpeechRegistry speechTurns;
    private ConversationPreparationGate preparations;

    this(
        string apiBase,
        RemoteTurnPlacementGate gate,
        TurnSpeechRegistry speechTurns,
    )
    {
        this(new RemoteConversationHttpPeer(apiBase), gate, speechTurns);
    }

    this(
        RemoteConversationPeer peer,
        RemoteTurnPlacementGate gate,
        TurnSpeechRegistry speechTurns,
    )
    {
        enforce(peer !is null, "Remote Conversation peer is required");
        enforce(gate !is null, "Remote Conversation placement gate is required");
        enforce(speechTurns !is null, "Remote Conversation speech registry is required");
        this.peer = peer;
        this.gate = gate;
        this.speechTurns = speechTurns;
        this.preparations = new ConversationPreparationGate;
    }

    bool performsLocalAgentStartup()
    {
        return false;
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
        bool prewarmExistingSession,
    )
    {
        return null;
    }

    string queueSnapshotJson(SessionKey session)
    {
        return peer.queueSnapshotJson(session);
    }

    QueueMutation reserveQueueItem(SessionKey session, QueueReservation reservation)
    {
        // Materialize the session before the remote queue write. The sync
        // importer requires an absent session root; a queue-only directory
        // created first would make the handoff irrecoverably partial. This
        // gate also serializes competing first admissions from this device.
        gate.prepare(session);
        return peer.reserveQueueItem(session, reservation);
    }

    QueueMutation touchQueuePreparation(
        SessionKey session,
        string itemId,
        string progressAt,
        string deadlineAt = "",
    )
    {
        return peer.touchQueuePreparation(session, itemId, progressAt, deadlineAt);
    }

    QueueMutation failQueuePreparation(SessionKey session, string itemId, string failure)
    {
        return peer.failQueuePreparation(session, itemId, failure);
    }

    QueueMutation cancelQueueItem(SessionKey session, string itemId)
    {
        return peer.cancelQueueItem(session, itemId);
    }

    void compactQueue(SessionKey session)
    {
        peer.compactQueue(session);
    }

    void run(
        SessionKey session,
        ConversationTurnRequest request,
        ConversationEventSink sink,
        string fallbackSource = "api_text",
        ConversationPromptPrewarm promptPrewarm = null,
    )
    {
        enforce(promptPrewarm is null,
            "Remote Conversation cannot use a local prompt prewarm");
        enforce(!request.hasUserImage,
            "Image turns require local Conversation placement");
        request.turn.source = conversationTurnSource(request, fallbackSource);
        gate.prepare(session);
        stream(session, request, sink, (remoteSink) {
            peer.streamText(session.profileId, request.turn, remoteSink);
        });
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
        enforce(promptPrewarm is null,
            "Remote Conversation cannot use a local prompt prewarm");
        enforce(!request.hasUserImage,
            "Image turns require local Conversation placement");
        request.turn.source = conversationTurnSource(request, fallbackSource);
        auto artifact = resolveAcceptedArtifact(session, request, userAudio);
        auto uploadPath = exists(userAudio.stagedPath) ? userAudio.stagedPath : "";
        gate.prepareAcceptedVoice(session, artifact, uploadPath);
        stream(
            session,
            request,
            sink,
            (remoteSink) {
                peer.streamAcceptedVoice(
                    session.profileId,
                    artifact.submissionId,
                    artifact.reasoningMode,
                    artifact.model,
                    request.afterSequence,
                    remoteSink,
                );
            },
            () {
                if (exists(userAudio.stagedPath)) remove(userAudio.stagedPath);
            },
        );
    }

    void wake(SessionKey session)
    {
        // The paired Conversation host owns dispatch for remote placement.
    }

    void stop(SessionKey session, string turnId)
    {
        peer.stop(session, turnId);
    }

    string compact(SessionKey session)
    {
        throw new Exception("Context compaction is only available on the Conversation host");
    }

    void shutdown()
    {
    }

    private void stream(
        SessionKey session,
        ConversationTurnRequest request,
        ConversationEventSink sink,
        void delegate(ConversationEventSink remoteSink) start,
        void delegate() afterMaterialized = null,
    )
    {
        RemoteConversationDelivery delivery;
        delivery = new RemoteConversationDelivery(
            session,
            request.afterSequence,
            request.language,
            gate,
            speechTurns,
            sink,
            afterMaterialized,
        );
        scope(exit) delivery.close();
        start((event) { delivery.accept(event); });
        delivery.finish();
    }

    private AcceptedVoiceArtifact resolveAcceptedArtifact(
        SessionKey session,
        ConversationTurnRequest request,
        UserAudioArtifactRecord audio,
    )
    {
        enforce(request.sessionId == session.sessionId,
            "Accepted voice request session changed");
        enforce(audio.profileId == session.profileId,
            "Accepted voice audio profile changed");
        enforce(audio.stagedPath.length, "Accepted voice staging path is required");
        auto sidecarPath = acceptedVoiceManifestPath(audio.stagedPath);
        if (!exists(audio.stagedPath)) {
            enforce(exists(sidecarPath),
                "Accepted voice artifact is unavailable for remote replay");
            auto saved = loadAcceptedVoiceManifest(audio.stagedPath);
            enforceAcceptedRequestMatches(
                saved.artifact,
                session,
                request,
                audio,
            );
            return saved.artifact;
        }

        auto artifact = acceptedVoiceArtifact(session.profileId, request, audio);
        if (exists(sidecarPath)) {
            auto saved = loadAcceptedVoiceManifest(audio.stagedPath);
            enforce(saved.artifact == artifact,
                "Accepted voice sidecar conflicts with the Conversation request");
        } else {
            writeAcceptedVoiceManifest(acceptedVoiceManifest(artifact, audio.stagedPath));
        }
        return artifact;
    }
}

private void enforceAcceptedRequestMatches(
    AcceptedVoiceArtifact artifact,
    SessionKey session,
    ConversationTurnRequest request,
    UserAudioArtifactRecord audio,
)
{
    enforce(artifact.profileId == session.profileId,
        "Accepted voice replay profile changed");
    enforce(artifact.sessionId == session.sessionId,
        "Accepted voice replay session changed");
    enforce(artifact.submissionId == request.submissionId,
        "Accepted voice replay submission changed");
    enforce(artifact.artifactKey == audio.artifactKey,
        "Accepted voice replay artifact key changed");
    enforce(artifact.source == request.source,
        "Accepted voice replay source changed");
    enforce(artifact.userText == request.text,
        "Accepted voice replay text changed");
    enforce(artifact.language == request.language,
        "Accepted voice replay language changed");
    enforce(artifact.deviceId == request.deviceId,
        "Accepted voice replay device changed");
    enforce(artifact.loadMemory == request.loadMemory,
        "Accepted voice replay memory policy changed");
    enforce(artifact.reasoningMode == request.reasoningMode,
        "Accepted voice replay reasoning mode changed");
    enforce(artifact.model == request.model,
        "Accepted voice replay model changed");
    enforce(artifact.audioCreatedAt == audio.createdAt,
        "Accepted voice replay creation time changed");
    enforce(artifact.bytes == audio.bytes,
        "Accepted voice replay byte count changed");
    enforce(artifact.audioDurationSeconds == audio.durationSeconds
        && artifact.audioHasDuration == audio.hasDuration,
        "Accepted voice replay duration changed");
    enforce(artifact.audioOpusEncodeMs == audio.opusEncodeMs
        && artifact.audioHasOpusEncodeMs == audio.hasOpusEncodeMs,
        "Accepted voice replay encode metrics changed");
    enforce(artifact.startedAtOverride == request.startedAtOverride,
        "Accepted voice replay start time changed");
    enforce(artifact.audioMetricsJson == request.audioMetricsJson,
        "Accepted voice replay audio metrics changed");
    enforce(artifact.sttMetricsJson == request.sttMetricsJson,
        "Accepted voice replay STT metrics changed");
    enforce(artifact.turnMetricsJson == request.turnMetricsJson,
        "Accepted voice replay turn metrics changed");
}

unittest
{
    import std.exception : assertThrown;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.common.api.text_turn : TextTurnRequest;
    import wheatley.common.conversation.events : ConversationEvent, ConversationEventKind;
    import wheatley.server.conversation.turn_request : conversationTurnRequest;

    auto session = SessionKey("tester", "2026/08/05/12_00_00");
    auto turnId = "tester/sessions/2026/08/05/12_00_00/turns/12_00_01_000001";
    auto trace = new RemotePortTestTrace;
    auto gate = new RemotePortTestGate(trace);
    auto peer = new RemotePortTestPeer(trace, session, turnId);
    auto registry = new TurnSpeechRegistry;
    auto port = new RemoteConversationHttpPort(peer, gate, registry);
    auto request = conversationTurnRequest(TextTurnRequest(
        session.sessionId, "Hello", "submission-a", "device", "en", "", true,
        ReasoningMode.off, "model", 0,
    ));
    bool terminalAfterMaterialization;
    port.run(session, request, (event) {
        if (event.kind == ConversationEventKind.completed) {
            terminalAfterMaterialization = gate.materialized;
            assert(registry.find(session, turnId).source("answer").snapshot().text ==
                "I'm searching. Remote answer.");
        }
    }, "voice_typed");
    assert(peer.textRequest.source == "voice_typed");
    assert(trace.steps[0 .. 2] == ["prepare", "text"]);
    assert(terminalAfterMaterialization);

    // The replay cursor remains authoritative and starts the next gap-free event.
    peer.replayOnly = true;
    request.afterSequence = 4;
    port.run(session, request, (event) {
        assert(event.sequence >= 5);
    }, "voice_typed");
    assert(peer.textRequest.afterSequence == 4);

    // Accepted audio uses the paired artifact gate, retains its sidecar, and
    // removes only the staged Opus after exact terminal materialization.
    auto root = buildPath(tempDir(), "wheatley-remote-port-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    auto opusPath = buildPath(root, "accepted.opus");
    write(opusPath, cast(ubyte[]) [1, 2, 3]);
    auto audio = UserAudioArtifactRecord(
        "runtime-user-audio:submission-a", "tester", "2026-08-05T12:00:00Z",
        opusPath, 3, 1, true, 4, true,
    );
    request.afterSequence = 0;
    request.turn.source = "";
    peer.replayOnly = false;
    peer.acceptedMode = true;
    port.runWithUserAudio(session, request, audio, (_) {}, "audio_live");
    assert(gate.acceptedArtifact.source == "audio_live");
    assert(gate.acceptedOpusPath == opusPath);
    assert(!exists(opusPath));
    assert(exists(acceptedVoiceManifestPath(opusPath)));

    // A commit replay needs no local Opus and does not execute a local fallback.
    request.afterSequence = 1;
    peer.replayOnly = true;
    port.runWithUserAudio(session, request, audio, (_) {}, "audio_live");
    assert(gate.acceptedOpusPath == "");

    port.stop(session, turnId);
    assert(peer.stopCount == 1);
    assert(!port.performsLocalAgentStartup());
    assert(port.startPromptPrewarm(session, "en", true, true) is null);

    auto queueReservation = QueueReservation(
        "queue-a", session.sessionId, "user", "audio_live", "device",
        "2026-08-05T12:00:00Z", "", "model", "off", "en",
        "runtime-user-audio:queue-a", "runtime-user-audio:queue-a",
        "queue-fingerprint", false,
    );
    auto queueMutation = port.reserveQueueItem(session, queueReservation);
    assert(queueMutation.item.sequence == 1 && trace.steps[$ - 1] == "prepare");
    assert(port.queueSnapshotJson(session).length);
    port.touchQueuePreparation(session, "queue-a", "2026-08-05T12:00:01Z");
    assert(port.cancelQueueItem(session, "queue-a").item.state == QueueItemState.cancelled);
    port.compactQueue(session);
    assert(peer.queue.items.length == 0);

    peer.failStream = true;
    request.afterSequence = 0;
    assertThrown!Exception(port.run(session, request, (_) {}, "voice_typed"));
    assert(peer.textCount == 3);
}

private final class RemotePortTestTrace
{
    string[] steps;
}

private final class RemotePortTestGate : RemoteTurnPlacementGate
{
    private RemotePortTestTrace trace;
    bool materialized;
    AcceptedVoiceArtifact acceptedArtifact;
    string acceptedOpusPath;

    this(RemotePortTestTrace trace)
    {
        this.trace = trace;
    }

    void prepare(SessionKey session)
    {
        trace.steps ~= "prepare";
    }

    void prepareAcceptedVoice(
        SessionKey session,
        AcceptedVoiceArtifact artifact,
        string opusPath,
    )
    {
        trace.steps ~= "accepted_prepare";
        acceptedArtifact = artifact;
        acceptedOpusPath = opusPath;
    }

    void materializeTerminalTurn(SessionKey session, string turnId)
    {
        trace.steps ~= "materialize";
        materialized = true;
    }
}

private final class RemotePortTestPeer : RemoteConversationPeer
{
    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.common.api.text_turn :
        TextTurnRequest,
        TextTurnResponse,
        TextTurnResponseTurn;
    import wheatley.common.conversation.events :
        ConversationAssistantDelta,
        ConversationEvent,
        ConversationEventKind,
        ConversationStatusEvent,
        ConversationToolEvent;

    private RemotePortTestTrace trace;
    private SessionKey session;
    private string turnId;
    TextTurnRequest textRequest;
    int textCount;
    int acceptedCount;
    int stopCount;
    bool acceptedMode;
    bool replayOnly;
    bool failStream;
    SessionQueue queue;

    this(RemotePortTestTrace trace, SessionKey session, string turnId)
    {
        this.trace = trace;
        this.session = session;
        this.turnId = turnId;
        this.queue = new SessionQueue(session.sessionId);
    }

    string queueSnapshotJson(SessionKey session)
    {
        return queue.json();
    }

    QueueMutation reserveQueueItem(SessionKey session, QueueReservation reservation)
    {
        return queue.reserve(reservation);
    }

    QueueMutation touchQueuePreparation(
        SessionKey session,
        string itemId,
        string progressAt,
        string deadlineAt,
    )
    {
        return queue.touchPreparation(itemId, progressAt, deadlineAt);
    }

    QueueMutation failQueuePreparation(SessionKey session, string itemId, string failure)
    {
        return queue.fail(itemId, failure);
    }

    QueueMutation cancelQueueItem(SessionKey session, string itemId)
    {
        return queue.cancel(itemId);
    }

    void compactQueue(SessionKey session)
    {
        queue.compactTerminalPrefix();
    }

    void streamText(
        string profileId,
        TextTurnRequest request,
        ConversationEventSink sink,
    )
    {
        trace.steps ~= "text";
        textRequest = request;
        textCount++;
        if (failStream) throw new Exception("upstream unavailable");
        emit(request.afterSequence, sink);
    }

    void streamAcceptedVoice(
        string profileId,
        string submissionId,
        ReasoningMode reasoningMode,
        string model,
        long afterSequence,
        ConversationEventSink sink,
    )
    {
        trace.steps ~= "accepted";
        acceptedCount++;
        emit(afterSequence, sink);
    }

    void stop(SessionKey session, string turnId)
    {
        stopCount++;
    }

    private void emit(long afterSequence, ConversationEventSink sink)
    {
        auto sequence = cast(ulong) afterSequence + 1;
        if (!replayOnly) {
            auto status = testEvent(sequence++, ConversationEventKind.status);
            status.status = ConversationStatusEvent("started", "Thinking", "{}");
            sink(status);
            auto tool = testEvent(sequence++, ConversationEventKind.tool);
            tool.tool = ConversationToolEvent(
                "start", "tool-1", "web_search", 0, "running", "", "", false,
                "I'm searching.",
            );
            sink(tool);
        }
        auto delta = testEvent(sequence++, ConversationEventKind.assistantDelta);
        delta.assistantDelta = ConversationAssistantDelta("answer-1", "Remote answer.");
        sink(delta);
        auto completed = testEvent(sequence, ConversationEventKind.completed);
        completed.completed = TextTurnResponse(TextTurnResponseTurn(
            turnId, session.profileId, "device", acceptedMode ? "audio_live" : "voice_typed",
            "completed", "2026-08-05T12:00:01Z", "2026-08-05T12:00:02Z",
            "model", "en", "Hello", "Remote answer.",
            acceptedMode ? 1 : 0, acceptedMode ? 1 : 0, 1,
        ), false, "[]");
        sink(completed);
    }

    private ConversationEvent testEvent(ulong sequence, ConversationEventKind kind)
    {
        ConversationEvent event;
        event.session = session;
        event.turnId = turnId;
        event.sequence = sequence;
        event.timestamp = "2026-08-05T12:00:01Z";
        event.kind = kind;
        return event;
    }
}
