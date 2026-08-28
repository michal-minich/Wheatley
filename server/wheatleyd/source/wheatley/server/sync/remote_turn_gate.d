module wheatley.server.sync.remote_turn_gate;

import std.algorithm : startsWith;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
import std.json : parseJSON;
import std.path : buildPath;
import std.string : endsWith;
import std.uuid : randomUUID;

import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.accepted_voice_artifact :
    AcceptedVoiceArtifact,
    validateAcceptedVoiceArtifact;
import wheatley.common.api.remote_turn_sync : RemoteTurnSessionHandoff;
import wheatley.common.api.session_sync :
    SessionSyncManifest,
    SessionSyncManifestFile;
import wheatley.common.json.read : Json;
import wheatley.server.config.app_config_store : AppConfigStore;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.sync : CompletedTurnImport;
import wheatley.server.history.store.sync_export :
    SyncCompletedTurnExport,
    SyncSessionSnapshot;
import wheatley.server.history.store.sync_paths : parseSyncTurnPath;
import wheatley.server.sync.outbox : ProfileSyncOutbox;
import wheatley.server.sync.remote_turn_peer : RemoteTurnSyncPeer;
import wheatley.server.sync.remote_turn_placement : RemoteTurnPlacementGate;

alias PendingAcceptedVoiceArtifacts = bool delegate(
    SessionKey session,
    string excludedSubmissionId,
);

/// Profile-owned prerequisite around one turn executed by remote Conversation.
final class RemoteTurnSyncGate : RemoteTurnPlacementGate
{
    private HistoryStore store;
    private ProfileSyncOutbox outbox;
    private RemoteTurnSyncPeer remote;
    private TaskMutex mutex;
    private PendingAcceptedVoiceArtifacts pendingAcceptedVoiceArtifacts;

    this(
        HistoryStore store,
        ProfileSyncOutbox outbox,
        RemoteTurnSyncPeer remote,
        PendingAcceptedVoiceArtifacts pendingAcceptedVoiceArtifacts,
        TaskMutex mutex = null,
    )
    {
        enforce(store !is null, "Remote turn history store is required");
        enforce(outbox !is null, "Remote turn outbox is required");
        enforce(remote !is null, "Remote turn peer is required");
        enforce(pendingAcceptedVoiceArtifacts !is null,
            "Accepted voice pending-work query is required");
        this.store = store;
        this.outbox = outbox;
        this.remote = remote;
        this.pendingAcceptedVoiceArtifacts = pendingAcceptedVoiceArtifacts;
        this.mutex = mutex is null ? new TaskMutex : mutex;
    }

    /// Makes the authoritative peer safe to execute the next turn in session.
    void prepare(SessionKey session)
    {
        auto guard = scopedMutexLock(mutex);
        foreach (turn; store.exportReadyTurns(session.profileId))
            uploadIfNeeded(turn);

        enforce(
            !pendingAcceptedVoiceArtifacts(session, ""),
            "Remote Conversation is blocked by an accepted voice prompt awaiting commit",
        );
        enforce(
            store.syncSessionIsFullyExportable(session.profileId, session.sessionId),
            "Remote Conversation is blocked by incomplete local session work or audio",
        );
        enforce(
            !outbox.hasPendingProfileWork(session.profileId),
            "Remote Conversation is blocked by unacknowledged profile work",
        );
        enforceSessionAcknowledged(session);
        remote.ensureSession(
            session.profileId,
            store.remoteTurnSessionHandoff(session),
        );
    }

    /// Hands one accepted local Opus to the authority without treating that
    /// same staged prompt as unrelated pending work.
    void prepareAcceptedVoice(
        SessionKey session,
        AcceptedVoiceArtifact artifact,
        string opusPath,
    )
    {
        auto guard = scopedMutexLock(mutex);
        validateAcceptedVoiceArtifact(artifact);
        enforce(artifact.profileId == session.profileId,
            "Accepted voice profile changed before remote handoff");
        enforce(artifact.sessionId == session.sessionId,
            "Accepted voice session changed before remote handoff");
        foreach (turn; store.exportReadyTurns(session.profileId))
            uploadIfNeeded(turn);

        enforce(
            !pendingAcceptedVoiceArtifacts(session, artifact.submissionId),
            "Remote Conversation is blocked by another accepted voice prompt awaiting commit",
        );
        enforce(
            store.syncSessionIsFullyExportable(session.profileId, session.sessionId),
            "Remote Conversation is blocked by incomplete local session work or audio",
        );
        enforce(
            !outbox.hasPendingProfileWork(session.profileId),
            "Remote Conversation is blocked by unacknowledged profile work",
        );
        enforceSessionAcknowledged(session);
        remote.ensureSession(
            session.profileId,
            store.remoteTurnSessionHandoff(session),
        );
        remote.importAcceptedVoice(artifact, opusPath);
    }

