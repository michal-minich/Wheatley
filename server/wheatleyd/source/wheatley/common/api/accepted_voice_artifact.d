module wheatley.common.api.accepted_voice_artifact;

import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : read;
import std.json : JSONValue;

import wheatley.common.json.object : jsonBoolField, jsonLongField, jsonObject, jsonRawField, jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.safe_token : enforceSafeToken;
import wheatley.common.api.reasoning : ReasoningMode, reasoningModeText;

enum acceptedVoiceArtifactSchema = "wheatley.accepted_voice_artifact.v1";
enum ulong acceptedVoiceArtifactMaxBytes = 64UL * 1024 * 1024;

/// Transport-safe identity and accepted Conversation facts for one Opus prompt.
/// The source and metrics preserve the exact accepted request on a paired peer.
struct AcceptedVoiceArtifact
{
    string profileId;
    string sessionId;
    string submissionId;
    string artifactKey;
    string source;
    string userText;
    string language;
    string deviceId;
    bool loadMemory;
    ReasoningMode reasoningMode;
    string model;
    string audioCreatedAt;
    ulong bytes;
    double audioDurationSeconds;
    bool audioHasDuration;
    long audioOpusEncodeMs;
    bool audioHasOpusEncodeMs;
    string sha256;
    string startedAtOverride;
    string audioMetricsJson;
    string sttMetricsJson;
    string turnMetricsJson;
}

string acceptedVoiceArtifactJson(AcceptedVoiceArtifact artifact)
{
    validateAcceptedVoiceArtifact(artifact);
    return jsonObject([
        jsonStringField("schema", acceptedVoiceArtifactSchema),
        jsonStringField("profile_id", artifact.profileId),
        jsonStringField("session_id", artifact.sessionId),
        jsonStringField("submission_id", artifact.submissionId),
        jsonStringField("artifact_key", artifact.artifactKey),
        jsonStringField("source", artifact.source),
        jsonStringField("user_text", artifact.userText),
        jsonStringField("language", artifact.language),
        jsonStringField("device_id", artifact.deviceId),
        jsonBoolField("load_memory", artifact.loadMemory),
        jsonStringField("reasoning_mode", reasoningModeText(artifact.reasoningMode)),
        jsonStringField("model", artifact.model),
        jsonStringField("audio_created_at", artifact.audioCreatedAt),
        jsonLongField("bytes", cast(long) artifact.bytes),
        jsonRawField("audio_duration_seconds", JSONValue(artifact.audioDurationSeconds).toString()),
        jsonBoolField("audio_has_duration", artifact.audioHasDuration),
        jsonLongField("audio_opus_encode_ms", artifact.audioOpusEncodeMs),
        jsonBoolField("audio_has_opus_encode_ms", artifact.audioHasOpusEncodeMs),
        jsonStringField("sha256", artifact.sha256),
        jsonStringField("started_at_override", artifact.startedAtOverride),
        jsonStringField("audio_metrics_json", artifact.audioMetricsJson),
        jsonStringField("stt_metrics_json", artifact.sttMetricsJson),
        jsonStringField("turn_metrics_json", artifact.turnMetricsJson),
    ]);
}

AcceptedVoiceArtifact acceptedVoiceArtifactFromJson(JSONValue value)
{
    auto json = Json.object(value);
    enforce(json.text("schema") == acceptedVoiceArtifactSchema,
        "Unsupported accepted voice artifact schema");
    auto artifact = AcceptedVoiceArtifact(
        json.token("profile_id"),
        json.nonEmpty("session_id"),
        json.token("submission_id"),
        json.nonEmpty("artifact_key"),
        json.nonEmpty("source"),
        json.nonEmpty("user_text"),
        json.token("language"),
        json.text("device_id"),
        json.boolean("load_memory"),
        json.enumeration!ReasoningMode("reasoning_mode"),
        json.text("model"),
        json.nonEmpty("audio_created_at"),
        cast(ulong) json.integer("bytes", 1, cast(long) acceptedVoiceArtifactMaxBytes),
        json.number("audio_duration_seconds", 0, double.max),
        json.boolean("audio_has_duration"),
        json.integer("audio_opus_encode_ms", 0),
        json.boolean("audio_has_opus_encode_ms"),
        json.nonEmpty("sha256"),
        json.text("started_at_override"),
        json.text("audio_metrics_json"),
        json.text("stt_metrics_json"),
        json.text("turn_metrics_json"),
    );
    validateAcceptedVoiceArtifact(artifact);
    return artifact;
}

