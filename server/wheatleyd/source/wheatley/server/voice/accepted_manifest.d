module wheatley.server.voice.accepted_manifest;

import std.exception : enforce;
import std.file : exists, getSize, readText;

import wheatley.common.api.accepted_voice_artifact :
    AcceptedVoiceArtifact,
    acceptedVoiceArtifactFileSha256,
    acceptedVoiceArtifactFromJson,
    acceptedVoiceArtifactJson,
    validateAcceptedVoiceArtifact;
import wheatley.common.api.live_audio : LiveAudioStartRequest;
import wheatley.common.api.reasoning : ReasoningMode;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.safe_token : enforceSafeToken;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.history.store.json : writeJsonFileAtomic;
import wheatley.server.conversation.turn_request : ConversationTurnRequest;

enum acceptedVoiceManifestSchema = "wheatley.accepted_voice.v2";

/// Server-accepted facts that bridge the live-audio connection and the later
/// HTTP commit. The staging path is intentionally reconstructed, never trusted
/// from the persisted file.
struct AcceptedVoiceManifest
{
    string profileId;
    string sessionId;
    string submissionId;
    string deviceId;
    string userText;
    string language;
    bool loadMemory;
    UserAudioArtifactRecord audio;
    AcceptedVoiceArtifact artifact;
}

void writeAcceptedVoiceManifest(
    string profileId,
    LiveAudioStartRequest start,
    string userText,
    string language,
    UserAudioArtifactRecord audio,
    string source = "audio_live",
    string startedAtOverride = "",
    string audioMetricsJson = "",
    string sttMetricsJson = "",
    string turnMetricsJson = "",
    ReasoningMode reasoningMode = ReasoningMode.off,
    string model = "",
)
{
    enforceSafeToken(profileId, "Accepted voice profile ID");
    enforceSafeToken(start.submissionId, "Accepted voice submission ID");
    validateAcceptedVoiceAudio(profileId, audio);
    enforce(
        audio.artifactKey == "runtime-user-audio:" ~ start.submissionId,
        "Accepted voice artifact key changed",
    );
    enforce(userText.length && language.length, "Accepted voice transcript is required");
    auto artifact = acceptedVoiceArtifactForAudio(
        profileId,
        start.sessionId,
        start.submissionId,
        audio,
        source,
        userText,
        language,
        start.deviceId,
        start.loadMemory,
        reasoningMode,
        model,
        audio.createdAt,
        audio.durationSeconds,
        audio.hasDuration,
        audio.opusEncodeMs,
        audio.hasOpusEncodeMs,
        startedAtOverride,
        audioMetricsJson,
        sttMetricsJson,
        turnMetricsJson,
    );
    auto manifest = AcceptedVoiceManifest(
        profileId, start.sessionId, start.submissionId, start.deviceId, userText,
        language, start.loadMemory, audio, artifact,
    );
    writeAcceptedVoiceManifest(manifest);
}

/// Persists a validated receiver-local manifest after its exact Opus has been staged.
void writeAcceptedVoiceManifest(AcceptedVoiceManifest manifest)
{
    validateAcceptedVoiceManifest(manifest);
    writeJsonFileAtomic(
        acceptedVoiceManifestPath(manifest.audio.stagedPath),
        acceptedVoiceManifestJson(manifest),
    );
}

/// Captures an already accepted Conversation request without transporting its
/// local staging path. Callers must resolve `request.source` before this edge.
void writeAcceptedVoiceManifest(
    string profileId,
    ConversationTurnRequest request,
    UserAudioArtifactRecord audio,
)
{
    auto artifact = acceptedVoiceArtifact(profileId, request, audio);
    writeAcceptedVoiceManifest(acceptedVoiceManifest(artifact, audio.stagedPath));
}

AcceptedVoiceArtifact acceptedVoiceArtifact(
    string profileId,
    ConversationTurnRequest request,
    UserAudioArtifactRecord audio,
)
{
    enforce(request.source.length, "Accepted voice Conversation source is required");
    return acceptedVoiceArtifactForAudio(
        profileId,
        request.sessionId,
        request.submissionId,
        audio,
        request.source,
        request.text,
        request.language,
        request.deviceId,
        request.loadMemory,
        request.reasoningMode,
        request.model,
        audio.createdAt,
        audio.durationSeconds,
        audio.hasDuration,
        audio.opusEncodeMs,
        audio.hasOpusEncodeMs,
        request.startedAtOverride,
        request.audioMetricsJson,
        request.sttMetricsJson,
        request.turnMetricsJson,
    );
}

