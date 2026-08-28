module wheatley.server.conversation.remote_delivery;

import std.exception : enforce;

import wheatley.common.api.accepted_voice_artifact : AcceptedVoiceArtifact;
import wheatley.common.api.session : SessionKey;
import wheatley.common.conversation.events :
    ConversationEvent,
    ConversationEventKind,
    ConversationEventSink;
import wheatley.server.conversation.speech_projection : projectConversationSpeech;
import wheatley.server.sync.remote_turn_placement : RemoteTurnPlacementGate;
import wheatley.server.tts.turn_speech_registry : TurnSpeechRegistry, TurnSpeechTurn;

/// Validates and exposes one authoritative remote event stream locally.
final class RemoteConversationDelivery
{
    private SessionKey session;
    private ulong lastSequence;
    private string turnId;
    private string language;
    private string reasoningStatus;
    private bool terminal;
    private RemoteTurnPlacementGate gate;
    private TurnSpeechRegistry speechTurns;
    private TurnSpeechTurn speech;
    private ConversationEventSink sink;
    private void delegate() afterMaterialized;

    this(
        SessionKey session,
        long afterSequence,
        string language,
        RemoteTurnPlacementGate gate,
        TurnSpeechRegistry speechTurns,
        ConversationEventSink sink,
        void delegate() afterMaterialized = null,
    )
    {
        enforce(afterSequence >= 0, "Remote Conversation replay cursor cannot be negative");
        enforce(gate !is null, "Remote turn placement gate is required");
        enforce(speechTurns !is null, "Remote Conversation speech registry is required");
        enforce(sink !is null, "Remote Conversation event sink is required");
        this.session = session;
        this.lastSequence = cast(ulong) afterSequence;
        this.language = language;
        this.gate = gate;
        this.speechTurns = speechTurns;
        this.sink = sink;
        this.afterMaterialized = afterMaterialized;
    }

    void accept(ConversationEvent event)
    {
        enforce(!terminal, "Remote Conversation emitted after its terminal event");
        enforce(event.session == session, "Remote Conversation event session changed");
        enforce(event.turnId.length, "Remote Conversation event turn is empty");
        enforce(!turnId.length || event.turnId == turnId,
            "Remote Conversation event turn changed");
        enforce(event.sequence == lastSequence + 1,
            "Remote Conversation event sequence gap");
        turnId = event.turnId;
        lastSequence = event.sequence;
        ensureSpeech();

        if (event.kind == ConversationEventKind.status)
            reasoningStatus = event.status.message;

        if (isTerminal(event.kind)) {
            validateTerminal(event);
            gate.materializeTerminalTurn(session, turnId);
            if (afterMaterialized !is null) afterMaterialized();
            if (event.kind == ConversationEventKind.completed)
                speech.setLanguage(event.completed.turn.language);
            terminal = true;
            sink(event);
            return;
        }

        projectConversationSpeech(speech, event, reasoningStatus);
        sink(event);
    }

    void finish()
    {
        enforce(terminal, "Remote Conversation stream ended without a terminal event");
    }

    void close() nothrow
    {
        if (!turnId.length) return;
        try {
            speechTurns.finish(turnId);
        } catch (Exception) {
        }
    }

    private void ensureSpeech()
    {
        if (speech !is null) return;
        speech = speechTurns.begin(session, turnId, language);
    }

    private void validateTerminal(ConversationEvent event)
    {
        if (event.kind != ConversationEventKind.completed) return;
        enforce(event.completed.turn.profileId == session.profileId,
            "Remote completed profile changed");
        enforce(event.completed.turn.turnId == turnId,
            "Remote completed turn changed");
    }
}

private bool isTerminal(ConversationEventKind kind)
{
    return kind == ConversationEventKind.completed || kind == ConversationEventKind.failed;
}

unittest
{
    import wheatley.common.api.text_turn : TextTurnResponse, TextTurnResponseTurn;
    import wheatley.common.conversation.events :
        ConversationAssistantDelta,
        ConversationStatusEvent,
        ConversationToolEvent;

    auto session = SessionKey("tester", "2026/08/05/12_00_00");
    auto turnId = "tester/sessions/2026/08/05/12_00_00/turns/12_00_01_000001";
    auto gate = new TestPlacementGate;
    auto registry = new TurnSpeechRegistry;
    ConversationEvent[] delivered;
    bool cleaned;
    bool materializedBeforeTerminal;
    auto delivery = new RemoteConversationDelivery(
        session,
        4,
        "en",
        gate,
        registry,
        (event) {
            if (event.kind == ConversationEventKind.completed)
                materializedBeforeTerminal = gate.materialized;
            delivered ~= event;
        },
        () { cleaned = true; },
    );
    scope(exit) delivery.close();

    auto status = remoteTestEvent(session, turnId, 5, ConversationEventKind.status);
    status.status = ConversationStatusEvent("started", "Thinking", "{}");
    delivery.accept(status);
    auto tool = remoteTestEvent(session, turnId, 6, ConversationEventKind.tool);
    tool.tool = ConversationToolEvent(
        "start", "tool-1", "web_search", 0, "running", "", "", false,
        "I'm searching.",
    );
    delivery.accept(tool);
    auto delta = remoteTestEvent(session, turnId, 7, ConversationEventKind.assistantDelta);
    delta.assistantDelta = ConversationAssistantDelta("answer-1", "Found it.");
    delivery.accept(delta);
    assert(registry.find(session, turnId).source("answer").snapshot().text ==
        "I'm searching. Found it.");

    auto completed = remoteTestEvent(session, turnId, 8, ConversationEventKind.completed);
    completed.completed = TextTurnResponse(TextTurnResponseTurn(
        turnId, "tester", "device", "api_text", "completed",
        "2026-08-05T12:00:01Z", "2026-08-05T12:00:02Z", "model", "sk",
        "Prompt", "Found it.", 0, 0, 1,
    ), false, "[]");
    delivery.accept(completed);
    delivery.finish();

    assert(delivered.length == 4);
    assert(gate.materializedTurn == turnId);
    assert(cleaned);
    assert(materializedBeforeTerminal);
    assert(registry.find(session, turnId).source("answer").snapshot().language == "sk");
}

private ConversationEvent remoteTestEvent(
    SessionKey session,
    string turnId,
    ulong sequence,
    ConversationEventKind kind,
)
{
    ConversationEvent event;
    event.session = session;
    event.turnId = turnId;
    event.sequence = sequence;
    event.timestamp = "2026-08-05T12:00:01Z";
    event.kind = kind;
    return event;
}

private final class TestPlacementGate : RemoteTurnPlacementGate
{
    bool materialized;
    string materializedTurn;

    void prepare(SessionKey session)
    {
    }

    void prepareAcceptedVoice(
        SessionKey session,
        AcceptedVoiceArtifact artifact,
        string opusPath,
    )
    {
    }

    void materializeTerminalTurn(SessionKey session, string turnId)
    {
        materialized = true;
        materializedTurn = turnId;
    }
}
