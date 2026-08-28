module wheatley.server.codex.store;

import std.algorithm : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName;
import std.stdio : File;
import std.string : endsWith, splitLines, strip;

import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.api.session : SessionKey;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.safe_token : safeToken;
import wheatley.server.codex.types :
    CodexDispatchRecord,
    CodexLiveEvent,
    CodexSessionRecord,
    CodexTurnRecord;
import wheatley.server.history.store.json : writeJsonFile, writeTextFile;
import wheatley.server.presentation.store : appendPresentation, withSessionStorageLock;

/** Session-local durable owner for Wheatley's Codex association and projection. */
final class CodexSessionStore
{
    private TaskMutex mutex;

    this()
    {
        mutex = new TaskMutex;
    }

    CodexSessionRecord load(SessionKey session, string sessionRoot)
    {
        auto guard = scopedMutexLock(mutex);
        return loadUnlocked(session, sessionRoot);
    }

    CodexSessionRecord associate(
        SessionKey session,
        string sessionRoot,
        string threadId,
        string codexSessionId,
    )
    {
        auto guard = scopedMutexLock(mutex);
        auto record = loadUnlocked(session, sessionRoot);
        enforce(!record.threadId.length, "Wheatley session already has a Codex thread");
        auto timestamp = nowIso();
        record.threadId = threadId;
        record.codexSessionId = codexSessionId;
        record.createdAt = timestamp;
        record.updatedAt = timestamp;
        record.status = "idle";
        saveSessionUnlocked(record);
        return record;
    }

    CodexTurnRecord beginTurn(
        SessionKey session,
        string sessionRoot,
        string turnId,
        string message,
    )
    {
        auto guard = scopedMutexLock(mutex);
        auto record = loadUnlocked(session, sessionRoot);
        enforce(record.threadId.length, "Codex thread is not associated");
        enforce(turnId.length, "Codex turn ID is required");
        auto timestamp = nowIso();
        auto ordinal = record.lastTurnOrdinal + 1;
        auto root = buildPath(
            codexRoot(sessionRoot),
            "turns",
            ordinalText(ordinal) ~ "-" ~ safeToken(turnId, "turn"),
        );
        auto turn = CodexTurnRecord(
            ordinal,
            record.threadId,
            turnId,
            "running",
            timestamp,
            timestamp,
            "",
            message.strip,
            "",
            "",
            "",
            root,
        );
        record.lastTurnId = turnId;
        record.lastTurnOrdinal = ordinal;
        record.status = "running";
        record.updatedAt = timestamp;
        record.latestReasoning = "";
        record.finalText = "";
        record.errorMessage = "";
        saveTurnUnlocked(turn);
        saveSessionUnlocked(record);
        return turn;
    }

    CodexTurnRecord latestTurn(SessionKey session, string sessionRoot)
    {
        auto guard = scopedMutexLock(mutex);
        auto record = loadUnlocked(session, sessionRoot);
        return record.lastTurnId.length
            ? loadTurnUnlocked(sessionRoot, record.lastTurnId)
            : CodexTurnRecord.init;
    }

    void appendReasoning(
        SessionKey session,
        string sessionRoot,
        string turnId,
        string itemId,
        long summaryIndex,
        string delta,
        bool recovered = false,
    )
    {
        if (!delta.length) return;
        auto guard = scopedMutexLock(mutex);
        auto record = loadUnlocked(session, sessionRoot);
        auto turn = loadTurnUnlocked(sessionRoot, turnId);
        turn.latestReasoning ~= delta;
        turn.updatedAt = nowIso();
        record.latestReasoning = turn.latestReasoning;
        record.updatedAt = turn.updatedAt;
        auto event = eventUnlocked(
            record,
            turnId,
            itemId,
            summaryIndex,
            "reasoning_summary",
            "delta",
            delta,
            "",
            "running",
            recovered,
        );
        appendEventUnlocked(sessionRoot, event);
        saveTurnUnlocked(turn);
        saveSessionUnlocked(record);
    }

    void beginReasoning(
        SessionKey session,
        string sessionRoot,
        string turnId,
        string itemId,
        long summaryIndex,
        bool recovered = false,
    )
    {
        auto guard = scopedMutexLock(mutex);
        auto record = loadUnlocked(session, sessionRoot);
        auto turn = loadTurnUnlocked(sessionRoot, turnId);
        if (turn.latestReasoning.length && !turn.latestReasoning.endsWith("\n\n"))
            turn.latestReasoning ~= "\n\n";
        turn.updatedAt = nowIso();
        record.latestReasoning = turn.latestReasoning;
        record.updatedAt = turn.updatedAt;
        auto event = eventUnlocked(
            record,
            turnId,
            itemId,
            summaryIndex,
            "reasoning_summary",
            "start",
            "",
            "",
            "running",
            recovered,
        );
        appendEventUnlocked(sessionRoot, event);
        saveTurnUnlocked(turn);
        saveSessionUnlocked(record);
    }

