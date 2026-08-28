module wheatley.server.history.store.session_branch;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.exception : enforce;
import std.file :
    SpanMode,
    copy,
    dirEntries,
    exists,
    isDir,
    isFile,
    mkdirRecurse,
    readText,
    remove,
    rmdirRecurse;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName, extension, stripExtension;
import std.string : replace, splitLines, strip;
import std.uri : encodeComponent;

import wheatley.common.json.object : jsonLongField, jsonObject, jsonRawField, jsonStringField;
import wheatley.server.history.store.json : jsonText, objectField, writeJsonFile, writeTextFile;
import wheatley.server.history.store.locations : HistoryStoreLocations;
import wheatley.server.history.store.markdown : turnMarkdown;
import wheatley.server.history.store.paths : piSessionJsonlPath, toolsJsonPath;
import wheatley.server.history.store.pi_session :
    PiPresentationItem,
    PiSessionBranch,
    branchPiSession,
    loadPiSessionTranscript;
import wheatley.server.history.store.reader : HistoryStoreReader;
import wheatley.server.history.store.tool_json : runtimeToolSchema, turnToolArray;
import wheatley.server.history.store.types : StoredTurn;
import wheatley.server.presentation.store : appendPresentation;

struct MaterializedSessionBranch
{
    string initialUserText;
    string completedAt;
}

package(wheatley.server.history) MaterializedSessionBranch materializeSessionBranch(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string profileId,
    string sourceSessionId,
    string targetSessionId,
    string sourceRoot,
    string targetRoot,
    StoredTurn selectedTurn,
    string kind,
    string itemId,
    string targetPiSessionId,
    string createdAt,
)
{
    auto pi = branchPiSession(
        piSessionJsonlPath(sourceRoot),
        selectedTurn,
        kind,
        itemId,
        targetPiSessionId,
        createdAt,
        buildPath(locations.profileRoot(profileId), "files"),
    );
    copySessionFile(sourceRoot, targetRoot, "context.md");
    copySessionFile(sourceRoot, targetRoot, "memory_auto.md");

    auto copied = copyTurns(
        locations,
        reader,
        sourceRoot,
        targetRoot,
        selectedTurn,
        pi,
    );
    auto rewrittenPi = rewritePiSession(
        pi.jsonl,
        sourceSessionId,
        targetSessionId,
        copied.turnIds,
    );
    writeTextFile(piSessionJsonlPath(targetRoot), rewrittenPi);
    rewriteTurnImageMetadata(
        targetRoot,
        profileId,
        sourceSessionId,
        targetSessionId,
        copied.turnIds,
    );

    if (!copyPresentationPrefix(
        sourceRoot,
        targetRoot,
        sourceSessionId,
        targetSessionId,
        selectedTurn.id,
        kind,
        itemId,
        copied.turnIds,
    )) rebuildPresentation(targetRoot, copied.turns, copied.turnIds);

    return MaterializedSessionBranch(copied.initialUserText, pi.completedAt);
}

private struct CopiedTurns
{
    StoredTurn[] turns;
    string[string] turnIds;
    string initialUserText;
}

private CopiedTurns copyTurns(
    HistoryStoreLocations locations,
    HistoryStoreReader reader,
    string sourceRoot,
    string targetRoot,
    StoredTurn selectedTurn,
    PiSessionBranch pi,
)
{
    auto paths = reader.turnJsonPaths(buildPath(sourceRoot, "turns"));
    sort(paths);
    CopiedTurns copied;
    bool selectedFound;
    foreach (path; paths) {
        auto sourceTurnRoot = dirName(path);
        auto turn = reader.loadTurn(sourceTurnRoot, true);
        if (turn.source == "memory_consolidation") continue;
        auto targetTurnRoot = buildPath(targetRoot, "turns", baseName(sourceTurnRoot));
        copyTree(sourceTurnRoot, targetTurnRoot);
        removeIfPresent(buildPath(targetTurnRoot, "conversation.events.jsonl"));
        removeIfPresent(buildPath(targetTurnRoot, ".presentation-user"));
        auto targetTurnId = locations.turnIdFromTurnRoot(targetTurnRoot);
        auto copiedTranscript = pi.transcript.turn(turn);
        markInheritedTurn(
            buildPath(targetTurnRoot, "turn.json"),
            false,
            "",
            targetTurnId,
            copiedTranscript.startedAt,
        );
        copied.turnIds[turn.id] = targetTurnId;
        copied.turns ~= turn;
        if (!copied.initialUserText.length && turn.userText.strip.length)
            copied.initialUserText = turn.userText.strip;

        if (sourceTurnRoot != selectedTurn.turnRoot) continue;
        selectedFound = true;
        pruneSelectedTurn(targetTurnRoot, turn, pi);
        break;
    }
    enforce(selectedFound, "Chat branch turn is outside the source session");
    return copied;
}

