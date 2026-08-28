module wheatley.server.history.rows.audio_artifact_record;

struct UserAudioArtifactRecord
{
    string artifactKey;
    string profileId;
    string createdAt;
    string stagedPath;
    ulong bytes;
    double durationSeconds;
    bool hasDuration;
    long opusEncodeMs;
    bool hasOpusEncodeMs;
}
