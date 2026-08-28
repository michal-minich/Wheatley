module wheatley.server.sync.outbox;

import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, remove, rename, tempDir, write;
import std.path : baseName, buildPath, dirName;
import std.string : endsWith;

import wheatley.common.safe_token : enforceSafeToken;
import wheatley.server.history.store.sync_paths :
    parseSyncSessionPath,
    parseSyncTurnPath;

final class ProfileSyncOutbox
{
    private string root;

    this(string root)
    {
        enforce(root.length, "Profile sync outbox root is required");
        this.root = root;
        mkdirRecurse(root);
    }

    bool acknowledged(string profileId, string sessionPath, string turnPath)
    {
        return exists(statePath(profileId, sessionPath, turnPath, ".ack"));
    }

    bool piAcknowledged(string profileId, string sessionPath)
    {
        return exists(sessionStatePath(profileId, sessionPath, "pi.ack"));
    }

    void markPending(string profileId, string sessionPath, string turnPath)
    {
        if (acknowledged(profileId, sessionPath, turnPath)) return;
        auto path = statePath(profileId, sessionPath, turnPath, ".pending");
        if (exists(path)) return;
        mkdirRecurse(dirName(path));
        write(path, "");
    }

    void acknowledge(string profileId, string sessionPath, string turnPath)
    {
        auto pending = statePath(profileId, sessionPath, turnPath, ".pending");
        auto acknowledged = statePath(profileId, sessionPath, turnPath, ".ack");
        if (exists(acknowledged)) {
            if (exists(pending)) remove(pending);
            return;
        }
        mkdirRecurse(dirName(acknowledged));
        if (!exists(pending)) write(pending, "");
        rename(pending, acknowledged);
    }

    void markPiPending(string profileId, string sessionPath)
    {
        if (piAcknowledged(profileId, sessionPath)) return;
        auto path = sessionStatePath(profileId, sessionPath, "pi.pending");
        if (exists(path)) return;
        mkdirRecurse(dirName(path));
        write(path, "");
    }

    void acknowledgePi(string profileId, string sessionPath)
    {
        auto pending = sessionStatePath(profileId, sessionPath, "pi.pending");
        auto acknowledged = sessionStatePath(profileId, sessionPath, "pi.ack");
        if (exists(acknowledged)) {
            if (exists(pending)) remove(pending);
            return;
        }
        mkdirRecurse(dirName(acknowledged));
        if (!exists(pending)) write(pending, "");
        rename(pending, acknowledged);
    }

    bool hasPendingSessionWork(string profileId, string sessionPath)
    {
        auto session = parseSyncSessionPath(sessionPath);
        enforceSafeToken(profileId, "Sync profile");
        auto sessionRoot = buildPath(
            root,
            profileId,
            session.year,
            session.month,
            session.day,
            session.folder,
        );
        if (!exists(sessionRoot)) return false;
        foreach (entry; dirEntries(sessionRoot, SpanMode.depth)) {
            if (entry.isFile && baseName(entry.name).endsWith(".pending")) return true;
        }
        return false;
    }

    bool hasPendingProfileWork(string profileId)
    {
        enforceSafeToken(profileId, "Sync profile");
        auto profileRoot = buildPath(root, profileId);
        if (!exists(profileRoot)) return false;
        foreach (entry; dirEntries(profileRoot, SpanMode.depth)) {
            if (entry.isFile && baseName(entry.name).endsWith(".pending")) return true;
        }
        return false;
    }

    private string statePath(
        string profileId,
        string sessionPath,
        string turnPath,
        string suffix,
    )
    {
        enforceSafeToken(profileId, "Sync profile");
        auto session = parseSyncSessionPath(sessionPath);
        auto turn = parseSyncTurnPath(turnPath);
        return buildPath(
            root,
            profileId,
            session.year,
            session.month,
            session.day,
            session.folder,
            turn.folder ~ suffix,
        );
    }

    private string sessionStatePath(string profileId, string sessionPath, string name)
    {
        enforceSafeToken(profileId, "Sync profile");
        auto session = parseSyncSessionPath(sessionPath);
        return buildPath(
            root,
            profileId,
            session.year,
            session.month,
            session.day,
            session.folder,
            name,
        );
    }
}

unittest
{
    import std.file : rmdirRecurse;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-sync-outbox-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);

    auto outbox = new ProfileSyncOutbox(root);
    auto session = "2026/08/05/12_34_56";
    auto turn = "12_35_01_123456";
    assert(!outbox.acknowledged("tester", session, turn));
    outbox.markPending("tester", session, turn);
    outbox.markPiPending("tester", session);
    outbox.acknowledge("tester", session, turn);
    outbox.acknowledgePi("tester", session);
    assert(outbox.acknowledged("tester", session, turn));
    assert(outbox.piAcknowledged("tester", session));

    auto reopened = new ProfileSyncOutbox(root);
    assert(reopened.acknowledged("tester", session, turn));
    reopened.markPending("tester", session, turn);
    reopened.acknowledge("tester", session, turn);
}
