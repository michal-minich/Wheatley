module wheatley.server.history.store.sync;

import std.conv : to;
import std.exception : enforce;
import std.file : copy, exists, isDir, isFile, mkdirRecurse, read, readText, remove, rename, rmdirRecurse;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.string : strip;
import std.uuid : randomUUID;

import wheatley.common.json.read : Json;
import wheatley.common.api.remote_turn_sync : RemoteTurnSessionHandoff;
import wheatley.server.history.store.locations : HistoryStoreLocations;
import wheatley.server.history.store.markdown : readTurnMarkdown;
import wheatley.server.history.store.paths : piSessionJsonlPath;
import wheatley.server.history.store.json : writeTextFile;
import wheatley.server.history.store.sync_paths :
    SyncSessionPath,
    SyncTurnPath,
    parseSyncSessionPath,
    parseSyncTurnPath;

struct CompletedTurnImport
{
    string profileId;
    string sessionPath;
    string turnPath;
    string sessionJsonPath;
    string turnJsonPath;
    string turnMarkdownPath;
    string piSessionJsonlPath;
    string userOpusPath;
    string errorsJsonPath;
    string toolsJsonPath;
    string llmRequestsJsonPath;
    bool userAudioRequired;
}

struct ImportedCompletedTurn
{
    bool imported;
    string sessionId;
    string turnId;
    string startedAt;
    string language;
    string userText;
}

bool commitSyncedSession(
    HistoryStoreLocations locations,
    string profileId,
    RemoteTurnSessionHandoff handoff,
)
{
    auto session = parseSyncSessionPath(handoff.sessionPath);
    Json.object(parseJSON(handoff.sessionJson));
    auto sessionRoot = buildPath(
        locations.profileRoot(profileId),
        "sessions",
        session.year,
        session.month,
        session.day,
        session.folder,
    );
    auto sessionJsonPath = buildPath(sessionRoot, "session.json");
    if (exists(sessionRoot)) {
        enforce(exists(sessionJsonPath) && isFile(sessionJsonPath),
            "Synchronized session root has no session.json");
        return false;
    }

    auto stageRoot = stagingRoot(locations.profileRoot(profileId));
    scope(failure) removeTree(stageRoot);
    writeTextFile(buildPath(stageRoot, "session.json"), handoff.sessionJson);
    mkdirRecurse(buildPath(stageRoot, "turns"));
    mkdirRecurse(dirName(sessionRoot));
    rename(stageRoot, sessionRoot);
    return true;
}

ImportedCompletedTurn commitCompletedTurn(
    HistoryStoreLocations locations,
    CompletedTurnImport input,
)
{
    auto session = parseSyncSessionPath(input.sessionPath);
    auto turn = parseSyncTurnPath(input.turnPath);
    auto sessionRoot = buildPath(
        locations.profileRoot(input.profileId),
        "sessions",
        session.year,
        session.month,
        session.day,
        session.folder,
    );
    auto turnRoot = buildPath(sessionRoot, "turns", turn.folder);
    auto sessionId = session.value;
    auto turnId = sessionId ~ "/turns/" ~ turn.value;

    validateInput(input);
    auto imported = importedTurn(input, sessionId, turnId, session);
    if (exists(turnRoot)) {
        imported.imported = false;
        return imported;
    }
    if (!exists(sessionRoot)) {
        publishNewSession(locations.profileRoot(input.profileId), sessionRoot, turn, input);
        return imported;
    }

    enforce(exists(buildPath(sessionRoot, "session.json")), "Imported session root has no session.json");
    publishTurnIntoExistingSession(
        locations.profileRoot(input.profileId),
        sessionRoot,
        turn,
        input,
    );
    return imported;
}

bool syncTurnExists(
    HistoryStoreLocations locations,
    string profileId,
    string sessionPath,
    string turnPath,
)
{
    auto session = parseSyncSessionPath(sessionPath);
    auto turn = parseSyncTurnPath(turnPath);
    auto root = buildPath(
        locations.profileRoot(profileId),
        "sessions",
        session.year,
        session.month,
        session.day,
        session.folder,
        "turns",
        turn.folder,
    );
    return exists(root) && isDir(root);
}

private void validateInput(CompletedTurnImport input)
{
    requireJsonFile(input.sessionJsonPath, "Imported session.json");
    requireFile(input.turnJsonPath, "Imported turn.json");
    auto turn = Json.object(parseJSON(readText(input.turnJsonPath)));
    enforce(isTerminalStatus(turn.text("status")), "Imported turn status is not terminal");
    enforce(turn.text("completed_at").length, "Imported turn is not complete");
    enforce(
        turn.text("source") != "memory_consolidation",
        "Imported memory-consolidation turns are not supported",
    );
    enforce(
        input.userAudioRequired == turn.boolean("user_audio_required"),
        "Imported user audio requirement does not match turn.json",
    );
    requireFile(input.turnMarkdownPath, "Imported turn.md");
    auto markdown = readTurnMarkdown(input.turnMarkdownPath);
    enforce(markdown.prompt.strip.length, "Imported turn prompt is required");
    if (input.userAudioRequired) requireFile(input.userOpusPath, "Imported user.opus");
    if (input.piSessionJsonlPath.length) requireFile(input.piSessionJsonlPath, "Imported Pi session JSONL");
    if (input.errorsJsonPath.length) requireJsonFile(input.errorsJsonPath, "Imported errors.json");
    if (input.toolsJsonPath.length) requireJsonFile(input.toolsJsonPath, "Imported tools.json");
    if (input.llmRequestsJsonPath.length)
        requireJsonFile(input.llmRequestsJsonPath, "Imported llm-requests.json");
}