    void appendItem(
        SessionKey session,
        string sessionRoot,
        string turnId,
        string itemId,
        long summaryIndex,
        string kind,
        string operation,
        string text,
        string name,
        string status,
        bool recovered = false,
    )
    {
        auto guard = scopedMutexLock(mutex);
        auto record = loadUnlocked(session, sessionRoot);
        record.updatedAt = nowIso();
        auto event = eventUnlocked(
            record,
            turnId,
            itemId,
            summaryIndex,
            kind,
            operation,
            text,
            name,
            status,
            recovered,
        );
        appendEventUnlocked(sessionRoot, event);
        saveSessionUnlocked(record);
    }

    void completeTurn(
        SessionKey session,
        string sessionRoot,
        string turnId,
        string status,
        string finalText,
        string errorMessage,
        bool recovered = false,
    )
    {
        auto guard = scopedMutexLock(mutex);
        auto record = loadUnlocked(session, sessionRoot);
        auto turn = loadTurnUnlocked(sessionRoot, turnId);
        auto cleanFinal = status == "completed" ? finalText.strip : "";
        auto cleanError = errorMessage.strip;
        if (turn.status == status
            && turn.finalText == cleanFinal
            && turn.errorMessage == cleanError)
            return;
        auto previousFinal = turn.finalText;
        auto previousError = turn.errorMessage;
        auto previousStatus = turn.status;
        auto timestamp = nowIso();
        turn.status = status;
        turn.updatedAt = timestamp;
        turn.completedAt = timestamp;
        turn.finalText = cleanFinal;
        turn.errorMessage = cleanError;
        record.status = status;
        record.updatedAt = timestamp;
        record.finalText = turn.finalText;
        record.errorMessage = turn.errorMessage;
        if (turn.finalText.length
            && (turn.finalText != previousFinal || status != previousStatus)) {
            writeTextFile(buildPath(turn.turnRoot, "final.md"), turn.finalText ~ "\n");
            auto event = eventUnlocked(
                record,
                turnId,
                "final:" ~ turnId,
                -1,
                "final",
                "finish",
                turn.finalText,
                "",
                status,
                recovered,
            );
            appendEventUnlocked(sessionRoot, event);
        } else if (turn.errorMessage.length
            && (turn.errorMessage != previousError || status != previousStatus)) {
            auto event = eventUnlocked(
                record,
                turnId,
                "error:" ~ turnId,
                -1,
                "error",
                "finish",
                turn.errorMessage,
                "",
                status,
                recovered,
            );
            appendEventUnlocked(sessionRoot, event);
        }
        saveTurnUnlocked(turn);
        saveSessionUnlocked(record);
    }

    void setSystemError(SessionKey session, string sessionRoot, string message)
    {
        auto guard = scopedMutexLock(mutex);
        auto record = loadUnlocked(session, sessionRoot);
        auto clean = message.strip;
        if (record.status == "system_error" && record.errorMessage == clean) return;
        record.status = "system_error";
        record.errorMessage = clean;
        record.updatedAt = nowIso();
        auto event = eventUnlocked(
            record,
            record.lastTurnId,
            "system_error:" ~ record.threadId,
            -1,
            "error",
            "finish",
            clean,
            "",
            "system_error",
            false,
        );
        appendEventUnlocked(sessionRoot, event);
        saveSessionUnlocked(record);
    }

    void appendDispatch(string sessionRoot, CodexDispatchRecord dispatch)
    {
        auto guard = scopedMutexLock(mutex);
        auto path = buildPath(codexRoot(sessionRoot), "dispatches.jsonl");
        appendLine(path, dispatchJson(dispatch));
    }

    CodexLiveEvent[] eventsAfter(
        SessionKey session,
        string sessionRoot,
        long afterSequence,
        long limit = 200,
    )
    {
        auto guard = scopedMutexLock(mutex);
        CodexLiveEvent[] result;
        auto path = buildPath(codexRoot(sessionRoot), "events.jsonl");
        if (!exists(path)) return result;
        auto text = readText(path);
        auto lines = text.splitLines;
        foreach (index, line; lines) {
            auto clean = line.strip;
            if (!clean.length) continue;
            CodexLiveEvent event;
            try event = liveEventFromJson(parseJSON(clean));
            catch (Exception error) {
                if (index + 1 == lines.length && !text.endsWith("\n")) continue;
                throw error;
            }
            enforce(event.profileId == session.profileId, "Codex event profile changed");
            enforce(event.sessionId == session.sessionId, "Codex event session changed");
            if (event.sequence <= afterSequence) continue;
            result ~= event;
            if (result.length >= limit) break;
        }
        return result;
    }

