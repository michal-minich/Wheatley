module wheatley.server.history.store.recent_sessions;

import std.algorithm : sort;
import std.exception : enforce;
import std.file : exists, readText;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.string : strip;

import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.server.history.store.json : jsonText, objectField;
import wheatley.server.history.store.locations : HistoryStoreLocations;
import wheatley.server.history.store.markdown : readTurnMarkdown;
import wheatley.server.history.store.paths :
    piSessionJsonlPath,
    sessionStartFromPath;
import wheatley.server.history.store.reader : HistoryStoreReader;

struct RecentSession
{
    string id;
    string root;
    string startedAt;
    string language;
    string initialUserText;
}

package(wheatley.server.history) final class RecentSessionIndex
{
    private HistoryStoreLocations locations;
    private HistoryStoreReader reader;
    private TaskMutex mutex;
    private RecentSession[][string] sessionsByProfile;

    this(HistoryStoreLocations locations, HistoryStoreReader reader)
    {
        this.locations = locations;
        this.reader = reader;
        this.mutex = new TaskMutex;
    }

    RecentSession[] load(string profileId)
    {
        auto guard = scopedMutexLock(mutex);
        RecentSession[] visible;
        foreach (session; loadLocked(profileId)) {
            if (resumable(session)) visible ~= session;
        }
        return visible;
    }

    RecentSession get(string profileId, string sessionId)
    {
        auto guard = scopedMutexLock(mutex);
        foreach (session; loadLocked(profileId)) {
            if (session.id == sessionId && resumable(session)) return session;
        }
        enforce(false, "Session not found");
        return RecentSession.init;
    }

    void add(string profileId, string sessionRoot, string language)
    {
        auto guard = scopedMutexLock(mutex);
        auto loaded = profileId in sessionsByProfile;
        if (loaded is null) return;
        auto session = RecentSession(
            locations.sessionIdFromSessionRoot(profileId, sessionRoot),
            sessionRoot,
            sessionStartFromPath(sessionRoot),
            language,
            "",
        );
        enforce(session.id.length, "Session root is outside the profile sessions tree");
        *loaded ~= session;
        sortSessions(*loaded);
    }

    void invalidate(string profileId)
    {
        auto guard = scopedMutexLock(mutex);
        sessionsByProfile.remove(profileId);
    }

    void setInitialUserText(string profileId, string sessionRoot, string text)
    {
        auto clean = text.strip;
        if (!clean.length) return;
        auto guard = scopedMutexLock(mutex);
        auto loaded = profileId in sessionsByProfile;
        if (loaded is null) return;
        foreach (ref session; *loaded) {
            if (session.root == sessionRoot && !session.initialUserText.length) {
                session.initialUserText = clean;
                return;
            }
        }
    }

    void remove(string profileId, string sessionId, void delegate() persist)
    {
        auto guard = scopedMutexLock(mutex);
        auto loaded = profileId in sessionsByProfile;
        enforce(loaded !is null, "Recent sessions are not loaded");
        foreach (index, session; *loaded) {
            if (session.id == sessionId) {
                persist();
                *loaded = (*loaded)[0 .. index] ~ (*loaded)[index + 1 .. $];
                return;
            }
        }
        enforce(false, "Session not found");
    }

    private RecentSession[] loadLocked(string profileId)
    {
        if (auto loaded = profileId in sessionsByProfile) return *loaded;
        auto loaded = scan(profileId);
        sessionsByProfile[profileId] = loaded;
        return sessionsByProfile[profileId];
    }

    private RecentSession[] scan(string profileId)
    {
        RecentSession[] sessions;
        auto root = buildPath(locations.profileRoot(profileId), "sessions");
        if (!exists(root)) return sessions;

        auto paths = reader.sessionJsonPaths(root);
        sort(paths);
        foreach_reverse (path; paths) {
            auto sessionRoot = dirName(path);
            auto session = read(profileId, sessionRoot, path);
            if (session.initialUserText.length && resumable(session)) sessions ~= session;
        }
        sortSessions(sessions);
        return sessions;
    }

    private RecentSession read(string profileId, string sessionRoot, string sessionJsonPath)
    {
        auto payload = parseJSON(readText(sessionJsonPath));
        auto metadata = reader.loadSessionMetadata(sessionRoot);
        auto startedAt = jsonText(payload, "started_at");
        if (!startedAt.length) startedAt = sessionStartFromPath(sessionRoot);

        auto text = firstUserText(sessionRoot);
        auto language = metadata.language;
        if (!language.length) language = text.language;
        // Sessions created before language persistence were English.
        if (!language.length) language = "en";
        auto id = locations.sessionIdFromSessionRoot(profileId, sessionRoot);
        enforce(id.length, "Session root is outside the profile sessions tree");
        return RecentSession(
            id,
            sessionRoot,
            startedAt,
            language,
            text.prompt,
        );
    }

    private FirstUserText firstUserText(string sessionRoot)
    {
        auto turnsRoot = buildPath(sessionRoot, "turns");
        if (!exists(turnsRoot)) return FirstUserText.init;
        auto paths = reader.turnJsonPaths(turnsRoot);
        sort(paths);
        foreach (path; paths) {
            auto payload = parseJSON(readText(path));
            if (jsonText(payload, "source") == "memory_consolidation") continue;
            auto text = readTurnMarkdown(buildPath(dirName(path), "turn.md"));
            auto prompt = text.prompt.strip;
            if (!prompt.length)
                prompt = jsonText(objectField(payload, "user_image"), "filename");
            if (!prompt.length) continue;
            return FirstUserText(prompt, jsonText(payload, "language"));
        }
        return FirstUserText.init;
    }

    private bool resumable(RecentSession session)
    {
        return session.initialUserText.length && exists(piSessionJsonlPath(session.root));
    }
}

private struct FirstUserText
{
    string prompt;
    string language;
}

private void sortSessions(ref RecentSession[] sessions)
{
    sort!((a, b) => a.startedAt == b.startedAt ? a.id > b.id : a.startedAt > b.startedAt)(sessions);
}