    /// Imports one exact authoritative terminal turn before local terminal use.
    void materializeTerminalTurn(SessionKey session, string turnId)
    {
        auto guard = scopedMutexLock(mutex);
        auto turnPath = turnPathFromId(session, turnId);
        auto manifest = remote.exactTurn(
            session.profileId,
            session.sessionId,
            turnPath,
        );
        enforce(manifest.sessionPath == session.sessionId,
            "Remote terminal session changed");
        validateExactManifest(manifest.files, turnPath);

        if (!store.hasSyncTurn(session.profileId, session.sessionId, turnPath)) {
            importExactTurn(session, turnPath, manifest.files);
            enforce(store.hasSyncTurn(session.profileId, session.sessionId, turnPath),
                "Remote terminal turn was not materialized");
        }
        outbox.acknowledge(session.profileId, session.sessionId, turnPath);
        if (hasPrimaryPi(manifest.files))
            outbox.acknowledgePi(session.profileId, session.sessionId);
    }

    private void uploadIfNeeded(SyncCompletedTurnExport turn)
    {
        if (outbox.acknowledged(turn.profileId, turn.sessionPath, turn.turnPath)) return;
        outbox.markPending(turn.profileId, turn.sessionPath, turn.turnPath);
        auto includePi = turn.piSessionJsonlPath.length
            && !outbox.piAcknowledged(turn.profileId, turn.sessionPath);
        if (includePi) outbox.markPiPending(turn.profileId, turn.sessionPath);
        remote.uploadCompletedTurn(turn, includePi);
        outbox.acknowledge(turn.profileId, turn.sessionPath, turn.turnPath);
        if (includePi) outbox.acknowledgePi(turn.profileId, turn.sessionPath);
    }

    private void enforceSessionAcknowledged(SessionKey session)
    {
        foreach (turn; store.exportReadyTurns(session.profileId)) {
            if (turn.sessionPath != session.sessionId) continue;
            enforce(
                outbox.acknowledged(turn.profileId, turn.sessionPath, turn.turnPath),
                "Remote Conversation session turn is not acknowledged",
            );
            if (turn.piSessionJsonlPath.length) {
                enforce(
                    outbox.piAcknowledged(turn.profileId, turn.sessionPath),
                    "Remote Conversation session Pi state is not acknowledged",
                );
            }
        }
    }

    private void importExactTurn(
        SessionKey session,
        string turnPath,
        SessionSyncManifestFile[] files,
    )
    {
        auto stageRoot = buildPath(
            tempDir(),
            "wheatley-remote-turn-" ~ randomUUID().toString(),
        );
        scope(exit) if (exists(stageRoot)) rmdirRecurse(stageRoot);
        mkdirRecurse(stageRoot);

        ExactTurnDownload downloaded;
        foreach (file; files) {
            if (!wantedExactFile(file, turnPath)) continue;
            auto target = file.turnPath.length
                ? buildPath(stageRoot, "turn", file.name)
                : buildPath(stageRoot, file.name);
            remote.downloadExactTurnFile(
                session.profileId,
                session.sessionId,
                turnPath,
                file,
                target,
            );
            downloaded.set(file, target);
        }
        enforce(downloaded.sessionJsonPath.length,
            "Remote terminal session.json is missing");
        enforce(downloaded.turnJsonPath.length,
            "Remote terminal turn.json is missing");
        enforce(downloaded.turnMarkdownPath.length,
            "Remote terminal turn.md is missing");
        auto turn = Json.object(parseJSON(readText(downloaded.turnJsonPath)));
        store.importCompletedTurn(CompletedTurnImport(
            session.profileId,
            session.sessionId,
            turnPath,
            downloaded.sessionJsonPath,
            downloaded.turnJsonPath,
            downloaded.turnMarkdownPath,
            downloaded.piSessionJsonlPath,
            downloaded.userOpusPath,
            downloaded.errorsJsonPath,
            downloaded.toolsJsonPath,
            downloaded.llmRequestsJsonPath,
            turn.boolean("user_audio_required"),
        ));
    }
}