    private CodexSessionRecord loadUnlocked(SessionKey session, string sessionRoot)
    {
        enforce(exists(buildPath(sessionRoot, "session.json")), "Wheatley session not found");
        auto path = buildPath(codexRoot(sessionRoot), "thread.json");
        if (!exists(path)) {
            return CodexSessionRecord(
                session.profileId,
                session.sessionId,
                sessionRoot,
                "",
                "",
                "",
                nowIso(),
                "",
                0,
                "not_started",
                "",
                "",
                "",
                0,
            );
        }
        auto json = Json.parse(readText(path));
        auto record = CodexSessionRecord(
            json.text("profile_id"),
            json.text("session_id"),
            sessionRoot,
            json.text("thread_id"),
            json.text("codex_session_id"),
            json.text("created_at"),
            json.text("updated_at"),
            json.text("last_turn_id"),
            json.nonNegativeInt("last_turn_ordinal"),
            json.text("status"),
            json.text("latest_reasoning"),
            json.text("final_text"),
            json.text("error_message"),
            json.nonNegativeInt("event_sequence"),
        );
        enforce(record.profileId == session.profileId, "Codex association profile changed");
        enforce(record.sessionId == session.sessionId, "Codex association session changed");
        return record;
    }

    private CodexTurnRecord loadTurnUnlocked(string sessionRoot, string turnId)
    {
        auto turnsRoot = buildPath(codexRoot(sessionRoot), "turns");
        enforce(exists(turnsRoot) && isDir(turnsRoot), "Codex turn not found: " ~ turnId);
        foreach (entry; dirEntries(turnsRoot, SpanMode.shallow)) {
            if (!entry.isDir) continue;
            auto path = buildPath(entry.name, "turn.json");
            if (!exists(path)) continue;
            auto json = Json.parse(readText(path));
            if (json.text("turn_id") != turnId) continue;
            return CodexTurnRecord(
                json.positiveInt("ordinal"),
                json.text("thread_id"),
                turnId,
                json.text("status"),
                json.text("started_at"),
                json.text("updated_at"),
                json.text("completed_at"),
                json.text("initial_message"),
                json.text("latest_reasoning"),
                json.text("final_text"),
                json.text("error_message"),
                entry.name,
            );
        }
        enforce(false, "Codex turn not found: " ~ turnId);
        return CodexTurnRecord.init;
    }

    private CodexLiveEvent eventUnlocked(
        ref CodexSessionRecord record,
        string turnId,
        string itemId,
        long summaryIndex,
        string kind,
        string operation,
        string text,
        string name,
        string status,
        bool recovered,
    )
    {
        auto event = CodexLiveEvent(
            0,
            record.profileId,
            record.sessionId,
            record.threadId,
            turnId,
            itemId,
            summaryIndex,
            kind,
            operation,
            text,
            name,
            status,
            nowIso(),
            recovered,
        );
        event.sequence = appendPresentation(
            record.sessionRoot,
            "codex",
            kind,
            turnId,
            itemId ~ (summaryIndex >= 0 ? ":" ~ summaryIndex.to!string : ""),
            (long sequence) {
                event.sequence = sequence;
                return liveEventJson(event);
            },
        );
        record.eventSequence = event.sequence;
        return event;
    }

    private void saveSessionUnlocked(CodexSessionRecord record)
    {
        auto root = codexRoot(record.sessionRoot);
        mkdirRecurse(root);
        writeJsonFile(buildPath(root, "thread.json"), sessionRecordJson(record));
        writeJsonFile(buildPath(root, "status.json"), statusRecordJson(record));
        updateSessionAssociation(record);
    }

    private void saveTurnUnlocked(CodexTurnRecord turn)
    {
        mkdirRecurse(turn.turnRoot);
        writeJsonFile(buildPath(turn.turnRoot, "turn.json"), turnRecordJson(turn));
    }

    private void appendEventUnlocked(string sessionRoot, CodexLiveEvent event)
    {
        appendLine(buildPath(codexRoot(sessionRoot), "events.jsonl"), liveEventJson(event));
    }

