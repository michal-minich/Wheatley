module wheatley.common.conversation.events;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.text_turn : TextTurnResponse;
import wheatley.common.api.generated_image : GeneratedImageArtifact;

enum ConversationEventKind
{
    status,
    assistantDelta,
    reasoning,
    tool,
    artifact,
    completed,
    failed,
}

struct ConversationStatusEvent
{
    string code;
    string message;
    string detailsJson;
}

struct ConversationAssistantDelta
{
    string itemId;
    string text;
}

struct ConversationReasoningEvent
{
    string phase;
    string itemId;
    long durationMs;
    string text;
}

struct ConversationToolEvent
{
    string stage;
    string itemId;
    string name;
    long callIndex;
    string status;
    string displayPrefix;
    string message;
    bool prefixOnly;
    string spokenMessage;
    string presentationJson;
    long durationMs;
}

struct ConversationFailureEvent
{
    string code;
    string message;
}

/** One ordered semantic event emitted by Conversation Runtime. */
struct ConversationEvent
{
    SessionKey session;
    string turnId;
    ulong sequence;
    string timestamp;
    ConversationEventKind kind;
    ConversationStatusEvent status;
    ConversationAssistantDelta assistantDelta;
    ConversationReasoningEvent reasoning;
    ConversationToolEvent tool;
    GeneratedImageArtifact artifact;
    TextTurnResponse completed;
    ConversationFailureEvent failed;
    long presentationSequence;
}

alias ConversationEventSink = void delegate(ConversationEvent event);

string conversationEventKindText(ConversationEventKind kind)
{
    final switch (kind) {
        case ConversationEventKind.status:
            return "status";
        case ConversationEventKind.assistantDelta:
            return "assistant_delta";
        case ConversationEventKind.reasoning:
            return "reasoning";
        case ConversationEventKind.tool:
            return "tool";
        case ConversationEventKind.artifact:
            return "artifact";
        case ConversationEventKind.completed:
            return "completed";
        case ConversationEventKind.failed:
            return "failed";
    }
}

ConversationEventKind parseConversationEventKind(string value)
{
    switch (value) {
        case "status":
            return ConversationEventKind.status;
        case "assistant_delta":
            return ConversationEventKind.assistantDelta;
        case "reasoning":
            return ConversationEventKind.reasoning;
        case "tool":
            return ConversationEventKind.tool;
        case "artifact":
            return ConversationEventKind.artifact;
        case "completed":
            return ConversationEventKind.completed;
        case "failed":
            return ConversationEventKind.failed;
        default:
            throw new Exception("Unsupported conversation event kind: " ~ value);
    }
}
