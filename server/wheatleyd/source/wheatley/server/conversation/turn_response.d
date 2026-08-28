module wheatley.server.conversation.turn_response;

import wheatley.common.api.text_turn :
    TextTurnResponse,
    TextTurnResponseTurn;
import wheatley.server.history.store.types : StoredTurn;
import wheatley.server.history.store.turn_metrics : inspectionMetrics;
import wheatley.server.turns.text.profile_runtime_settings : ProfileRuntimeSettings;

TextTurnResponse conversationTurnResponse(
    string turnId,
    string profileId,
    string deviceId,
    string source,
    string startedAt,
    string completedAt,
    ProfileRuntimeSettings settings,
    string userText,
    string assistantText,
    string status,
    bool stopped,
    long toolCount = 0,
    long audioCount = 0,
    long artifactCount = 0,
    string metricsJson = "{}",
)
{
    return TextTurnResponse(
        TextTurnResponseTurn(
            turnId,
            profileId,
            deviceId,
            source.length ? source : "api_text",
            status,
            startedAt,
            completedAt,
            settings.assistantModel,
            settings.language,
            userText,
            assistantText,
            audioCount,
            artifactCount,
            toolCount,
            inspectionMetrics(metricsJson, startedAt, completedAt),
        ),
        stopped,
        "[]",
    );
}

TextTurnResponse storedConversationTurnResponse(StoredTurn turn)
{
    return TextTurnResponse(
        TextTurnResponseTurn(
            turn.id,
            turn.profileId,
            turn.deviceId,
            turn.source,
            turn.status,
            turn.startedAt,
            turn.completedAt,
            turn.modelName,
            turn.language,
            turn.userText,
            turn.assistantText,
            turn.hasUserAudio ? 1 : 0,
            turn.hasUserAudio ? 1 : 0,
            0,
            inspectionMetrics(turn.metricsJson, turn.startedAt, turn.completedAt),
        ),
        turn.status == "stopped",
        "[]",
    );
}
