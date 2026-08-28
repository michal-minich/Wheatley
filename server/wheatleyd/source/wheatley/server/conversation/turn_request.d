module wheatley.server.conversation.turn_request;

import core.time : MonoTime;

import wheatley.common.api.text_turn :
    TextTurnRequest,
    textTurnSubmissionId,
    commonTextTurnSource = textTurnSource;
import wheatley.server.history.rows.image_artifact_record : UserImageArtifactRecord;

struct ConversationTurnRequest
{
    TextTurnRequest turn;
    alias turn this;

    string startedAtOverride;
    string audioMetricsJson;
    string sttMetricsJson;
    string turnMetricsJson;
    bool hasAcceptedTurnStartMono;
    MonoTime acceptedTurnStartMono;
    bool hasUserImage;
    UserImageArtifactRecord userImage;
    // Server-authored context for a scheduled occurrence.  This is deliberately
    // outside TextTurnRequest, which is client/LLM controlled.
    string scheduledTriggerJson;
    // Immutable scheduler-owned tool-result snapshot.  Keeping it distinct
    // from arguments ensures the compact transcript never exposes the task
    // instruction or internal execution context.
    string scheduledTriggerDetailsJson;
    string scheduledPrivatePrompt;
}

ConversationTurnRequest conversationTurnRequest(TextTurnRequest request)
{
    ConversationTurnRequest result;
    result.turn = request;
    return result;
}

string conversationSubmissionId(ConversationTurnRequest request)
{
    return textTurnSubmissionId(request.turn);
}

string conversationTurnSource(ConversationTurnRequest request, string fallbackSource)
{
    return commonTextTurnSource(request.turn, fallbackSource);
}
