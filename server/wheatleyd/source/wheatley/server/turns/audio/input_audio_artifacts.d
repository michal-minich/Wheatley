module wheatley.server.turns.audio.input_audio_artifacts;

import core.time : MonoTime;
import std.exception : enforce;
import std.file : getSize, mkdirRecurse;
import std.conv : to;
import std.path : buildPath, dirName;
import std.uuid : randomUUID;

import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.files : moveFileReplacing;
import wheatley.common.runtime.process_runner : enforceProcessOk, runLocalProcessBytes;
import wheatley.common.runtime.temp_files : removeQuietly, runtimeOwnerRoot;
import wheatley.common.safe_token : enforceSafeToken;

/// Normalizes an accepted live prompt into profile-local durable staging before
/// the transcript-accepted event is emitted. Conversation persistence later
/// moves this file into the turn directory before writing turn.json.
UserAudioArtifactRecord persistAcceptedUserAudioPcmAsOpus(
    ServerConfig config,
    string profileId,
    string turnId,
    string createdAt,
    const(ubyte)[] pcmBytes,
    int sampleRate,
    ushort channels,
    double durationSeconds,
    double timeoutSeconds,
)
{
    enforce(turnId.length > 0, "Audio turn ID is required");
    enforce(pcmBytes.length > 0, "User audio PCM bytes are empty");
    enforce(sampleRate > 0, "User audio sample rate is required");
    enforce(channels > 0, "User audio channel count is required");
    enforceSafeToken(profileId, "Profile ID");
    enforceSafeToken(turnId, "Audio turn ID");

    auto artifactKey = "runtime-user-audio:" ~ turnId;
    auto stagedPath = buildPath(
        config.profilesRoot,
        profileId,
        "files",
        "_staged",
        "user-audio",
        turnId ~ ".opus",
    );
    mkdirRecurse(dirName(stagedPath));
    auto partialPath = buildPath(
        dirName(stagedPath),
        "." ~ turnId ~ ".partial-" ~ randomUUID().toString() ~ ".opus",
    );
    scope(failure) removeQuietly(partialPath);
    auto ffmpeg = resolveBundledExecutable("ffmpeg", "ffmpeg binary", config.appDataRoot);
    auto started = MonoTime.currTime;
    auto result = runLocalProcessBytes(
        [
            ffmpeg,
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "s16le",
            "-ar", sampleRate.to!string,
            "-ac", channels.to!string,
            "-i", "pipe:0",
            "-map", "0:a:0",
            "-vn",
            "-ac", "1",
            "-c:a", "libopus",
            "-b:a", "32k",
            "-vbr", "on",
            "-compression_level", "10",
            "-frame_duration", "60",
            "-application", "audio",
            partialPath,
        ],
        pcmBytes,
        runtimeOwnerRoot(config.appDataRoot, "wheatleyd"),
        timeoutSeconds,
    );
    auto opusEncodeMs = cast(long) (MonoTime.currTime - started).total!"msecs";
    enforceProcessOk(result, "user audio Opus encode");
    moveFileReplacing(partialPath, stagedPath);

    return UserAudioArtifactRecord(
        artifactKey,
        profileId,
        createdAt,
        stagedPath,
        cast(ulong) getSize(stagedPath),
        durationSeconds,
        durationSeconds > 0,
        opusEncodeMs,
        true,
    );
}
