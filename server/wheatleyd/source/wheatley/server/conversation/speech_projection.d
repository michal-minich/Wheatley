module wheatley.server.conversation.speech_projection;

import wheatley.common.conversation.events : ConversationEvent, ConversationEventKind;
import wheatley.server.tts.turn_speech_registry : TurnSpeechTurn;

/// Projects transport-stable Conversation semantics into local narration.
void projectConversationSpeech(
    TurnSpeechTurn speech,
    ConversationEvent event,
    string reasoningStatus,
)
{
    final switch (event.kind) {
        case ConversationEventKind.status:
            return;
        case ConversationEventKind.assistantDelta:
            speech.feedAnswer(event.assistantDelta.itemId, event.assistantDelta.text);
            return;
        case ConversationEventKind.reasoning:
            if (event.reasoning.phase == "delta") {
                speech.feedReasoning(
                    event.reasoning.itemId,
                    event.reasoning.text,
                    reasoningStatus,
                );
            } else if (event.reasoning.phase == "end") {
                speech.finishItem("reasoning", event.reasoning.itemId);
            }
            return;
        case ConversationEventKind.tool:
            if (event.tool.stage == "start" && event.tool.spokenMessage.length)
                speech.feedProgress(event.tool.spokenMessage);
            return;
        case ConversationEventKind.artifact:
            speech.feedAnswerItem(event.artifact.itemId, event.artifact.prompt);
            return;
        case ConversationEventKind.completed:
        case ConversationEventKind.failed:
            return;
    }
}

unittest
{
    import wheatley.common.api.session : SessionKey;
    import wheatley.common.conversation.events :
        ConversationAssistantDelta,
        ConversationReasoningEvent,
        ConversationToolEvent;

    auto speech = new TurnSpeechTurn(SessionKey("tester", "session"), "en");
    ConversationEvent event;
    event.kind = ConversationEventKind.tool;
    event.tool = ConversationToolEvent(
        "start", "tool-1", "web_search", 0, "running", "", "", false,
        "I'm searching.",
    );
    projectConversationSpeech(speech, event, "Thinking");
    event.kind = ConversationEventKind.reasoning;
    event.reasoning = ConversationReasoningEvent("delta", "reasoning-1", 0, "Checking.");
    projectConversationSpeech(speech, event, "Thinking");
    event.kind = ConversationEventKind.assistantDelta;
    event.assistantDelta = ConversationAssistantDelta("answer-1", "Done.");
    projectConversationSpeech(speech, event, "Thinking");

    assert(speech.source("answer").snapshot().text == "I'm searching. Done.");
    auto reasoning = speech.source("reasoning").snapshot();
    assert(reasoning.text == "Checking.");
    assert(speech.source("answer").snapshot().status == "Thinking");
}
