module wheatley.server.history.rows.text_turn_record;

import wheatley.common.api.reasoning : ReasoningMode;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.history.rows.image_artifact_record : UserImageArtifactRecord;

struct TextTurnRecord
{
    string turnId;
    string profileId;
    string sessionId;
    string deviceId;
    string source;
    string status;
    string startedAt;
    string completedAt;
    string modelName;
    string language;
    string userText;
    string assistantText;
    string metricsJson;
    bool hasPiExitStatus;
    int piExitStatus;
    string errorsJson;
    bool hasUserAudio;
    UserAudioArtifactRecord userAudio;
    ReasoningMode reasoningMode;
    bool userAudioRequired;
    string submissionId;
    string executionId;
    string submissionJson;
    bool hasUserImage;
    UserImageArtifactRecord userImage;
}