AcceptedVoiceManifest loadAcceptedVoiceManifest(string stagedAudioPath)
{
    auto path = acceptedVoiceManifestPath(stagedAudioPath);
    enforce(exists(path), "Accepted voice manifest does not exist");
    auto json = Json.parse(readText(path), "accepted voice manifest");
    enforce(json.text("schema") == acceptedVoiceManifestSchema, "Unsupported accepted voice manifest schema");
    auto profileId = json.token("profile_id");
    auto submissionId = json.nonEmpty("submission_id");
    auto artifact = acceptedVoiceArtifactFromJson(json.object("artifact").value);
    enforce(artifact.profileId == profileId, "Accepted voice artifact profile changed");
    enforce(artifact.sessionId == json.text("session_id"), "Accepted voice artifact session changed");
    enforce(artifact.submissionId == submissionId, "Accepted voice artifact submission changed");
    auto manifest = acceptedVoiceManifest(artifact, stagedAudioPath);
    enforce(manifest.deviceId == json.text("device_id"), "Accepted voice artifact device changed");
    enforce(manifest.userText == json.nonEmpty("user_text"), "Accepted voice artifact user text changed");
    enforce(manifest.language == json.token("language"), "Accepted voice artifact language changed");
    enforce(manifest.loadMemory == json.boolean("load_memory"),
        "Accepted voice artifact memory policy changed");
    return manifest;
}

/// Reconstructs the receiver-local sidecar without accepting any sender path.
AcceptedVoiceManifest acceptedVoiceManifest(
    AcceptedVoiceArtifact artifact,
    string receiverStagedPath,
)
{
    validateAcceptedVoiceArtifact(artifact);
    enforce(receiverStagedPath.length, "Accepted voice receiver staging path is required");
    auto audio = UserAudioArtifactRecord(
        artifact.artifactKey,
        artifact.profileId,
        artifact.audioCreatedAt,
        receiverStagedPath,
        artifact.bytes,
        artifact.audioDurationSeconds,
        artifact.audioHasDuration,
        artifact.audioOpusEncodeMs,
        artifact.audioHasOpusEncodeMs,
    );
    auto manifest = AcceptedVoiceManifest(
        artifact.profileId,
        artifact.sessionId,
        artifact.submissionId,
        artifact.deviceId,
        artifact.userText,
        artifact.language,
        artifact.loadMemory,
        audio,
        artifact,
    );
    validateAcceptedVoiceManifest(manifest);
    return manifest;
}

/// A sidecar must be unique to a submission: multiple accepted prompts can
/// await a later HTTP commit at the same time.
string acceptedVoiceManifestPath(string stagedAudioPath)
{
    enforce(stagedAudioPath.length, "Accepted voice audio path is required");
    return stagedAudioPath ~ ".accepted.json";
}

private void validateAcceptedVoiceAudio(string profileId, UserAudioArtifactRecord audio)
{
    enforce(audio.artifactKey.length, "Accepted voice artifact key is required");
    enforce(audio.profileId == profileId, "Accepted voice audio profile changed");
    enforce(audio.createdAt.length, "Accepted voice audio creation time is required");
    enforce(audio.stagedPath.length, "Accepted voice audio path is required");
    enforce(audio.bytes > 0, "Accepted voice audio is empty");
    enforce(!audio.hasDuration || audio.durationSeconds > 0, "Accepted voice duration is invalid");
    enforce(!audio.hasOpusEncodeMs || audio.opusEncodeMs >= 0, "Accepted voice encode time is invalid");
}

private AcceptedVoiceArtifact acceptedVoiceArtifactForAudio(
    string profileId,
    string sessionId,
    string submissionId,
    UserAudioArtifactRecord audio,
    string source,
    string userText,
    string language,
    string deviceId,
    bool loadMemory,
    ReasoningMode reasoningMode,
    string model,
    string audioCreatedAt,
    double audioDurationSeconds,
    bool audioHasDuration,
    long audioOpusEncodeMs,
    bool audioHasOpusEncodeMs,
    string startedAtOverride,
    string audioMetricsJson,
    string sttMetricsJson,
    string turnMetricsJson,
)
{
    enforce(exists(audio.stagedPath), "Accepted voice audio does not exist");
    auto bytes = cast(ulong) getSize(audio.stagedPath);
    enforce(bytes == audio.bytes, "Accepted voice audio byte count changed");
    auto artifact = AcceptedVoiceArtifact(
        profileId,
        sessionId,
        submissionId,
        audio.artifactKey,
        source,
        userText,
        language,
        deviceId,
        loadMemory,
        reasoningMode,
        model,
        audioCreatedAt,
        bytes,
        audioDurationSeconds,
        audioHasDuration,
        audioOpusEncodeMs,
        audioHasOpusEncodeMs,
        acceptedVoiceArtifactFileSha256(audio.stagedPath),
        startedAtOverride,
        audioMetricsJson,
        sttMetricsJson,
        turnMetricsJson,
    );
    validateAcceptedVoiceArtifact(artifact);
    return artifact;
}

