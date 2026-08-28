module wheatley.common.api.conversation_events;

import std.exception : assertThrown, enforce;
import std.json : JSONValue;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.generated_image :
    generatedImageArtifactFromJson,
    generatedImageArtifactJson;
import wheatley.common.api.text_turn :
    textTurnResponseFromJson,
    textTurnResponseJson;
import wheatley.common.conversation.events :
    ConversationAssistantDelta,
    ConversationEvent,
    ConversationEventKind,
    ConversationFailureEvent,
    ConversationReasoningEvent,
    ConversationStatusEvent,
    ConversationToolEvent,
    conversationEventKindText,
    parseConversationEventKind;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField,
    jsonUlongField;
import wheatley.common.json.read : Json;

string conversationEventJson(ConversationEvent event)
{
    return jsonObject([
        jsonStringField("profile_id", event.session.profileId),
        jsonStringField("session_id", event.session.sessionId),
        jsonStringField("turn_id", event.turnId),
        jsonUlongField("sequence", event.sequence),
        event.presentationSequence > 0
            ? jsonLongField("presentation_sequence", event.presentationSequence)
            : "",
        jsonStringField("timestamp", event.timestamp),
        jsonStringField("kind", conversationEventKindText(event.kind)),
        jsonRawField("payload", conversationEventPayloadJson(event)),
    ]);
}

ConversationEvent conversationEventFromJson(JSONValue value)
{
    auto json = Json.object(value);
    ConversationEvent event;
    event.session = SessionKey(json.text("profile_id"), json.text("session_id"));
    event.turnId = json.text("turn_id");
    event.sequence = json.positiveInt("sequence");
    event.presentationSequence = json.opt.positiveInt("presentation_sequence").get(0);
    event.timestamp = json.text("timestamp");
    event.kind = parseConversationEventKind(json.text("kind"));
    auto payload = json.object("payload");
    final switch (event.kind) {
        case ConversationEventKind.status:
            event.status = ConversationStatusEvent(
                payload.text("code"),
                payload.text("message"),
                payload.objectRaw("details"),
            );
            break;
        case ConversationEventKind.assistantDelta:
            event.assistantDelta = ConversationAssistantDelta(
                payload.text("item_id"),
                payload.text("text"),
            );
            break;
        case ConversationEventKind.reasoning:
            event.reasoning = ConversationReasoningEvent(
                payload.choice!("start", "delta", "end")("phase"),
                payload.text("item_id"),
                payload.nonNegativeInt("duration_ms"),
                payload.text("text"),
            );
            break;
        case ConversationEventKind.tool:
            auto presentation = payload.opt.object("presentation");
            auto toolName = payload.text("name");
            auto callIndex = payload.intRange("call_index", -1, int.max);
            enforce(
                callIndex >= 0 || toolName == "model_context",
                "JSON payload.call_index",
            );
            event.tool = ConversationToolEvent(
                payload.choice!("start", "end")("stage"),
                payload.text("item_id"),
                toolName,
                callIndex,
                payload.choice!("running", "succeeded", "failed")("status"),
                payload.text("display_prefix"),
                payload.text("message"),
                payload.boolean("prefix_only"),
                payload.text("spoken_message"),
                presentation.isNull ? "{}" : presentation.get.value.toString(),
                optionalDuration(payload),
            );
            break;
        case ConversationEventKind.artifact:
            event.artifact = generatedImageArtifactFromJson(payload);
            break;
        case ConversationEventKind.completed:
            event.completed = textTurnResponseFromJson(payload.value);
            break;
        case ConversationEventKind.failed:
            event.failed = ConversationFailureEvent(
                payload.text("code"),
                payload.text("message"),
            );
            break;
    }
    return event;
}

private string conversationEventPayloadJson(ConversationEvent event)
{
    final switch (event.kind) {
        case ConversationEventKind.status:
            return conversationStatusEventJson(event.status);
        case ConversationEventKind.assistantDelta:
            return conversationAssistantDeltaJson(event.assistantDelta);
        case ConversationEventKind.reasoning:
            return conversationReasoningEventJson(event.reasoning);
        case ConversationEventKind.tool:
            return conversationToolEventJson(event.tool);
        case ConversationEventKind.artifact:
            return generatedImageArtifactJson(event.artifact);
        case ConversationEventKind.completed:
            return textTurnResponseJson(event.completed);
        case ConversationEventKind.failed:
            return jsonObject([
                jsonStringField("code", event.failed.code),
                jsonStringField("message", event.failed.message),
            ]);
    }
}