private struct ExactTurnDownload
{
    string sessionJsonPath;
    string piSessionJsonlPath;
    string turnJsonPath;
    string turnMarkdownPath;
    string userOpusPath;
    string errorsJsonPath;
    string toolsJsonPath;
    string llmRequestsJsonPath;

    void set(SessionSyncManifestFile file, string path)
    {
        if (!file.turnPath.length) {
            if (file.name == "session.json") sessionJsonPath = path;
            else if (file.name == "pi_session.jsonl") piSessionJsonlPath = path;
            return;
        }
        if (file.name == "turn.json") turnJsonPath = path;
        else if (file.name == "turn.md") turnMarkdownPath = path;
        else if (file.name == "user.opus") userOpusPath = path;
        else if (file.name == "errors.json") errorsJsonPath = path;
        else if (file.name == "tools.json") toolsJsonPath = path;
        else if (file.name == "llm-requests.json") llmRequestsJsonPath = path;
    }
}

private string turnPathFromId(SessionKey session, string turnId)
{
    auto prefix = session.profileId ~ "/sessions/" ~ session.sessionId ~ "/turns/";
    enforce(turnId.startsWith(prefix), "Remote terminal turn is outside its session");
    auto result = turnId[prefix.length .. $];
    parseSyncTurnPath(result);
    return result;
}

private void validateExactManifest(SessionSyncManifestFile[] files, string turnPath)
{
    bool hasSession;
    bool hasTurn;
    bool hasMarkdown;
    foreach (file; files) {
        enforce(
            !file.turnPath.length || file.turnPath == turnPath,
            "Remote terminal manifest contains another turn",
        );
        enforce(isExactFile(file), "Remote terminal manifest file is unsupported");
        if (!file.turnPath.length && file.name == "session.json") hasSession = true;
        if (file.turnPath.length && file.name == "turn.json") hasTurn = true;
        if (file.turnPath.length && file.name == "turn.md") hasMarkdown = true;
    }
    enforce(hasSession, "Remote terminal manifest has no session.json");
    enforce(hasTurn, "Remote terminal manifest has no turn.json");
    enforce(hasMarkdown, "Remote terminal manifest has no turn.md");
}

private bool wantedExactFile(SessionSyncManifestFile file, string turnPath)
{
    if (file.turnPath == turnPath) return true;
    return !file.turnPath.length
        && (file.name == "session.json" || file.name == "pi_session.jsonl");
}

private bool isExactFile(SessionSyncManifestFile file)
{
    if (!file.turnPath.length) {
        if (file.name == "session.json" || file.name == "pi_session.jsonl") return true;
        if (!file.name.startsWith("pi_session_") || !file.name.endsWith(".jsonl"))
            return false;
        auto number = file.name["pi_session_".length .. $ - ".jsonl".length];
        if (!number.length) return false;
        long value;
        foreach (ch; number) {
            if (ch < '0' || ch > '9') return false;
            value = value * 10 + ch - '0';
        }
        return value >= 2;
    }
    return file.name == "turn.json" || file.name == "turn.md"
        || file.name == "user.opus" || file.name == "errors.json"
        || file.name == "tools.json" || file.name == "llm-requests.json";
}

private bool hasPrimaryPi(SessionSyncManifestFile[] files)
{
    foreach (file; files) {
        if (!file.turnPath.length && file.name == "pi_session.jsonl") return true;
    }
    return false;
}

