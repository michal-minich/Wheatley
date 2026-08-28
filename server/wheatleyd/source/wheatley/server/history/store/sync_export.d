module wheatley.server.history.store.sync_export;

import std.algorithm : canFind, sort;
import std.exception : assertThrown, enforce;
import std.file : SpanMode, dirEntries, exists, isFile, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json : parseJSON;
import std.path : baseName, buildPath, dirName;
import std.string : endsWith, startsWith, strip;
import std.uuid : randomUUID;

import wheatley.common.json.read : Json;
import wheatley.server.history.store.json : writeTextFile;
import wheatley.server.history.store.locations : HistoryStoreLocations;
import wheatley.server.history.store.markdown : readTurnMarkdown, turnMarkdown;
import wheatley.server.history.store.paths : sessionRootFromTurnRoot;
import wheatley.server.history.store.reader : HistoryStoreReader;
import wheatley.server.history.store.sync_paths :
    parseSyncSessionPath,
    parseSyncTurnPath;

struct SyncCompletedTurnExport
{
    string profileId;
    string sessionPath;
    string turnPath;
    string sessionJsonPath;
    string piSessionJsonlPath;
    string turnJsonPath;
    string turnMarkdownPath;
    string userOpusPath;
    string errorsJsonPath;
    string toolsJsonPath;
    string llmRequestsJsonPath;
    bool userAudioRequired;
}

struct SyncSnapshotFile
{
    string relativePath;
    string localPath;
}

struct SyncSessionSnapshot
{
    string profileId;
    string sessionPath;
    SyncSnapshotFile[] files;
}

string[] loadSyncProfileIds(HistoryStoreReader reader)
{
    return reader.listProfiles();
}

string[] loadSyncSessionPaths(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
)
{
    auto sessionsRoot = buildPath(locations.profileRoot(profileId), "sessions");
    string[] result;
    foreach (path; reader.sessionJsonPaths(sessionsRoot)) {
        auto sessionPath = locations.sessionIdFromSessionRoot(profileId, dirName(path));
        if (sessionPath.length) result ~= sessionPath;
    }
    sort(result);
    return result;
}

bool syncSessionIsFullyExportable(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
    string sessionPath,
)
{
    auto session = parseSyncSessionPath(sessionPath);
    auto sessionRoot = buildPath(
        locations.profileRoot(profileId),
        "sessions",
        session.year,
        session.month,
        session.day,
        session.folder,
    );
    auto turnsRoot = buildPath(sessionRoot, "turns");
    if (!exists(turnsRoot)) return true;
    foreach (path; reader.turnJsonPaths(turnsRoot)) {
        if (!exportReadyTurn(locations, dirName(path)).turnPath.length)
            return false;
    }
    return true;
}

SyncCompletedTurnExport[] loadExportReadyTurns(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
)
{
    SyncCompletedTurnExport[] output;
    auto sessionsRoot = buildPath(locations.profileRoot(profileId), "sessions");
    if (!exists(sessionsRoot)) return output;
    auto paths = reader.turnJsonPaths(sessionsRoot);
    sort(paths);
    foreach (path; paths) {
        auto exported = exportReadyTurn(locations, dirName(path));
        if (exported.turnPath.length) output ~= exported;
    }
    sort!((a, b) => a.sessionPath == b.sessionPath
        ? a.turnPath < b.turnPath
        : a.sessionPath < b.sessionPath)(output);
    return output;
}

SyncSessionSnapshot loadLatestSessionSnapshot(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
)
{
    auto sessionsRoot = buildPath(locations.profileRoot(profileId), "sessions");
    auto sessionJsonPaths = reader.sessionJsonPaths(sessionsRoot);
    sort(sessionJsonPaths);
    enforce(sessionJsonPaths.length, "Session snapshot not found");
    return snapshot(locations, reader, profileId, dirName(sessionJsonPaths[$ - 1]));
}