private void pruneSelectedTurn(string targetTurnRoot, StoredTurn turn, PiSessionBranch branch)
{
    auto transcript = branch.transcript.turn(turn);
    auto response = appender!string;
    long retainedToolCount;
    bool[string] retainedImages;
    if (turn.hasUserImage) retainImage(retainedImages, turn.userImageFilename);
    foreach (item; transcript.items) {
        if (item.kind == "assistant") {
            if (response.data.length) response.put("\n\n");
            response.put(item.text);
        }
        if (item.kind == "tool" && item.hasResult) retainedToolCount++;
        collectImageFilenames(item.details, retainedImages);
        collectImageFilenames(item.extensionData, retainedImages);
    }
    writeTextFile(
        buildPath(targetTurnRoot, "turn.md"),
        turnMarkdown(turn.userText, response.data),
    );
    markInheritedTurn(
        buildPath(targetTurnRoot, "turn.json"),
        true,
        branch.completedAt,
        "",
        "",
    );
    writeSelectedMetrics(
        buildPath(targetTurnRoot, "turn.json"),
        transcript.startedAt,
        branch.completedAt,
        transcript.items,
    );
    pruneTools(targetTurnRoot, retainedToolCount);
    pruneImages(targetTurnRoot, retainedImages);
    auto llmRoot = buildPath(targetTurnRoot, "llm");
    if (exists(llmRoot)) rmdirRecurse(llmRoot);
    removeIfPresent(buildPath(targetTurnRoot, "errors.json"));
}

private void markInheritedTurn(
    string path,
    bool selected,
    string completedAt,
    string turnId,
    string startedAt,
)
{
    auto value = parseJSON(readText(path));
    value.object.remove("submission_id");
    value.object.remove("execution_id");
    value.object.remove("submission");
    value.object["branch_inherited"] = JSONValue(true);
    if (turnId.length) value.object["id"] = JSONValue(turnId);
    if (startedAt.length) value.object["started_at"] = JSONValue(startedAt);
    if (selected) {
        value.object["status"] = JSONValue("completed");
        value.object["completed_at"] = JSONValue(completedAt);
        value.object["metrics"] = parseJSON("{}");
    }
    writeJsonFile(path, value.toString());
}

private void writeSelectedMetrics(
    string path,
    string startedAt,
    string completedAt,
    PiPresentationItem[] items,
)
{
    auto value = parseJSON(readText(path));
    auto sourceMetrics = objectField(value, "metrics");
    JSONValue[] reasoningItems;
    foreach (item; items) {
        if (item.kind != "reasoning") continue;
        reasoningItems ~= parseJSON(jsonObject([
            jsonStringField("item_id", item.id),
            jsonLongField("duration_ms", item.durationMs >= 0 ? item.durationMs : 0),
        ]));
    }
    string[] fields;
    if (sourceMetrics.type == JSONType.object) {
        foreach (name; ["audio", "stt"]) {
            auto source = name in sourceMetrics.objectNoRef;
            if (source !is null) fields ~= jsonRawField(name, source.toString());
        }
    }
    if (reasoningItems.length) fields ~= jsonRawField("reasoning", jsonObject([
        jsonRawField("items", JSONValue(reasoningItems).toString()),
    ]));
    fields ~= jsonRawField("turn", jsonObject([
        jsonLongField("activity_ms", branchDurationMs(startedAt, completedAt)),
    ]));
    value.object["metrics"] = parseJSON(jsonObject(fields));
    writeJsonFile(path, value.toString());
}

