module wheatley.server.voice.accepted_replica;

import std.exception : enforce;
import std.file : copy, exists, getSize, mkdirRecurse, remove, rename;
import std.path : buildPath, dirName;
import std.uuid : randomUUID;

import vibe.core.core : yield;
import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.api.accepted_voice_artifact :
    AcceptedVoiceArtifact,
    acceptedVoiceArtifactFileSha256,
    acceptedVoiceArtifactMaxBytes,
    validateAcceptedVoiceArtifact;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.process_runner : enforceProcessOk, runLocalProcess;
import wheatley.common.runtime.temp_files : runtimeOwnerRoot;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.voice.accepted_manifest :
    AcceptedVoiceManifest,
    acceptedVoiceManifestPath,
    acceptedVoiceManifest,
    loadAcceptedVoiceManifest,
    writeAcceptedVoiceManifest;

interface AcceptedVoiceOpusValidator
{
    void validateOpus(string path);
}

/// Actual Ogg/Opus validation for a received accepted-prompt artifact.
final class FfmpegAcceptedVoiceOpusValidator : AcceptedVoiceOpusValidator
{
    private string ffmpeg;
    private string workingRoot;

    this(string appDataRoot)
    {
        ffmpeg = resolveBundledExecutable("ffmpeg", "ffmpeg binary", appDataRoot);
        workingRoot = runtimeOwnerRoot(appDataRoot, "wheatleyd");
    }

    void validateOpus(string path)
    {
        auto result = runLocalProcess(
            [
                ffmpeg,
                "-hide_banner",
                "-loglevel", "error",
                "-i", path,
                "-map", "0:a:0",
                "-f", "null",
                "-",
            ],
            "",
            workingRoot,
            60,
        );
        enforceProcessOk(result, "Accepted voice Ogg/Opus validation");
    }
}

/// The one receiver-side owner for an exact accepted voice upload.
/// It derives the staging path locally and never accepts a sender-provided path.
final class AcceptedVoiceReplica
{
    private RuntimeFiles files;
    private AcceptedVoiceOpusValidator validator;
    private bool delegate(AcceptedVoiceArtifact artifact) turnCommitted;
    private ulong maxBytes;
    private TaskMutex mutex;

    this(
        RuntimeFiles files,
        AcceptedVoiceOpusValidator validator,
        bool delegate(AcceptedVoiceArtifact artifact) turnCommitted = null,
        ulong maxBytes = acceptedVoiceArtifactMaxBytes,
    )
    {
        enforce(files !is null, "Accepted voice runtime files are required");
        enforce(validator !is null, "Accepted voice Opus validator is required");
        enforce(maxBytes > 0 && maxBytes <= acceptedVoiceArtifactMaxBytes,
            "Accepted voice replica byte cap is invalid");
        this.files = files;
        this.validator = validator;
        this.turnCommitted = turnCommitted;
        this.maxBytes = maxBytes;
        this.mutex = new TaskMutex;
    }

    /// Imports one exact Opus upload or recognizes an already committed sidecar.
    void importOpus(AcceptedVoiceArtifact artifact, string uploadPath)
    {
        auto guard = scopedMutexLock(mutex);
        validateAcceptedVoiceArtifact(artifact);
        enforce(artifact.bytes <= maxBytes,
            "Accepted voice artifact exceeds replica byte cap");
        auto targetPath = files.stagedUserAudioPath(
            artifact.profileId,
            artifact.submissionId,
        );
        auto local = acceptedVoiceManifest(artifact, targetPath);
        auto sidecarPath = acceptedVoiceManifestPath(targetPath);

        bool matchingSidecar;
        if (exists(sidecarPath)) {
            auto saved = loadAcceptedVoiceManifest(targetPath);
            enforce(sameManifest(saved, local), "Accepted voice sidecar conflicts with upload");
            matchingSidecar = true;
        }

        if (exists(targetPath)) {
            enforceExactArtifact(targetPath, artifact);
            if (!exists(sidecarPath)) writeAcceptedVoiceManifest(local);
            return;
        }

        if (matchingSidecar && turnCommitted !is null && turnCommitted(artifact)) {
            if (uploadPath.length) {
                enforce(exists(uploadPath), "Accepted voice upload does not exist");
                enforceExactArtifact(uploadPath, artifact);
            }
            return;
        }

        if (!uploadPath.length) {
            enforce(
                exists(sidecarPath) && turnCommitted !is null && turnCommitted(artifact),
                "Accepted voice upload is required before its turn is committed",
            );
            return;
        }

        enforce(exists(uploadPath), "Accepted voice upload does not exist");
        enforceExactArtifact(uploadPath, artifact);
        stageExactArtifact(local, uploadPath, targetPath);
    }