SyncSessionSnapshot loadSessionTurnSnapshot(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
    string sessionPath,
    string turnPath,
)
{
    auto session = parseSyncSessionPath(sessionPath);
    auto turn = parseSyncTurnPath(turnPath);
    auto sessionRoot = buildPath(
        locations.profileRoot(profileId),
        "sessions",
        session.year,
        session.month,
        session.day,
        session.folder,
    );
    auto exported = exportReadyTurn(
        locations,
        buildPath(sessionRoot, "turns", turn.folder),
    );
    enforce(exported.turnPath == turnPath, "Synchronized terminal turn is not available");

    SyncSnapshotFile[] files;
    addSnapshotFile(files, sessionRoot, "session.json");
    addPiSessionFiles(files, sessionRoot);
    addTurnSnapshotFiles(files, exported);
    return SyncSessionSnapshot(profileId, sessionPath, files);
}

SyncSnapshotFile resolveLatestSnapshotFile(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
    string relativePath,
)
{
    auto files = loadLatestSessionSnapshot(locations, reader, profileId).files;
    foreach (file; files) {
        if (file.relativePath == relativePath) return file;
    }
    throw new Exception("Session snapshot file not found");
}

SyncSnapshotFile resolveSessionTurnSnapshotFile(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
    string sessionPath,
    string turnPath,
    string relativePath,
)
{
    auto files = loadSessionTurnSnapshot(
        locations,
        reader,
        profileId,
        sessionPath,
        turnPath,
    ).files;
    foreach (file; files) {
        if (file.relativePath == relativePath) return file;
    }
    throw new Exception("Session turn snapshot file not found");
}

private SyncSessionSnapshot snapshot(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
    string sessionRoot,
)
{
    auto sessionPath = locations.sessionIdFromSessionRoot(profileId, sessionRoot);
    enforce(sessionPath.length, "Session snapshot is outside profile history");
    SyncSnapshotFile[] files;
    addSnapshotFile(files, sessionRoot, "session.json");
    addPiSessionFiles(files, sessionRoot);
    foreach (turn; exportReadyTurnsForSession(locations, reader, sessionRoot)) {
        addTurnSnapshotFiles(files, turn);
    }
    return SyncSessionSnapshot(profileId, sessionPath, files);
}

private SyncCompletedTurnExport[] exportReadyTurnsForSession(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string sessionRoot,
)
{
    SyncCompletedTurnExport[] output;
    auto turnsRoot = buildPath(sessionRoot, "turns");
    if (!exists(turnsRoot)) return output;
    auto paths = reader.turnJsonPaths(turnsRoot);
    sort(paths);
    foreach (path; paths) {
        auto exported = exportReadyTurn(locations, dirName(path));
        if (exported.turnPath.length) output ~= exported;
    }
    return output;
}

private SyncCompletedTurnExport exportReadyTurn(HistoryStoreLocations locations, string turnRoot)
{
    auto turnJsonPath = buildPath(turnRoot, "turn.json");
    auto turnMarkdownPath = buildPath(turnRoot, "turn.md");
    auto payload = parseJSON(readText(turnJsonPath));
    auto json = Json.object(payload);
    if (!("source" in payload.object) || !("status" in payload.object) ||
        !("completed_at" in payload.object) || !("user_audio_required" in payload.object))
        return SyncCompletedTurnExport();
    if (json.text("source") == "memory_consolidation") return SyncCompletedTurnExport();
    if (!json.text("status").length || !json.text("completed_at").length)
        return SyncCompletedTurnExport();
    if (!exists(turnMarkdownPath) || !readTurnMarkdown(turnMarkdownPath).prompt.strip.length)
        return SyncCompletedTurnExport();

    auto userAudioRequired = json.boolean("user_audio_required");
    auto userOpusPath = buildPath(turnRoot, "user.opus");
    if (userAudioRequired && !exists(userOpusPath)) return SyncCompletedTurnExport();

    auto sessionRoot = sessionRootFromTurnRoot(turnRoot);
    auto profileId = locations.profileIdFromTurnRoot(turnRoot);
    auto sessionPath = locations.sessionIdFromSessionRoot(profileId, sessionRoot);
    enforce(sessionPath.length, "Turn export is outside profile history");
    return SyncCompletedTurnExport(
        profileId,
        sessionPath,
        baseName(turnRoot),
        buildPath(sessionRoot, "session.json"),
        piSessionPath(sessionRoot),
        turnJsonPath,
        turnMarkdownPath,
        exists(userOpusPath) ? userOpusPath : "",
        optionalFile(turnRoot, "errors.json"),
        optionalFile(turnRoot, "tools.json"),
        optionalFile(turnRoot, "llm-requests.json"),
        userAudioRequired,
    );
}

