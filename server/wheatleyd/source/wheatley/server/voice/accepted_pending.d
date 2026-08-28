module wheatley.server.voice.accepted_pending;

import std.exception : enforce;
import std.file : exists;
import std.string : endsWith;

import wheatley.common.api.session : SessionKey;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.voice.accepted_manifest : loadAcceptedVoiceManifest;

private enum manifestSuffix = ".accepted.json";

/// True while an accepted prompt for this session still awaits its durable turn.
bool hasPendingAcceptedVoiceArtifacts(
    RuntimeFiles files,
    SessionKey session,
    string excludedSubmissionId = "",
)
{
    enforce(files !is null, "Accepted voice runtime files are required");
    foreach (manifestPath; files.stagedUserAudioManifestPaths(session.profileId)) {
        enforce(manifestPath.endsWith(manifestSuffix),
            "Accepted voice manifest path is invalid");
        auto audioPath = manifestPath[0 .. $ - manifestSuffix.length];
        // Successful commit moves the Opus into durable turn history while the
        // sidecar deliberately remains for idempotent commit replay.
        if (!exists(audioPath)) continue;
        auto manifest = loadAcceptedVoiceManifest(audioPath);
        if (
            manifest.sessionId == session.sessionId
            && manifest.submissionId != excludedSubmissionId
        ) return true;
    }
    return false;
}

unittest
{
    import std.file : mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    import wheatley.common.api.live_audio : LiveAudioFormat, LiveAudioStartRequest;
    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.common.api.text_turn : TextTurnRequest;
    import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
    import wheatley.server.voice.accepted_manifest : writeAcceptedVoiceManifest;

    auto root = buildPath(tempDir(), "wheatley-accepted-pending-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto files = new RuntimeFiles(root);
    auto audioPath = files.stagedUserAudioPath("tester", "submission-a");
    mkdirRecurse(buildPath(root, "tester", "files", "_staged", "user-audio"));
    write(audioPath, cast(ubyte[]) [1]);
    auto start = LiveAudioStartRequest(
        TextTurnRequest(
            "2026/08/05/12_00_00", "", "submission-a", "device-a", "en", "",
            true, ReasoningMode.off, "model-a", 0,
        ),
        LiveAudioFormat(), "turn", false, "", "", 2,
    );
    writeAcceptedVoiceManifest(
        "tester",
        start,
        "accepted words",
        "en",
        UserAudioArtifactRecord(
            "runtime-user-audio:submission-a", "tester", "2026-08-05T12:00:01Z",
            audioPath, 1, 0, false, 0, false,
        ),
    );

    assert(hasPendingAcceptedVoiceArtifacts(
        files,
        SessionKey("tester", "2026/08/05/12_00_00"),
    ));
    assert(!hasPendingAcceptedVoiceArtifacts(
        files,
        SessionKey("tester", "2026/08/05/12_00_00"),
        "submission-a",
    ));
    assert(!hasPendingAcceptedVoiceArtifacts(
        files,
        SessionKey("tester", "2026/08/05/13_00_00"),
    ));
    remove(audioPath);
    assert(!hasPendingAcceptedVoiceArtifacts(
        files,
        SessionKey("tester", "2026/08/05/12_00_00"),
    ));
}