void validateAcceptedVoiceArtifact(AcceptedVoiceArtifact artifact)
{
    enforceSafeToken(artifact.profileId, "Accepted voice artifact profile ID");
    enforce(artifact.sessionId.length, "Accepted voice artifact session ID is required");
    enforceSafeToken(artifact.submissionId, "Accepted voice artifact submission ID");
    enforce(
        artifact.artifactKey == "runtime-user-audio:" ~ artifact.submissionId,
        "Accepted voice artifact key changed",
    );
    enforce(artifact.source.length, "Accepted voice artifact source is required");
    enforce(artifact.userText.length, "Accepted voice artifact user text is required");
    enforceSafeToken(artifact.language, "Accepted voice artifact language");
    enforce(artifact.audioCreatedAt.length, "Accepted voice artifact audio creation time is required");
    enforce(artifact.bytes > 0 && artifact.bytes <= acceptedVoiceArtifactMaxBytes,
        "Accepted voice artifact exceeds 64 MiB limit");
    enforce(!artifact.audioHasDuration || artifact.audioDurationSeconds > 0,
        "Accepted voice artifact duration is invalid");
    enforce(!artifact.audioHasOpusEncodeMs || artifact.audioOpusEncodeMs >= 0,
        "Accepted voice artifact Opus encode time is invalid");
    enforceLowerSha256(artifact.sha256);
    validateOptionalJsonObject(artifact.audioMetricsJson, "Accepted voice audio metrics");
    validateOptionalJsonObject(artifact.sttMetricsJson, "Accepted voice STT metrics");
    validateOptionalJsonObject(artifact.turnMetricsJson, "Accepted voice turn metrics");
}

string acceptedVoiceArtifactSha256(const(ubyte)[] bytes)
{
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
}

string acceptedVoiceArtifactFileSha256(string path)
{
    return acceptedVoiceArtifactSha256(cast(const(ubyte)[]) read(path));
}

private void enforceLowerSha256(string value)
{
    enforce(value.length == 64, "Accepted voice artifact SHA-256 must be 64 lowercase hex characters");
    foreach (ch; value) {
        enforce(
            (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'),
            "Accepted voice artifact SHA-256 must be 64 lowercase hex characters",
        );
    }
}

private void validateOptionalJsonObject(string value, string label)
{
    if (!value.length) return;
    Json.parse(value, label);
}

unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;

    auto artifact = AcceptedVoiceArtifact(
        "tester", "2026/08/05/12_00_00", "submission-a",
        "runtime-user-audio:submission-a", "audio_live", "Hello", "en", "device-a", true,
        ReasoningMode.off, "model-a", "2026-08-05T12:00:00Z", 3, 1, true, 4, true,
        acceptedVoiceArtifactSha256(cast(ubyte[]) [1, 2, 3]),
        "2026-08-05T12:00:00Z", "{\"accepted_seconds\":1}", "{}", "",
    );
    auto decoded = acceptedVoiceArtifactFromJson(parseJSON(acceptedVoiceArtifactJson(artifact)));
    assert(decoded == artifact);

    artifact.sha256 = "A" ~ artifact.sha256[1 .. $];
    assertThrown!Exception(validateAcceptedVoiceArtifact(artifact));
    artifact.sha256 = acceptedVoiceArtifactSha256(cast(ubyte[]) [1, 2, 3]);
    artifact.audioMetricsJson = "[]";
    assertThrown!Exception(validateAcceptedVoiceArtifact(artifact));
}