unittest
{
    import std.exception : assertThrown;
    import wheatley.common.api.reasoning : ReasoningMode;

    auto root = buildPath(
        tempDir(),
        "wheatley-remote-turn-gate-" ~ randomUUID().toString(),
    );
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto local = testStore(buildPath(root, "local"));
    auto upstream = testStore(buildPath(root, "upstream"));
    auto peer = new StoreRemoteTurnPeer(upstream);
    auto outbox = new ProfileSyncOutbox(buildPath(root, "outbox"));
    string[] pendingAcceptedVoice;
    auto gate = new RemoteTurnSyncGate(
        local,
        outbox,
        peer,
        (session, excluded) {
            foreach (submissionId; pendingAcceptedVoice) {
                if (submissionId != excluded) return true;
            }
            return false;
        },
    );

    auto prior = local.startProfileSession(
        "tester",
        "2026-08-05T09:00:00.000000Z",
        "chat",
        "en",
        ReasoningMode.off,
        "model",
    );
    completeTestTurn(
        local,
        prior,
        "2026-08-05T09:00:01.000001Z",
        "prior-submission",
        "Prior prompt",
        "Prior answer",
    );
    auto current = local.startProfileSession(
        "tester",
        "2026-08-05T10:00:00.000000Z",
        "chat",
        "en",
        ReasoningMode.off,
        "model",
    );

    // A zero-turn session is handed off after all prior work is acknowledged.
    gate.prepare(current);
    assert(peer.uploadCount == 1);
    assert(peer.ensureCount == 1);
    assert(upstream.syncSessionPaths("tester") == [prior.sessionId, current.sessionId]);

    auto remoteTurnId = completeTestTurn(
        upstream,
        current,
        "2026-08-05T10:00:01.000001Z",
        "remote-submission",
        "Remote prompt",
        "Remote answer",
    );
    auto unrelated = upstream.startProfileSession(
        "tester",
        "2026-08-05T11:00:00.000000Z",
        "chat",
        "en",
        ReasoningMode.off,
        "model",
    );
    completeTestTurn(
        upstream,
        unrelated,
        "2026-08-05T11:00:01.000001Z",
        "unrelated-submission",
        "Unrelated prompt",
        "Unrelated answer",
    );

    // Materialization addresses the exact session even when it is not latest.
    gate.materializeTerminalTurn(current, remoteTurnId);
    auto localRemote = local.findTurn(current, remoteTurnId);
    assert(localRemote.assistantText == "Remote answer");
    assert(local.syncSessionPaths("tester") == [prior.sessionId, current.sessionId]);
    auto downloads = peer.downloadCount;
    assert(downloads >= 3);

    // A repeated terminal delivery is an ACK-only no-op.
    gate.materializeTerminalTurn(current, remoteTurnId);
    assert(peer.downloadCount == downloads);
    auto remoteTurnPath = turnPathFromId(current, remoteTurnId);
    assert(outbox.acknowledged("tester", current.sessionId, remoteTurnPath));

    // Accepted audio awaiting its durable voice turn blocks handoff.
    pendingAcceptedVoice = ["accepted-submission"];
    auto ensuresBeforeAccepted = peer.ensureCount;
    assertThrown!Exception(gate.prepare(current));
    assert(peer.ensureCount == ensuresBeforeAccepted);
    auto accepted = testAcceptedVoiceArtifact(current);
    auto acceptedPath = buildPath(root, "accepted.opus");
    import std.file : write;
    write(acceptedPath, cast(ubyte[]) [1]);
    gate.prepareAcceptedVoice(current, accepted, acceptedPath);
    assert(peer.acceptedUploadCount == 1);
    pendingAcceptedVoice ~= "other-accepted-submission";
    assertThrown!Exception(gate.prepareAcceptedVoice(current, accepted, acceptedPath));
    assert(peer.acceptedUploadCount == 1);
    pendingAcceptedVoice = [];

    // A terminal voice record without its required Opus blocks remote use.
    auto blocked = local.startProfileSession(
        "tester",
        "2026-08-05T12:00:00.000000Z",
        "chat",
        "en",
        ReasoningMode.off,
        "model",
    );
    completeTestTurn(
        local,
        blocked,
        "2026-08-05T12:00:01.000001Z",
        "missing-audio",
        "Voice prompt",
        "Answer",
        true,
    );
    auto ensuresBeforeBlocked = peer.ensureCount;
    assertThrown!Exception(gate.prepare(blocked));
    assert(peer.ensureCount == ensuresBeforeBlocked);

    // Upstream loss leaves a durable pending marker and never hands off.
    auto unavailableRoot = buildPath(root, "unavailable");
    auto unavailableStore = testStore(unavailableRoot);
    auto unavailableSession = unavailableStore.startProfileSession(
        "tester",
        "2026-08-05T13:00:00.000000Z",
        "chat",
        "en",
        ReasoningMode.off,
        "model",
    );
    completeTestTurn(
        unavailableStore,
        unavailableSession,
        "2026-08-05T13:00:01.000001Z",
        "unavailable-submission",
        "Offline prompt",
        "Offline answer",
    );
    auto unavailableOutbox = new ProfileSyncOutbox(buildPath(root, "unavailable-outbox"));
    auto unavailablePeer = new StoreRemoteTurnPeer(upstream);
    unavailablePeer.failUpload = true;
    auto unavailableGate = new RemoteTurnSyncGate(
        unavailableStore,
        unavailableOutbox,
        unavailablePeer,
        (session, excluded) => false,
    );
    assertThrown!Exception(unavailableGate.prepare(unavailableSession));
    assert(unavailableOutbox.hasPendingProfileWork("tester"));
    assert(unavailablePeer.ensureCount == 0);
}