    private void stageExactArtifact(
        AcceptedVoiceManifest manifest,
        string uploadPath,
        string targetPath,
    )
    {
        mkdirRecurse(dirName(targetPath));
        auto temporaryPath = buildPath(
            dirName(targetPath),
            "." ~ manifest.artifact.submissionId ~ ".partial-" ~ randomUUID().toString() ~ ".opus",
        );
        bool promoted;
        scope(failure) {
            if (exists(temporaryPath)) remove(temporaryPath);
            if (promoted && exists(targetPath)) remove(targetPath);
        }

        copy(uploadPath, temporaryPath);
        enforceExactArtifact(temporaryPath, manifest.artifact);
        validator.validateOpus(temporaryPath);
        rename(temporaryPath, targetPath);
        promoted = true;
        writeAcceptedVoiceManifest(manifest);
    }
}

private void enforceExactArtifact(string path, AcceptedVoiceArtifact artifact)
{
    enforce(cast(ulong) getSize(path) == artifact.bytes,
        "Accepted voice artifact byte count changed");
    enforce(acceptedVoiceArtifactFileSha256(path) == artifact.sha256,
        "Accepted voice artifact SHA-256 changed");
}

private bool sameManifest(AcceptedVoiceManifest left, AcceptedVoiceManifest right)
{
    return left.profileId == right.profileId
        && left.sessionId == right.sessionId
        && left.submissionId == right.submissionId
        && left.deviceId == right.deviceId
        && left.userText == right.userText
        && left.language == right.language
        && left.loadMemory == right.loadMemory
        && left.audio.artifactKey == right.audio.artifactKey
        && left.audio.profileId == right.audio.profileId
        && left.audio.createdAt == right.audio.createdAt
        && left.audio.bytes == right.audio.bytes
        && left.audio.durationSeconds == right.audio.durationSeconds
        && left.audio.hasDuration == right.audio.hasDuration
        && left.audio.opusEncodeMs == right.audio.opusEncodeMs
        && left.audio.hasOpusEncodeMs == right.audio.hasOpusEncodeMs
        && left.artifact == right.artifact;
}

private final class TestValidator : AcceptedVoiceOpusValidator
{
    bool reject;
    bool yieldDuringValidation;
    int calls;

    void validateOpus(string path)
    {
        calls++;
        if (reject) throw new Exception("corrupt Ogg/Opus");
        if (yieldDuringValidation) yield();
    }
}

private AcceptedVoiceManifest testManifest(string sourcePath, ubyte[] bytes)
{
    import wheatley.common.api.accepted_voice_artifact : acceptedVoiceArtifactSha256;
    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;

    auto artifact = AcceptedVoiceArtifact(
        "tester", "2026/08/05/12_00_00", "submission-a",
        "runtime-user-audio:submission-a", "audio_live", "Accepted words", "en", "device-a", true,
        ReasoningMode.off, "model-a", "2026-08-05T12:00:00Z", bytes.length,
        1, true, 4, true, acceptedVoiceArtifactSha256(bytes), "2026-08-05T12:00:00Z",
        "{\"accepted_seconds\":1}", "{}", "{}",
    );
    return AcceptedVoiceManifest(
        "tester", "2026/08/05/12_00_00", "submission-a", "device-a",
        "Accepted words", "en", true,
        UserAudioArtifactRecord(
            artifact.artifactKey, "tester", "2026-08-05T12:00:00Z", sourcePath,
            bytes.length, 1, true, 4, true,
        ),
        artifact,
    );
}

