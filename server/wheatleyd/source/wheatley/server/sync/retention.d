module wheatley.server.sync.retention;

import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.uuid : randomUUID;

import wheatley.server.config.app_config_store : AppConfigStore;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.json : writeTextFile;
import wheatley.server.history.store.markdown : turnMarkdown;
import wheatley.server.sync.outbox : ProfileSyncOutbox;

/// Keeps only the local current/last replica sessions once older sessions are
/// fully exportable, acknowledged, and free of pending outbox work.
void pruneAcknowledgedReplicaSessions(
    HistoryStore store,
    ProfileSyncOutbox outbox,
    string profileId,
)
{
    auto sessions = store.syncSessionPaths(profileId);
    if (sessions.length <= 2) return;
    foreach (sessionPath; sessions[0 .. $ - 2]) {
        if (!store.syncSessionIsFullyExportable(profileId, sessionPath)) continue;
        if (outbox.hasPendingSessionWork(profileId, sessionPath)) continue;
        if (!sessionAcknowledged(store, outbox, profileId, sessionPath)) continue;
        store.removeNonCurrentSyncSession(profileId, sessionPath);
    }
}

private bool sessionAcknowledged(
    HistoryStore store,
    ProfileSyncOutbox outbox,
    string profileId,
    string sessionPath,
)
{
    foreach (turn; store.exportReadyTurns(profileId)) {
        if (turn.sessionPath != sessionPath) continue;
        if (!outbox.acknowledged(profileId, sessionPath, turn.turnPath)) return false;
        if (turn.piSessionJsonlPath.length && !outbox.piAcknowledged(profileId, sessionPath))
            return false;
    }
    return true;
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-sync-retention-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(profilesRoot, new AppConfigStore(configPath), root);
    auto outbox = new ProfileSyncOutbox(buildPath(root, "outbox"));

    auto empty = addSession(profilesRoot, "tester", "2026/08/05/07_00_00", false);
    auto pending = addSession(profilesRoot, "tester", "2026/08/05/08_00_00", true);
    auto unacknowledged = addSession(profilesRoot, "tester", "2026/08/05/09_00_00", true);
    auto removable = addCompletedSession(profilesRoot, "tester", "2026/08/05/10_00_00");
    auto last = addCompletedSession(profilesRoot, "tester", "2026/08/05/11_00_00");
    auto current = addCompletedSession(profilesRoot, "tester", "2026/08/05/12_00_00");
    outbox.markPending("tester", pending, "10_00_01_000001");
    outbox.markPending("tester", removable, "10_00_01_000001");
    outbox.acknowledge("tester", removable, "10_00_01_000001");
    pruneAcknowledgedReplicaSessions(store, outbox, "tester");

    assert(!sessionExists(store, "tester", empty));
    assert(sessionExists(store, "tester", pending));
    assert(sessionExists(store, "tester", unacknowledged));
    assert(!sessionExists(store, "tester", removable));
    assert(sessionExists(store, "tester", last));
    assert(sessionExists(store, "tester", current));
}

private string addCompletedSession(string profilesRoot, string profileId, string sessionPath)
{
    return addSession(profilesRoot, profileId, sessionPath, true);
}

private string addSession(string profilesRoot, string profileId, string sessionPath, bool withTurn)
{
    import std.string : split;

    auto parts = sessionPath.split("/");
    auto root = buildPath(profilesRoot, profileId, "sessions", parts[0], parts[1], parts[2], parts[3]);
    writeTextFile(buildPath(root, "session.json"),
        `{"client":"offline","language":"en","model":"","reasoning_mode":"off"}`);
    if (!withTurn) return sessionPath;
    auto turn = "10_00_01_000001";
    auto turnRoot = buildPath(root, "turns", turn);
    writeTextFile(buildPath(turnRoot, "turn.json"),
        `{"source":"offline","status":"completed","completed_at":"2026-08-05T10:00:01.000001Z","user_audio_required":false,"reasoning_mode":"off"}`);
    writeTextFile(buildPath(turnRoot, "turn.md"), turnMarkdown("prompt", "answer"));
    return sessionPath;
}

private bool sessionExists(HistoryStore store, string profileId, string sessionPath)
{
    foreach (path; store.syncSessionPaths(profileId)) {
        if (path == sessionPath) return true;
    }
    return false;
}