private HistoryStore testStore(string root)
{
    import std.file : write;

    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    return new HistoryStore(
        profilesRoot,
        new AppConfigStore(configPath),
        root,
    );
}

private string completeTestTurn(
    HistoryStore store,
    SessionKey session,
    string startedAt,
    string submissionId,
    string prompt,
    string answer,
    bool userAudioRequired = false,
)
{
    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
    import wheatley.server.history.rows.text_turn_record : TextTurnRecord;

    return store.saveTextTurn(TextTurnRecord(
        submissionId,
        session.profileId,
        session.sessionId,
        "test-device",
        "test",
        "completed",
        startedAt,
        startedAt,
        "model",
        "en",
        prompt,
        answer,
        "{}",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
        ReasoningMode.off,
        userAudioRequired,
        submissionId,
        "",
        "{}",
    ));
}

private final class StoreRemoteTurnPeer : RemoteTurnSyncPeer
{
    private HistoryStore store;
    int uploadCount;
    int ensureCount;
    int downloadCount;
    int acceptedUploadCount;
    bool failUpload;

    this(HistoryStore store)
    {
        this.store = store;
    }

    void uploadCompletedTurn(SyncCompletedTurnExport turn, bool includePi)
    {
        if (failUpload) throw new Exception("upstream unavailable");
        uploadCount++;
        store.importCompletedTurn(CompletedTurnImport(
            turn.profileId,
            turn.sessionPath,
            turn.turnPath,
            turn.sessionJsonPath,
            turn.turnJsonPath,
            turn.turnMarkdownPath,
            includePi ? turn.piSessionJsonlPath : "",
            turn.userOpusPath,
            turn.errorsJsonPath,
            turn.toolsJsonPath,
            turn.llmRequestsJsonPath,
            turn.userAudioRequired,
        ));
    }

    void ensureSession(
        string profileId,
        RemoteTurnSessionHandoff handoff,
    )
    {
        ensureCount++;
        store.ensureSyncedSession(profileId, handoff);
    }

    void importAcceptedVoice(AcceptedVoiceArtifact artifact, string opusPath)
    {
        acceptedUploadCount++;
    }

    SessionSyncManifest exactTurn(
        string profileId,
        string sessionPath,
        string turnPath,
    )
    {
        return manifestFromSnapshot(store.sessionTurnSnapshot(
            profileId,
            sessionPath,
            turnPath,
        ), turnPath);
    }

    void downloadExactTurnFile(
        string profileId,
        string sessionPath,
        string turnPath,
        SessionSyncManifestFile file,
        string targetPath,
    )
    {
        import std.file : copy;
        import std.path : dirName;

        auto relativePath = file.turnPath.length
            ? "turns/" ~ file.turnPath ~ "/" ~ file.name
            : file.name;
        auto source = store.resolveSessionTurnSnapshotFile(
            profileId,
            sessionPath,
            turnPath,
            relativePath,
        );
        mkdirRecurse(dirName(targetPath));
        copy(source.localPath, targetPath);
        downloadCount++;
    }
}

private AcceptedVoiceArtifact testAcceptedVoiceArtifact(SessionKey session)
{
    import wheatley.common.api.accepted_voice_artifact : acceptedVoiceArtifactSha256;
    import wheatley.common.api.reasoning : ReasoningMode;

    return AcceptedVoiceArtifact(
        session.profileId,
        session.sessionId,
        "accepted-submission",
        "runtime-user-audio:accepted-submission",
        "audio_live",
        "Accepted words",
        "en",
        "device",
        true,
        ReasoningMode.off,
        "model",
        "2026-08-05T10:00:00Z",
        1,
        1,
        true,
        4,
        true,
        acceptedVoiceArtifactSha256(cast(ubyte[]) [1]),
        "",
        "{}",
        "{}",
        "{}",
    );
}

private SessionSyncManifest manifestFromSnapshot(
    SyncSessionSnapshot snapshot,
    string turnPath,
)
{
    SessionSyncManifestFile[] files;
    auto prefix = "turns/" ~ turnPath ~ "/";
    foreach (file; snapshot.files) {
        if (file.relativePath.startsWith(prefix)) {
            files ~= SessionSyncManifestFile(turnPath, file.relativePath[prefix.length .. $]);
        } else {
            files ~= SessionSyncManifestFile("", file.relativePath);
        }
    }
    return SessionSyncManifest(snapshot.sessionPath, files);
}