private long branchDurationMs(string startedAt, string completedAt)
{
    if (!startedAt.length || !completedAt.length) return 0;
    auto duration = SysTime.fromISOExtString(completedAt)
        - SysTime.fromISOExtString(startedAt);
    return duration.total!"msecs" > 0 ? duration.total!"msecs" : 0;
}

private void pruneTools(string turnRoot, long retainedCount)
{
    auto path = toolsJsonPath(turnRoot);
    if (!exists(path)) return;
    if (retainedCount == 0) {
        remove(path);
        return;
    }
    auto value = parseJSON(readText(path));
    auto tools = turnToolArray(value).array;
    enforce(retainedCount <= tools.length, "Chat branch tool history is incomplete");
    JSONValue[] retained;
    foreach (tool; tools[0 .. cast(size_t) retainedCount]) retained ~= tool;
    writeJsonFile(path, jsonObject([
        jsonStringField("schema", runtimeToolSchema),
        jsonRawField("tools", JSONValue(retained).toString()),
    ]));
}

private void collectImageFilenames(JSONValue value, ref bool[string] filenames)
{
    if (value.type == JSONType.object) {
        foreach (name, child; value.objectNoRef) {
            if (name == "filename" && child.type == JSONType.string)
                retainImage(filenames, child.str);
            collectImageFilenames(child, filenames);
        }
    } else if (value.type == JSONType.array) {
        foreach (child; value.array) collectImageFilenames(child, filenames);
    }
}

private void retainImage(ref bool[string] filenames, string filename)
{
    if (!filename.length) return;
    filenames[filename] = true;
    filenames[stripExtension(filename) ~ ".json"] = true;
}

private void pruneImages(string turnRoot, bool[string] retained)
{
    auto root = buildPath(turnRoot, "images");
    if (!exists(root)) return;
    foreach (entry; dirEntries(root, SpanMode.shallow)) {
        if (entry.isFile && baseName(entry.name) !in retained) remove(entry.name);
    }
}

private string rewritePiSession(
    string jsonl,
    string sourceSessionId,
    string targetSessionId,
    string[string] turnIds,
)
{
    auto output = appender!string;
    foreach (line; jsonl.splitLines()) {
        if (!line.strip.length) continue;
        auto value = parseJSON(line);
        rewriteReferences(value, sourceSessionId, targetSessionId, turnIds);
        output.put(value.toString());
        output.put("\n");
    }
    return output.data;
}

private bool copyPresentationPrefix(
    string sourceRoot,
    string targetRoot,
    string sourceSessionId,
    string targetSessionId,
    string turnId,
    string kind,
    string itemId,
    string[string] turnIds,
)
{
    auto source = buildPath(sourceRoot, "presentation.jsonl");
    if (!exists(source)) return false;
    string[] lines;
    long sequence;
    bool found;
    foreach (line; readText(source).splitLines()) {
        if (!line.strip.length) continue;
        auto value = parseJSON(line);
        lines ~= value.toString();
        if (!presentationEndsAt(value, turnId, kind, itemId)) continue;
        sequence = value["sequence"].integer;
        found = true;
        break;
    }
    if (!found) return false;

    auto output = appender!string;
    foreach (line; lines) {
        auto value = parseJSON(line);
        rewriteReferences(value, sourceSessionId, targetSessionId, turnIds);
        output.put(value.toString());
        output.put("\n");
    }
    writeTextFile(buildPath(targetRoot, "presentation.jsonl"), output.data);
    writeTextFile(buildPath(targetRoot, "presentation.sequence"), sequence.to!string ~ "\n");
    return true;
}

private bool presentationEndsAt(JSONValue entry, string turnId, string kind, string itemId)
{
    if (jsonText(entry, "source") != "pi" || jsonText(entry, "turn_id") != turnId)
        return false;
    auto entryKind = jsonText(entry, "kind");
    auto payload = objectField(entry, "payload");
    if (kind == "user") return entryKind == "user";
    if (kind == "reasoning") return entryKind == "reasoning"
        && jsonText(entry, "item_id") == itemId
        && jsonText(payload, "phase") == "end";
    if (kind == "artifact") return entryKind == "artifact"
        && jsonText(entry, "item_id") == itemId;
    if (entryKind != "status" || jsonText(payload, "code") != "assistant_item_finished")
        return false;
    return jsonText(objectField(payload, "details"), "item_id") == itemId;
}