private void validateAcceptedVoiceManifest(AcceptedVoiceManifest manifest)
{
    enforceSafeToken(manifest.profileId, "Accepted voice profile ID");
    enforce(manifest.sessionId.length, "Accepted voice session ID is required");
    enforceSafeToken(manifest.submissionId, "Accepted voice submission ID");
    enforce(manifest.userText.length && manifest.language.length,
        "Accepted voice transcript is required");
    validateAcceptedVoiceAudio(manifest.profileId, manifest.audio);
    validateAcceptedVoiceArtifact(manifest.artifact);
    enforce(manifest.artifact.profileId == manifest.profileId,
        "Accepted voice artifact profile changed");
    enforce(manifest.artifact.sessionId == manifest.sessionId,
        "Accepted voice artifact session changed");
    enforce(manifest.artifact.submissionId == manifest.submissionId,
        "Accepted voice artifact submission changed");
    enforce(manifest.artifact.artifactKey == manifest.audio.artifactKey,
        "Accepted voice artifact key changed");
    enforce(manifest.artifact.bytes == manifest.audio.bytes,
        "Accepted voice artifact byte count changed");
    enforce(manifest.artifact.audioCreatedAt == manifest.audio.createdAt,
        "Accepted voice artifact creation time changed");
    enforce(manifest.artifact.audioDurationSeconds == manifest.audio.durationSeconds,
        "Accepted voice artifact duration changed");
    enforce(manifest.artifact.audioHasDuration == manifest.audio.hasDuration,
        "Accepted voice artifact duration flag changed");
    enforce(manifest.artifact.audioOpusEncodeMs == manifest.audio.opusEncodeMs,
        "Accepted voice artifact Opus encode time changed");
    enforce(manifest.artifact.audioHasOpusEncodeMs == manifest.audio.hasOpusEncodeMs,
        "Accepted voice artifact Opus encode flag changed");
    enforce(manifest.artifact.userText == manifest.userText,
        "Accepted voice artifact user text changed");
    enforce(manifest.artifact.language == manifest.language,
        "Accepted voice artifact language changed");
    enforce(manifest.artifact.deviceId == manifest.deviceId,
        "Accepted voice artifact device changed");
    enforce(manifest.artifact.loadMemory == manifest.loadMemory,
        "Accepted voice artifact memory policy changed");
}

private string acceptedVoiceManifestJson(AcceptedVoiceManifest manifest)
{
    return jsonObject([
        jsonStringField("schema", acceptedVoiceManifestSchema),
        jsonStringField("profile_id", manifest.profileId),
        jsonStringField("session_id", manifest.sessionId),
        jsonStringField("submission_id", manifest.submissionId),
        jsonStringField("device_id", manifest.deviceId),
        jsonStringField("user_text", manifest.userText),
        jsonStringField("language", manifest.language),
        jsonBoolField("load_memory", manifest.loadMemory),
        jsonRawField("artifact", acceptedVoiceArtifactJson(manifest.artifact)),
    ]);
}

unittest
{
    import std.file : mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    import wheatley.common.api.live_audio : LiveAudioFormat;
    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.common.api.text_turn : TextTurnRequest;

    auto root = buildPath(tempDir(), "wheatley-accepted-voice-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto audioAPath = buildPath(root, "submission-a.opus");
    auto audioBPath = buildPath(root, "submission-b.opus");
    mkdirRecurse(root);
    write(audioAPath, cast(ubyte[]) [1]);
    write(audioBPath, cast(ubyte[]) [2]);

    auto startA = LiveAudioStartRequest(
        TextTurnRequest(
            "session-a", "", "submission-a", "device-a", "en", "", true,
            ReasoningMode.off, "model-a", 0,
        ),
        LiveAudioFormat(), "turn", false, "", "", 2,
    );
    auto audioA = UserAudioArtifactRecord(
        "runtime-user-audio:submission-a", "tester", "2026-08-05T10:00:00Z", audioAPath,
        1, 4.25, true, 17, true,
    );
    writeAcceptedVoiceManifest("tester", startA, "accepted words", "en", audioA);

    auto startB = startA;
    startB.submissionId = "submission-b";
    auto audioB = audioA;
    audioB.artifactKey = "runtime-user-audio:submission-b";
    audioB.stagedPath = audioBPath;
    writeAcceptedVoiceManifest("tester", startB, "other words", "en", audioB);

    assert(acceptedVoiceManifestPath(audioAPath) != acceptedVoiceManifestPath(audioBPath));
    auto loadedA = loadAcceptedVoiceManifest(audioAPath);
    assert(loadedA.submissionId == "submission-a");
    assert(loadedA.userText == "accepted words");
    assert(loadedA.audio.stagedPath == audioAPath);
    assert(loadedA.audio.artifactKey == audioA.artifactKey);
    assert(loadedA.audio.createdAt == audioA.createdAt);
    assert(loadedA.audio.bytes == audioA.bytes);
    assert(loadedA.audio.durationSeconds == audioA.durationSeconds);
    assert(loadedA.audio.hasDuration == audioA.hasDuration);
    assert(loadedA.audio.opusEncodeMs == audioA.opusEncodeMs);
    assert(loadedA.audio.hasOpusEncodeMs == audioA.hasOpusEncodeMs);
    assert(loadedA.artifact.source == "audio_live");
    assert(loadedA.artifact.bytes == 1);

    // The first successful commit moves the Opus file into the durable turn.
    // The sidecar still has enough server-established data to replay it.
    remove(audioAPath);
    assert(loadAcceptedVoiceManifest(audioAPath).submissionId == "submission-a");
}
