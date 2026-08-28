module wheatley.client.console.text.events;

import std.exception : enforce;
import std.json : parseJSON;

import wheatley.common.api.conversation_events :
    conversationEventFromJson,
    conversationReasoningEventJson,
    conversationStatusEventJson,
    conversationToolEventJson;
import wheatley.common.api.text_turn : TextTurnResponse;
import wheatley.common.api.generated_image : generatedImageArtifactJson;
import wheatley.common.api.session : SessionKey;
import wheatley.common.conversation.events : ConversationEventKind, ConversationStatusEvent;
import wheatley.client.console.api.sse_events : readConsoleSseEvents;
import wheatley.client.console.text.types : ConsoleTextTurnResult;

ConsoleTextTurnResult readConsoleTextTurnEvents(Reader)(
    Reader reader,
    SessionKey expectedSession,
    ulong initialSequence = 0,
    void delegate(string token) onToken = null,
    void delegate(string dataJson) onTool = null,
    void delegate(string dataJson) onStatus = null,
    void delegate(string dataJson) onReasoning = null,
    void delegate(ulong sequence) onReplayCursor = null,
    void delegate(string turnId, ulong sequence) onTerminal = null,
)
{
    auto finalResult = ConsoleTextTurnResult();
    bool finalReceived;
    string streamError;
    ulong lastSequence = initialSequence;
    string turnId;
    readConsoleSseEvents(reader, (event) {
        enforce(event.name == "conversation", "Unsupported text turn event: " ~ event.name);
        auto conversation = conversationEventFromJson(parseJSON(event.data));
        enforce(conversation.session == expectedSession, "Conversation event session changed");
        enforce(conversation.turnId.length, "Conversation event turn ID is required");
        enforce(!turnId.length || conversation.turnId == turnId, "Conversation event turn changed");
        enforce(conversation.sequence == lastSequence + 1, "Conversation event sequence gap");
        lastSequence = conversation.sequence;
        turnId = conversation.turnId;
        final switch (conversation.kind) {
            case ConversationEventKind.assistantDelta:
                if (onReplayCursor !is null) onReplayCursor(lastSequence);
                if (onToken !is null) onToken(conversation.assistantDelta.text);
                break;
            case ConversationEventKind.tool:
                if (onReplayCursor !is null) onReplayCursor(lastSequence);
                if (onTool !is null) onTool(conversationToolEventJson(conversation.tool));
                break;
            case ConversationEventKind.artifact:
                if (onReplayCursor !is null) onReplayCursor(lastSequence);
                if (onStatus !is null) onStatus(conversationStatusEventJson(
                    ConversationStatusEvent(
                        "generated_image",
                        conversation.artifact.path,
                        generatedImageArtifactJson(conversation.artifact),
                    ),
                ));
                break;
            case ConversationEventKind.status:
                if (onReplayCursor !is null) onReplayCursor(lastSequence);
                if (onStatus !is null) onStatus(conversationStatusEventJson(conversation.status));
                break;
            case ConversationEventKind.reasoning:
                if (onReplayCursor !is null) onReplayCursor(lastSequence);
                if (onReasoning !is null)
                    onReasoning(conversationReasoningEventJson(conversation.reasoning));
                break;
            case ConversationEventKind.completed:
                finalResult = parseTurnResult(conversation.completed, expectedSession, turnId);
                finalReceived = true;
                if (onTerminal !is null) onTerminal(turnId, lastSequence);
                return false;
            case ConversationEventKind.failed:
                streamError = conversation.failed.message;
                if (onTerminal !is null) onTerminal(turnId, lastSequence);
                return false;
        }
        return true;
    });

    if (streamError.length) throw new Exception(streamError);
    enforce(finalReceived, "Text turn stream ended without a final response");
    return finalResult;
}

private ConsoleTextTurnResult parseTurnResult(
    TextTurnResponse response,
    SessionKey expectedSession,
    string expectedTurnId,
)
{
    enforce(response.turn.profileId == expectedSession.profileId,
        "Completed Conversation profile changed");
    enforce(response.turn.turnId == expectedTurnId, "Completed Conversation turn changed");
    auto result = ConsoleTextTurnResult();
    result.stopped = response.stopped;
    result.turnId = response.turn.turnId;
    result.assistantText = response.turn.assistantText;
    result.language = response.turn.language;
    result.metrics = response.turn.metrics;
    return result;
}

unittest
{
    import std.exception : assertThrown;
    import vibe.stream.memory : createMemoryStream;

    import wheatley.common.api.conversation_events : conversationEventJson;
    import wheatley.common.api.text_turn : TextTurnResponse, TextTurnResponseTurn;
    import wheatley.common.conversation.events :
        ConversationEvent,
        ConversationEventKind,
        ConversationFailureEvent,
        ConversationStatusEvent;

    string sse(ConversationEvent event)
    {
        return "event: conversation\n" ~ "data: " ~ conversationEventJson(event) ~ "\n\n";
    }

    auto expected = SessionKey("wheatley", "session-voice");
    auto status = ConversationEvent(
        expected,
        "turn-voice",
        5,
        "2026-08-05T12:00:01Z",
        ConversationEventKind.status,
    );
    status.status = ConversationStatusEvent("processing", "Working", "{}");
    auto failed = ConversationEvent(
        expected,
        "turn-voice",
        6,
        "2026-08-05T12:00:02Z",
        ConversationEventKind.failed,
    );
    failed.failed = ConversationFailureEvent("agent_failed", "No answer");

    ulong[] checkpoints;
    ulong terminalSequence;
    auto failedStream = createMemoryStream(cast(ubyte[]) (sse(status) ~ sse(failed)).dup, false);
    assertThrown!Exception(readConsoleTextTurnEvents(
        failedStream,
        expected,
        4,
        null,
        null,
        null,
        null,
        (ulong sequence) { checkpoints ~= sequence; },
        (string turnId, ulong sequence) {
            assert(turnId == "turn-voice");
            terminalSequence = sequence;
        },
    ));
    assert(checkpoints == [5]);
    assert(terminalSequence == 6);

    auto completed = ConversationEvent(
        expected,
        "turn-voice",
        5,
        "2026-08-05T12:00:03Z",
        ConversationEventKind.completed,
    );
    completed.completed = TextTurnResponse(
        TextTurnResponseTurn(
            "different-turn",
            expected.profileId,
            "console-1",
            "audio_live",
            "completed",
            "2026-08-05T12:00:00Z",
            "2026-08-05T12:00:03Z",
            "model",
            "en",
            "Hello",
            "Hi",
        ),
        false,
        "[]",
    );
    bool terminalCalled;
    auto mismatchedStream = createMemoryStream(cast(ubyte[]) sse(completed).dup, false);
    assertThrown!Exception(readConsoleTextTurnEvents(
        mismatchedStream,
        expected,
        4,
        null,
        null,
        null,
        null,
        null,
        (string turnId, ulong sequence) { terminalCalled = true; },
    ));
    assert(!terminalCalled);

    status.session = SessionKey("other", expected.sessionId);
    auto wrongSessionStream = createMemoryStream(cast(ubyte[]) sse(status).dup, false);
    assertThrown!Exception(readConsoleTextTurnEvents(wrongSessionStream, expected, 4));

    status.session = expected;
    status.sequence = 7;
    auto gapStream = createMemoryStream(cast(ubyte[]) sse(status).dup, false);
    assertThrown!Exception(readConsoleTextTurnEvents(gapStream, expected, 4));
}