string conversationStatusEventJson(ConversationStatusEvent event)
{
    return jsonObject([
        jsonStringField("code", event.code),
        jsonStringField("message", event.message),
        jsonRawField("details", jsonObjectRaw(event.detailsJson)),
    ]);
}

string conversationAssistantDeltaJson(ConversationAssistantDelta event)
{
    return jsonObject([
        jsonStringField("item_id", event.itemId),
        jsonStringField("text", event.text),
    ]);
}

string conversationReasoningEventJson(ConversationReasoningEvent event)
{
    return jsonObject([
        jsonStringField("phase", event.phase),
        jsonStringField("item_id", event.itemId),
        jsonLongField("duration_ms", event.durationMs),
        jsonStringField("text", event.text),
    ]);
}

string conversationToolEventJson(ConversationToolEvent event)
{
    return jsonObject([
        jsonStringField("stage", event.stage),
        jsonStringField("item_id", event.itemId),
        jsonStringField("name", event.name),
        jsonLongField("call_index", event.callIndex),
        jsonStringField("status", event.status),
        jsonStringField("display_prefix", event.displayPrefix),
        jsonStringField("message", event.message),
        jsonBoolField("prefix_only", event.prefixOnly),
        jsonStringField("spoken_message", event.spokenMessage),
        jsonLongField("duration_ms", event.durationMs >= 0 ? event.durationMs : 0),
        jsonRawField(
            "presentation",
            jsonObjectRaw(event.presentationJson.length ? event.presentationJson : "{}"),
        ),
    ]);
}

private long optionalDuration(Json payload)
{
    auto value = payload.opt.integer("duration_ms", 0);
    return value.isNull ? 0 : value.get;
}

unittest
{
    import std.json : parseJSON;

    import wheatley.common.api.text_turn : TextTurnResponse, TextTurnResponseTurn;
    import wheatley.common.conversation.events : ConversationEventKind;

    auto event = ConversationEvent(
        SessionKey("tester", "2026/08/05/12_00_00"),
        "turn-1",
        3,
        "2026-08-05T12:00:01Z",
        ConversationEventKind.assistantDelta,
    );
    event.assistantDelta = ConversationAssistantDelta("assistant:0:0", "Hello");
    auto decoded = conversationEventFromJson(parseJSON(conversationEventJson(event)));
    assert(decoded.session == event.session);
    assert(decoded.turnId == "turn-1");
    assert(decoded.sequence == 3);
    assert(decoded.presentationSequence == 0);
    assert(decoded.kind == ConversationEventKind.assistantDelta);
    assert(decoded.assistantDelta.text == "Hello");

    event.presentationSequence = 17;
    decoded = conversationEventFromJson(parseJSON(conversationEventJson(event)));
    assert(decoded.presentationSequence == 17);
    event.presentationSequence = 0;

    event.kind = ConversationEventKind.tool;
    event.tool = ConversationToolEvent(
        "start",
        "model-context",
        "model_context",
        -1,
        "succeeded",
        "tester",
        "Model context",
        false,
        "",
        "{}",
    );
    decoded = conversationEventFromJson(parseJSON(conversationEventJson(event)));
    assert(decoded.tool.name == "model_context");
    assert(decoded.tool.callIndex == -1);

    event.tool.name = "ordinary_tool";
    assertThrown!Exception(
        conversationEventFromJson(parseJSON(conversationEventJson(event))),
    );

    event.kind = ConversationEventKind.completed;
    event.completed = TextTurnResponse(
        TextTurnResponseTurn(
            "turn-1",
            "tester",
            "device",
            "api_text",
            "completed",
            "2026-08-05T12:00:00Z",
            "2026-08-05T12:00:02Z",
            "model",
            "en",
            "Hi",
            "Hello",
        ),
        false,
        "[]",
    );
    decoded = conversationEventFromJson(parseJSON(conversationEventJson(event)));
    assert(decoded.completed.turn.assistantText == "Hello");
}
