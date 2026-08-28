module wheatley.server.conversation.event_stream;

import std.exception : enforce;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.text_turn : TextTurnResponse;
import wheatley.common.api.generated_image : GeneratedImageArtifact;
import wheatley.common.choice : requireChoice;
import wheatley.common.conversation.events :
    ConversationAssistantDelta,
    ConversationEvent,
    ConversationEventKind,
    ConversationEventSink,
    ConversationFailureEvent,
    ConversationReasoningEvent,
    ConversationStatusEvent,
    ConversationToolEvent;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.json.read : Json;
import wheatley.common.json.object : jsonObject, jsonStringField;

/** Assigns identity and a gap-free sequence to one Conversation turn stream. */
final class ConversationEventStream
{
    private SessionKey session;
    private string turnId;
    private ConversationEventSink sink;
    private ulong nextSequence;
    private bool terminal;

    this(
        SessionKey session,
        string turnId,
        ConversationEventSink sink,
        ulong firstSequence = 1,
    )
    {
        enforce(turnId.length, "Conversation turn ID is required");
        enforce(sink !is null, "Conversation event sink is required");
        enforce(firstSequence > 0, "Conversation first sequence is required");
        this.session = session;
        this.turnId = turnId;
        this.sink = sink;
        this.nextSequence = firstSequence;
    }

    void status(string code, string message, string detailsJson = "{}")
    {
        enforce(code.length, "Conversation status code is required");
        Json.parse(detailsJson);
        ConversationEvent event;
        event.kind = ConversationEventKind.status;
        event.status = ConversationStatusEvent(code, message, detailsJson);
        emit(event);
    }

    void assistantDelta(string itemId, string text)
    {
        enforce(itemId.length, "Conversation assistant item ID is required");
        enforce(text.length, "Conversation assistant delta is required");
        ConversationEvent event;
        event.kind = ConversationEventKind.assistantDelta;
        event.assistantDelta = ConversationAssistantDelta(itemId, text);
        emit(event);
    }

    void assistantStart(string itemId)
    {
        enforce(itemId.length, "Conversation assistant item ID is required");
        status(
            "assistant_item_started",
            "Assistant item started.",
            jsonObject([jsonStringField("item_id", itemId)]),
        );
    }

    void assistantEnd(string itemId)
    {
        enforce(itemId.length, "Conversation assistant item ID is required");
        status(
            "assistant_item_finished",
            "Assistant item finished.",
            jsonObject([jsonStringField("item_id", itemId)]),
        );
    }

    void reasoning(string phase, string itemId, long durationMs, string text)
    {
        requireChoice!("start", "delta", "end")(phase, "Conversation reasoning phase");
        enforce(itemId.length, "Conversation reasoning item ID is required");
        enforce(durationMs >= 0, "Conversation reasoning duration cannot be negative");
        ConversationEvent event;
        event.kind = ConversationEventKind.reasoning;
        event.reasoning = ConversationReasoningEvent(phase, itemId, durationMs, text);
        emit(event);
    }

    void tool(ConversationToolEvent tool)
    {
        requireChoice!("start", "end")(tool.stage, "Conversation tool stage");
        requireChoice!("running", "succeeded", "failed")(
            tool.status,
            "Conversation tool status",
        );
        enforce(tool.name.length, "Conversation tool name is required");
        enforce(
            tool.callIndex >= 0
                || (tool.name == "model_context" && tool.callIndex == -1),
            "Conversation tool call index cannot be negative",
        );
        ConversationEvent event;
        event.kind = ConversationEventKind.tool;
        event.tool = tool;
        emit(event);
    }

    void artifact(GeneratedImageArtifact artifact)
    {
        enforce(artifact.itemId.length, "Conversation artifact item ID is required");
        enforce(artifact.mediaType == "image/png", "Conversation image artifact must be PNG");
        enforce(artifact.url.length && artifact.filename.length,
            "Conversation image artifact location is required");
        ConversationEvent event;
        event.kind = ConversationEventKind.artifact;
        event.artifact = artifact;
        emit(event);
    }

    void complete(TextTurnResponse response)
    {
        enforce(!terminal, "Conversation event stream is already terminal");
        enforce(response.turn.profileId == session.profileId, "Completed profile changed");
        enforce(response.turn.turnId == turnId, "Completed turn changed");
        ConversationEvent event;
        event.kind = ConversationEventKind.completed;
        event.completed = response;
        emit(event);
        terminal = true;
    }

    void fail(string code, string message)
    {
        if (terminal) return;
        enforce(code.length, "Conversation failure code is required");
        enforce(message.length, "Conversation failure message is required");
        ConversationEvent event;
        event.kind = ConversationEventKind.failed;
        event.failed = ConversationFailureEvent(code, message);
        emit(event);
        terminal = true;
    }

    private void emit(ref ConversationEvent event)
    {
        enforce(!terminal, "Conversation event stream is already terminal");
        event.session = session;
        event.turnId = turnId;
        event.sequence = nextSequence++;
        event.timestamp = nowIso();
        sink(event);
    }
}

unittest
{
    import std.exception : assertThrown;
    import wheatley.common.conversation.events : ConversationEvent;

    ConversationEvent[] events;
    auto stream = new ConversationEventStream(
        SessionKey("tester", "2026/08/05/12_00_00"),
        "turn-1",
        (event) { events ~= event; },
    );
    stream.status("started", "Started");
    stream.tool(ConversationToolEvent(
        "start", "model-context", "model_context", -1, "succeeded",
        "tester", "Model context", false, "", "{}",
    ));
    assertThrown(stream.tool(ConversationToolEvent(
        "start", "bad", "read", -1, "succeeded",
        "tester", "Bad", false, "", "{}",
    )));
    stream.assistantDelta("assistant:0:0", "Hello");
    stream.fail("turn", "Failed");
    assert(events.length == 4);
    assert(events[0].sequence == 1);
    assert(events[1].sequence == 2);
    assert(events[1].tool.callIndex == -1);
    assert(events[2].sequence == 3);
    assert(events[3].kind == ConversationEventKind.failed);
}