private ImportedCompletedTurn importedTurn(
    CompletedTurnImport input,
    string sessionId,
    string turnId,
    SyncSessionPath session,
)
{
    auto metadata = Json.parse(readText(input.sessionJsonPath));
    auto markdown = readTurnMarkdown(input.turnMarkdownPath);
    return ImportedCompletedTurn(
        true,
        sessionId,
        turnId,
        session.year ~ "-" ~ session.month ~ "-" ~ session.day ~ "T" ~
            input.turnPath[0 .. 2] ~ ":" ~ input.turnPath[3 .. 5] ~ ":" ~
            input.turnPath[6 .. 8] ~ "." ~ input.turnPath[9 .. 15] ~ "Z",
        metadata.text("language"),
        markdown.prompt.strip,
    );
}

private void publishNewSession(
    string profileRoot,
    string sessionRoot,
    SyncTurnPath turn,
    CompletedTurnImport input,
)
{
    auto stageRoot = stagingRoot(profileRoot);
    scope (failure) removeTree(stageRoot);
    copyFile(input.sessionJsonPath, buildPath(stageRoot, "session.json"));
    copyTurn(input, buildPath(stageRoot, "turns", turn.folder));
    if (input.piSessionJsonlPath.length) copyFile(input.piSessionJsonlPath, piSessionJsonlPath(stageRoot));
    mkdirRecurse(dirName(sessionRoot));
    rename(stageRoot, sessionRoot);
}

private void publishTurnIntoExistingSession(
    string profileRoot,
    string sessionRoot,
    SyncTurnPath turn,
    CompletedTurnImport input,
)
{
    auto stageRoot = stagingRoot(profileRoot);
    scope (failure) removeTree(stageRoot);
    auto stageTurn = buildPath(stageRoot, turn.folder);
    copyTurn(input, stageTurn);
    preservePiSession(sessionRoot, input.piSessionJsonlPath);
    rename(stageTurn, buildPath(sessionRoot, "turns", turn.folder));
    removeTree(stageRoot);
}

private void copyTurn(CompletedTurnImport input, string targetRoot)
{
    copyFile(input.turnJsonPath, buildPath(targetRoot, "turn.json"));
    copyFile(input.turnMarkdownPath, buildPath(targetRoot, "turn.md"));
    if (input.userAudioRequired) copyFile(input.userOpusPath, buildPath(targetRoot, "user.opus"));
    if (input.errorsJsonPath.length) copyFile(input.errorsJsonPath, buildPath(targetRoot, "errors.json"));
    if (input.toolsJsonPath.length) copyFile(input.toolsJsonPath, buildPath(targetRoot, "tools.json"));
    if (input.llmRequestsJsonPath.length)
        copyFile(input.llmRequestsJsonPath, buildPath(targetRoot, "llm-requests.json"));
}

private void preservePiSession(string sessionRoot, string incomingPath)
{
    if (!incomingPath.length) return;
    auto primary = piSessionJsonlPath(sessionRoot);
    if (!exists(primary)) {
        copyFileAtomic(incomingPath, primary);
        return;
    }
    if (sameFile(primary, incomingPath)) return;

    foreach (index; 2 .. 10_000) {
        auto target = buildPath(sessionRoot, "pi_session_" ~ index.to!string ~ ".jsonl");
        if (exists(target)) {
            if (sameFile(target, incomingPath)) return;
            continue;
        }
        copyFileAtomic(incomingPath, target);
        return;
    }
    throw new Exception("Could not preserve imported Pi session JSONL");
}

private string stagingRoot(string profileRoot)
{
    return buildPath(profileRoot, ".sync-staging", randomUUID().toString());
}

private bool isTerminalStatus(string status)
{
    return status == "completed" || status == "failed" || status == "stopped";
}

private void requireFile(string path, string label)
{
    enforce(path.length && exists(path) && isFile(path), label ~ " is required");
}

private void requireJsonFile(string path, string label)
{
    requireFile(path, label);
    Json.object(parseJSON(readText(path)));
}

private void copyFile(string source, string target)
{
    mkdirRecurse(dirName(target));
    copy(source, target);
}

private void copyFileAtomic(string source, string target)
{
    mkdirRecurse(dirName(target));
    auto staged = target ~ ".sync-" ~ randomUUID().toString();
    scope(failure) if (exists(staged)) remove(staged);
    copy(source, staged);
    rename(staged, target);
}

private bool sameFile(string first, string second)
{
    return read(first) == read(second);
}

private void removeTree(string path) nothrow
{
    if (!exists(path)) return;
    try {
        rmdirRecurse(path);
    } catch (Exception) {
    }
}