unittest
{
    import std.exception : assertThrown;
    import std.file : rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import vibe.core.core : runTask;

    auto root = buildPath(tempDir(), "wheatley-accepted-replica-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto uploadPath = buildPath(root, "upload.opus");
    auto bytes = cast(ubyte[]) [1, 2, 3];
    mkdirRecurse(root);
    write(uploadPath, bytes);

    auto files = new RuntimeFiles(buildPath(root, "profiles"));
    auto validator = new TestValidator;
    auto replica = new AcceptedVoiceReplica(files, validator);
    auto manifest = testManifest(uploadPath, bytes);
    auto targetPath = files.stagedUserAudioPath("tester", "submission-a");
    auto sidecarPath = acceptedVoiceManifestPath(targetPath);

    auto raceFiles = new RuntimeFiles(buildPath(root, "race"));
    auto raceValidator = new TestValidator;
    raceValidator.yieldDuringValidation = true;
    auto raceReplica = new AcceptedVoiceReplica(raceFiles, raceValidator);
    bool firstSucceeded;
    bool secondSucceeded;
    auto first = runTask(() nothrow {
        try {
            raceReplica.importOpus(manifest.artifact, uploadPath);
            firstSucceeded = true;
        } catch (Throwable) {
        }
    });
    auto second = runTask(() nothrow {
        try {
            raceReplica.importOpus(manifest.artifact, uploadPath);
            secondSucceeded = true;
        } catch (Throwable) {
        }
    });
    first.join();
    second.join();
    assert(firstSucceeded && secondSucceeded);
    assert(raceValidator.calls == 1);

    replica.importOpus(manifest.artifact, uploadPath);
    assert(exists(targetPath));
    assert(exists(sidecarPath));
    assert(validator.calls == 1);

    // Exact retry does not replace or revalidate the already staged artifact.
    replica.importOpus(manifest.artifact, uploadPath);
    assert(validator.calls == 1);

    auto conflicting = manifest;
    conflicting.artifact.source = "conflicting_source";
    assertThrown!Exception(replica.importOpus(conflicting.artifact, uploadPath));
    assert(exists(targetPath));

    // A committed turn may legitimately have moved the staging Opus away.
    remove(targetPath);
    auto committedReplica = new AcceptedVoiceReplica(files, validator, (_) => true);
    committedReplica.importOpus(manifest.artifact, "");
    assert(!exists(targetPath));

    // A matching upload retry after commit remains a no-op and does not leak
    // another staging copy.
    committedReplica.importOpus(manifest.artifact, uploadPath);
    assert(!exists(targetPath));

    auto corruptRoot = buildPath(root, "corrupt");
    auto corruptFiles = new RuntimeFiles(corruptRoot);
    auto rejecting = new TestValidator;
    rejecting.reject = true;
    auto corruptReplica = new AcceptedVoiceReplica(corruptFiles, rejecting);
    auto corruptManifest = testManifest(uploadPath, bytes);
    auto corruptTarget = corruptFiles.stagedUserAudioPath("tester", "submission-a");
    assertThrown!Exception(corruptReplica.importOpus(corruptManifest.artifact, uploadPath));
    assert(!exists(corruptTarget));
    assert(!exists(acceptedVoiceManifestPath(corruptTarget)));

    auto cappedFiles = new RuntimeFiles(buildPath(root, "capped"));
    auto cappedReplica = new AcceptedVoiceReplica(cappedFiles, validator, null, 2);
    auto cappedTarget = cappedFiles.stagedUserAudioPath("tester", "submission-a");
    assertThrown!Exception(cappedReplica.importOpus(manifest.artifact, uploadPath));
    assert(!exists(cappedTarget));
    assert(!exists(acceptedVoiceManifestPath(cappedTarget)));
}