private void rebuildPresentation(
    string targetRoot,
    StoredTurn[] sourceTurns,
    string[string] turnIds,
)
{
    auto pi = loadPiSessionTranscript(piSessionJsonlPath(targetRoot));
    foreach (turn; sourceTurns) {
        auto newTurnId = turnIds[turn.id];
        appendPresentation(targetRoot, "pi", "user", newTurnId, "", "{}");
        foreach (item; pi.turn(turn).items) {
            auto kind = item.kind == "assistant" ? "assistant_delta" : item.kind;
            appendPresentation(targetRoot, "pi", kind, newTurnId, item.id, "{}");
            auto artifactKind = jsonText(item.details, "kind");
            if (artifactKind == "generated_image" || artifactKind == "screen_capture")
                appendPresentation(targetRoot, "pi", "artifact", newTurnId, item.id, "{}");
        }
    }
}

private void rewriteTurnImageMetadata(
    string targetRoot,
    string profileId,
    string sourceSessionId,
    string targetSessionId,
    string[string] turnIds,
)
{
    auto turnsRoot = buildPath(targetRoot, "turns");
    if (!exists(turnsRoot)) return;
    foreach (entry; dirEntries(turnsRoot, SpanMode.depth)) {
        if (!entry.isFile || extension(entry.name) != ".json") continue;
        auto value = parseJSON(readText(entry.name));
        rewriteReferences(value, sourceSessionId, targetSessionId, turnIds);
        writeJsonFile(entry.name, value.toString());
    }
}

private void rewriteReferences(
    ref JSONValue value,
    string sourceSessionId,
    string targetSessionId,
    string[string] turnIds,
)
{
    if (value.type == JSONType.array) {
        foreach (ref child; value.array) rewriteReferences(
            child,
            sourceSessionId,
            targetSessionId,
            turnIds,
        );
        return;
    }
    if (value.type != JSONType.object) return;
    foreach (name, ref child; value.object) {
        if (child.type == JSONType.string) {
            if (name == "session_id" && child.str == sourceSessionId)
                child = JSONValue(targetSessionId);
            else if (name == "turn_id" && child.str in turnIds)
                child = JSONValue(turnIds[child.str]);
            else if (name == "url" || name == "path" || name == "image_url")
                child = JSONValue(rewriteReferenceText(
                    child.str,
                    sourceSessionId,
                    targetSessionId,
                    turnIds,
                ));
        } else rewriteReferences(child, sourceSessionId, targetSessionId, turnIds);
    }
}

private string rewriteReferenceText(
    string text,
    string sourceSessionId,
    string targetSessionId,
    string[string] turnIds,
)
{
    auto rewritten = text;
    foreach (sourceTurnId, targetTurnId; turnIds) {
        rewritten = rewritten
            .replace(encodeComponent(sourceTurnId), encodeComponent(targetTurnId))
            .replace(sourceTurnId, targetTurnId);
    }
    return rewritten
        .replace(encodeComponent(sourceSessionId), encodeComponent(targetSessionId))
        .replace(sourceSessionId, targetSessionId);
}

private void copySessionFile(string sourceRoot, string targetRoot, string name)
{
    auto source = buildPath(sourceRoot, name);
    if (exists(source)) copy(source, buildPath(targetRoot, name));
}

private void copyTree(string source, string target)
{
    enforce(exists(source) && isDir(source), "Chat branch source directory is missing");
    mkdirRecurse(target);
    foreach (entry; dirEntries(source, SpanMode.shallow)) {
        auto destination = buildPath(target, baseName(entry.name));
        if (entry.isDir) copyTree(entry.name, destination);
        else if (entry.isFile) copy(entry.name, destination);
    }
}

private void removeIfPresent(string path)
{
    if (exists(path) && isFile(path)) remove(path);
}