private void addSnapshotFile(ref SyncSnapshotFile[] files, string sessionRoot, string relativePath)
{
    auto path = buildPath(sessionRoot, relativePath);
    enforce(exists(path) && isFile(path), "Session snapshot file is missing: " ~ relativePath);
    files ~= SyncSnapshotFile(relativePath, path);
}

private void addPiSessionFiles(ref SyncSnapshotFile[] files, string sessionRoot)
{
    string[] paths;
    foreach (entry; dirEntries(sessionRoot, SpanMode.shallow)) {
        if (entry.isFile && isPiSessionFile(baseName(entry.name))) paths ~= entry.name;
    }
    sort(paths);
    foreach (path; paths) files ~= SyncSnapshotFile(baseName(path), path);
}

private void addTurnSnapshotFiles(
    ref SyncSnapshotFile[] files,
    SyncCompletedTurnExport turn,
)
{
    auto prefix = "turns/" ~ turn.turnPath ~ "/";
    files ~= SyncSnapshotFile(prefix ~ "turn.json", turn.turnJsonPath);
    files ~= SyncSnapshotFile(prefix ~ "turn.md", turn.turnMarkdownPath);
    if (turn.userOpusPath.length) files ~= SyncSnapshotFile(prefix ~ "user.opus", turn.userOpusPath);
    if (turn.errorsJsonPath.length) files ~= SyncSnapshotFile(prefix ~ "errors.json", turn.errorsJsonPath);
    if (turn.toolsJsonPath.length) files ~= SyncSnapshotFile(prefix ~ "tools.json", turn.toolsJsonPath);
    if (turn.llmRequestsJsonPath.length)
        files ~= SyncSnapshotFile(prefix ~ "llm-requests.json", turn.llmRequestsJsonPath);
}

private string piSessionPath(string sessionRoot)
{
    auto path = buildPath(sessionRoot, "pi_session.jsonl");
    return exists(path) ? path : "";
}

private string optionalFile(string turnRoot, string name)
{
    auto path = buildPath(turnRoot, name);
    return exists(path) ? path : "";
}