    private void updateSessionAssociation(CodexSessionRecord record)
    {
        auto path = buildPath(record.sessionRoot, "session.json");
        withSessionStorageLock(record.sessionRoot, {
            auto payload = parseJSON(readText(path));
            enforce(payload.type == JSONType.object, "session.json must be an object");
            payload["codex"] = parseJSON(jsonObject([
                jsonStringField("thread_id", record.threadId),
                jsonStringField("codex_session_id", record.codexSessionId),
                jsonStringField("created_at", record.createdAt),
                jsonStringField("updated_at", record.updatedAt),
                jsonStringField("last_turn_id", record.lastTurnId),
                jsonLongField("last_turn_ordinal", record.lastTurnOrdinal),
                jsonStringField("status", record.status),
            ]));
            writeJsonFile(path, payload.toString());
        });
    }
}

string sessionRecordJson(CodexSessionRecord record)
{
    return jsonObject([
        jsonStringField("profile_id", record.profileId),
        jsonStringField("session_id", record.sessionId),
        jsonStringField("thread_id", record.threadId),
        jsonStringField("codex_session_id", record.codexSessionId),
        jsonStringField("created_at", record.createdAt),
        jsonStringField("updated_at", record.updatedAt),
        jsonStringField("last_turn_id", record.lastTurnId),
        jsonLongField("last_turn_ordinal", record.lastTurnOrdinal),
        jsonStringField("status", record.status),
        jsonStringField("latest_reasoning", record.latestReasoning),
        jsonStringField("final_text", record.finalText),
        jsonStringField("error_message", record.errorMessage),
        jsonLongField("event_sequence", record.eventSequence),
    ]);
}

string statusRecordJson(CodexSessionRecord record)
{
    return jsonObject([
        jsonStringField("thread_id", record.threadId),
        jsonStringField("turn_id", record.lastTurnId),
        jsonStringField("status", record.status),
        jsonStringField("updated_at", record.updatedAt),
        jsonStringField("latest_reasoning", record.latestReasoning),
        jsonStringField("final_response", record.finalText),
        jsonStringField("error", record.errorMessage),
    ]);
}

string turnRecordJson(CodexTurnRecord turn)
{
    return jsonObject([
        jsonLongField("ordinal", turn.ordinal),
        jsonStringField("thread_id", turn.threadId),
        jsonStringField("turn_id", turn.turnId),
        jsonStringField("status", turn.status),
        jsonStringField("started_at", turn.startedAt),
        jsonStringField("updated_at", turn.updatedAt),
        jsonStringField("completed_at", turn.completedAt),
        jsonStringField("initial_message", turn.initialMessage),
        jsonStringField("latest_reasoning", turn.latestReasoning),
        jsonStringField("final_text", turn.finalText),
        jsonStringField("error_message", turn.errorMessage),
    ]);
}

string dispatchJson(CodexDispatchRecord dispatch)
{
    return jsonObject([
        jsonStringField("id", dispatch.id),
        jsonStringField("pi_turn_id", dispatch.piTurnId),
        jsonStringField("operation", dispatch.operation),
        jsonStringField("state", dispatch.state),
        jsonStringField("error_kind", dispatch.errorKind),
        jsonStringField("error_message", dispatch.errorMessage),
        jsonStringField("created_at", dispatch.createdAt),
        jsonStringField("updated_at", dispatch.updatedAt),
        jsonStringField("thread_id", dispatch.threadId),
        jsonStringField("turn_id", dispatch.turnId),
    ]);
}

string liveEventJson(CodexLiveEvent event)
{
    return jsonObject([
        jsonLongField("sequence", event.sequence),
        jsonStringField("profile_id", event.profileId),
        jsonStringField("session_id", event.sessionId),
        jsonStringField("thread_id", event.threadId),
        jsonStringField("turn_id", event.turnId),
        jsonStringField("item_id", event.itemId),
        jsonLongField("summary_index", event.summaryIndex),
        jsonStringField("kind", event.kind),
        jsonStringField("operation", event.operation),
        jsonStringField("text", event.text),
        jsonStringField("name", event.name),
        jsonStringField("status", event.status),
        jsonStringField("timestamp", event.timestamp),
        jsonBoolField("recovered", event.recovered),
    ]);
}

CodexLiveEvent liveEventFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return CodexLiveEvent(
        json.positiveInt("sequence"),
        json.text("profile_id"),
        json.text("session_id"),
        json.text("thread_id"),
        json.text("turn_id"),
        json.text("item_id"),
        json.integer("summary_index"),
        json.text("kind"),
        json.text("operation"),
        json.text("text"),
        json.text("name"),
        json.text("status"),
        json.text("timestamp"),
        json.boolean("recovered"),
    );
}

private string codexRoot(string sessionRoot)
{
    return buildPath(sessionRoot, "codex");
}

private string ordinalText(long ordinal)
{
    import std.format : format;
    return "%04d".format(ordinal);
}

private void appendLine(string path, string line)
{
    mkdirRecurse(dirName(path));
    auto file = File(path, "a");
    file.writeln(line);
    file.flush();
}