private bool isPiSessionFile(string name)
{
    if (name == "pi_session.jsonl") return true;
    if (!name.startsWith("pi_session_") || !name.endsWith(".jsonl")) return false;
    auto number = name["pi_session_".length .. $ - ".jsonl".length];
    if (!number.length) return false;
    foreach (ch; number) if (ch < '0' || ch > '9') return false;
    auto value = 0L;
    foreach (ch; number) value = value * 10 + ch - '0';
    return value >= 2;
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-sync-export-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    auto profileRoot = buildPath(profilesRoot, "tester");
    mkdirRecurse(profileRoot);
    auto locations = new HistoryStoreLocations(profilesRoot, root);
    auto reader = new HistoryStoreReader(locations);

    auto oldSession = buildPath(profileRoot, "sessions", "2026", "08", "05", "10_00_00");
    writeTextFile(buildPath(oldSession, "session.json"), `{"client":"offline","language":"en","model":"","reasoning_mode":"off"}`);
    writeTextFile(buildPath(oldSession, "turns", "10_00_00_000001", "turn.json"), `{"source":"offline","completed_at":"2026-08-05T10:00:00.000001Z","reasoning_mode":"off"}`);
    writeTextFile(buildPath(oldSession, "turns", "10_00_00_000001", "turn.md"), turnMarkdown("old prompt", "old answer"));

    auto latestSession = buildPath(profileRoot, "sessions", "2026", "08", "05", "10_01_00");
    writeTextFile(buildPath(latestSession, "session.json"), `{"client":"offline","language":"en","model":"","reasoning_mode":"off"}`);
    writeTextFile(buildPath(latestSession, "pi_session.jsonl"), "primary\n");
    writeTextFile(buildPath(latestSession, "pi_session_2.jsonl"), "collision\n");
    writeTextFile(buildPath(latestSession, "pi_session_bad.jsonl"), "ignore\n");

    auto textTurn = buildPath(latestSession, "turns", "10_01_00_000001");
    writeTextFile(buildPath(textTurn, "turn.json"), `{"source":"offline","status":"completed","completed_at":"2026-08-05T10:01:00.000001Z","user_audio_required":false,"reasoning_mode":"off"}`);
    writeTextFile(buildPath(textTurn, "turn.md"), turnMarkdown("text prompt", "text answer"));
    writeTextFile(buildPath(textTurn, "errors.json"), `{}`);

    auto voiceTurn = buildPath(latestSession, "turns", "10_01_01_000001");
    writeTextFile(buildPath(voiceTurn, "turn.json"), `{"source":"offline","status":"completed","completed_at":"2026-08-05T10:01:01.000001Z","user_audio_required":true,"reasoning_mode":"off"}`);
    writeTextFile(buildPath(voiceTurn, "turn.md"), turnMarkdown("voice prompt", "voice answer"));
    write(buildPath(voiceTurn, "user.opus"), cast(ubyte[]) [1, 2, 3]);
    writeTextFile(buildPath(voiceTurn, "tools.json"), `{}`);

    auto pendingVoice = buildPath(latestSession, "turns", "10_01_02_000001");
    writeTextFile(buildPath(pendingVoice, "turn.json"), `{"source":"offline","status":"completed","completed_at":"2026-08-05T10:01:02.000001Z","user_audio_required":true,"reasoning_mode":"off"}`);
    writeTextFile(buildPath(pendingVoice, "turn.md"), turnMarkdown("pending prompt", "pending answer"));

    auto memoryTurn = buildPath(latestSession, "turns", "10_01_03_000001");
    writeTextFile(buildPath(memoryTurn, "turn.json"), `{"source":"memory_consolidation","status":"completed","completed_at":"2026-08-05T10:01:03.000001Z","user_audio_required":false,"reasoning_mode":"off"}`);
    writeTextFile(buildPath(memoryTurn, "turn.md"), turnMarkdown("memory prompt", "memory answer"));

    assert(loadSyncProfileIds(reader) == ["tester"]);
    auto turns = loadExportReadyTurns(locations, reader, "tester");
    assert(turns.length == 2);
    assert(turns[$ - 1].turnPath == "10_01_01_000001");
    assert(turns[$ - 1].userOpusPath == buildPath(voiceTurn, "user.opus"));

    auto snapshot = loadLatestSessionSnapshot(locations, reader, "tester");
    assert(snapshot.sessionPath == "2026/08/05/10_01_00");
    string[] paths;
    foreach (file; snapshot.files) paths ~= file.relativePath;
    assert(paths.canFind("session.json"));
    assert(paths.canFind("pi_session.jsonl"));
    assert(paths.canFind("pi_session_2.jsonl"));
    assert(!paths.canFind("pi_session_bad.jsonl"));
    assert(paths.canFind("turns/10_01_00_000001/errors.json"));
    assert(paths.canFind("turns/10_01_01_000001/user.opus"));
    assert(paths.canFind("turns/10_01_01_000001/tools.json"));
    assert(!paths.canFind("turns/10_01_02_000001/turn.json"));
    assert(!paths.canFind("turns/10_01_03_000001/turn.json"));

    auto userAudio = resolveLatestSnapshotFile(
        locations,
        reader,
        "tester",
        "turns/10_01_01_000001/user.opus",
    );
    assert(userAudio.localPath == buildPath(voiceTurn, "user.opus"));
    assertThrown!Exception(resolveLatestSnapshotFile(locations, reader, "tester", "../session.json"));
}
