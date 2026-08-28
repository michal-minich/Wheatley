module wheatley.server.codex.service;

import std.algorithm : canFind;
import std.array : appender, join;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isDir, readText;
import std.json : JSONType, JSONValue;
import std.path : baseName, dirName;
import std.string : split, strip;
import std.uuid : randomUUID;

import vibe.core.sync : TaskMutex, scopedMutexLock;
import vibe.core.log : logWarn;

import wheatley.common.api.session : SessionKey;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.codex.runner : CodexAppServerGateway;
import wheatley.server.codex.port : CodexSessionPort;
import wheatley.server.codex.store : CodexSessionStore, liveEventJson;
import wheatley.server.codex.types :
    CodexDispatchRecord,
    CodexLiveEvent,
    CodexMessageResult,
    CodexSessionRecord,
    CodexStatusResult,
    CodexTurnRecord;

private struct SessionBinding
{
    SessionKey session;
    string sessionRoot;
}

/** Routes one permanent Codex thread for each Wheatley session. */
final class CodexSessionService : CodexSessionPort
{
    private string workspaceRoot;
    private CodexSessionStore store;
    private CodexAppServerGateway gateway;
    private TaskMutex dispatchMutex;
    private TaskMutex stateMutex;
    private SessionBinding[string] bindingsByThread;
    private string[string] finalByTurn;

    this(string workspaceRoot)
    {
        this.workspaceRoot = workspaceRoot;
        this.store = new CodexSessionStore;
        this.dispatchMutex = new TaskMutex;
        this.stateMutex = new TaskMutex;
        this.gateway = new CodexAppServerGateway(
            workspaceRoot,
            (notification) { handleNotificationSafely(notification); },
        );
    }

    void start()
    {
        gateway.start();
    }

    /** Restores routing and native subscriptions after the worker itself restarts. */
    void reconcileAssociations(string profilesRoot)
    {
        if (!exists(profilesRoot) || !isDir(profilesRoot)) return;
        gateway.start();
        foreach (entry; dirEntries(profilesRoot, SpanMode.depth)) {
            if (entry.isDir || baseName(entry.name) != "thread.json") continue;
            if (baseName(dirName(entry.name)) != "codex") continue;
            try {
                auto json = Json.parse(readText(entry.name));
                auto threadId = json.text("thread_id");
                if (!threadId.length) continue;
                auto sessionRoot = dirName(dirName(entry.name));
                auto session = SessionKey(json.text("profile_id"), json.text("session_id"));
                auto record = store.load(session, sessionRoot);
                registerBinding(record);
                auto native = readThread(threadId);
                reconcile(session, sessionRoot, record, native);
                auto latest = latestNativeTurn(native);
                if (latest !is null && Json.object(*latest).text("status") == "inProgress")
                    resumeThread(threadId);
            } catch (Exception error) {
                try {
                    auto json = Json.parse(readText(entry.name));
                    auto sessionRoot = dirName(dirName(entry.name));
                    auto session = SessionKey(json.text("profile_id"), json.text("session_id"));
                    if (nativeThreadMissing(error.msg))
                        store.setSystemError(session, sessionRoot,
                            "The paired native Codex thread is missing and cannot be replaced.");
                } catch (Exception) {
                }
            }
        }
    }

    CodexMessageResult message(
        SessionKey session,
        string sessionRoot,
        string piTurnId,
        string value,
    )
    {
        auto clean = value.strip;
        enforce(workspaceRoot.length, "Codex is disabled: no workspace root is configured");
        enforce(clean.length, "codex_message requires a non-empty message");
        enforce(clean.length <= 20_000, "codex_message message is too long");

        auto dispatchId = randomUUID().toString();
        auto createdAt = nowIso();
        auto dispatch = CodexDispatchRecord(
            dispatchId,
            piTurnId,
            "routing",
            "dispatching",
            "",
            "",
            createdAt,
            createdAt,
            "",
            "",
        );
        store.appendDispatch(sessionRoot, dispatch);

        auto guard = scopedMutexLock(dispatchMutex);
        try {
            gateway.start();
            auto record = store.load(session, sessionRoot);
            enforce(record.status != "system_error",
                record.errorMessage.length
                    ? record.errorMessage
                    : "This Wheatley session's Codex thread is unavailable");

            if (!record.threadId.length) {
                dispatch.operation = "create_thread";
                auto thread = startThread(session);
                auto threadId = textAt(thread, ["thread", "id"]);
                auto codexSessionId = textAt(thread, ["thread", "sessionId"]);
                enforce(threadId.length, "Codex thread/start returned no thread ID");
                enforce(codexSessionId.length, "Codex thread/start returned no session ID");
                record = store.associate(
                    session,
                    sessionRoot,
                    threadId,
                    codexSessionId,
                );
                registerBinding(record);
                gateway.request("thread/name/set", jsonObject([
                    jsonStringField("threadId", threadId),
                    jsonStringField("name", "Wheatley · " ~ session.profileId ~ " · " ~ session.sessionId),
                ]));
                auto turnId = startTurn(threadId, dispatchId, clean);
                store.beginTurn(session, sessionRoot, turnId, clean);
                dispatch.turnId = turnId;
            } else {
                registerBinding(record);
                auto native = readThread(record.threadId);
                reconcile(session, sessionRoot, record, native);
                record = store.load(session, sessionRoot);
                enforce(record.status != "system_error",
                    record.errorMessage.length
                        ? record.errorMessage
                        : "This Wheatley session's Codex thread is unavailable");
                auto nativeTurn = latestNativeTurn(native);
                auto nativeStatus = nativeTurn is null
                    ? ""
                    : Json.object(*nativeTurn).text("status");
                if (nativeStatus == "inProgress") {
                    dispatch.operation = "steer_turn";
                    auto turnId = Json.object(*nativeTurn).text("id");
                    steerTurn(record.threadId, turnId, dispatchId, clean);
                    dispatch.turnId = turnId;
                    store.appendItem(
                        session,
                        sessionRoot,
                        turnId,
                        "steer:" ~ dispatchId,
                        -1,
                        "steer",
                        "finish",
                        clean,
                        "",
                        "accepted",
                    );
                } else {
                    dispatch.operation = "start_turn";
                    resumeThread(record.threadId);
                    auto turnId = startTurn(record.threadId, dispatchId, clean);
                    store.beginTurn(session, sessionRoot, turnId, clean);
                    dispatch.turnId = turnId;
                }
            }

            dispatch.state = "accepted";
            dispatch.updatedAt = nowIso();
            dispatch.threadId = store.load(session, sessionRoot).threadId;
            store.appendDispatch(sessionRoot, dispatch);
            return CodexMessageResult(true, "Message sent to Codex.", dispatchId);
        } catch (Exception error) {
            dispatch.errorKind = dispatchErrorKind(error.msg);
            dispatch.state = dispatch.errorKind == "io" ? "unconfirmed" : "failed";
            dispatch.errorMessage = error.msg;
            dispatch.updatedAt = nowIso();
            store.appendDispatch(sessionRoot, dispatch);
            if (nativeThreadMissing(error.msg)) {
                try store.setSystemError(
                    session,
                    sessionRoot,
                    "The paired native Codex thread is missing and cannot be replaced.",
                );
                catch (Exception) {
                }
            }
            try store.appendItem(
                session,
                sessionRoot,
                dispatch.turnId.length ? dispatch.turnId : "dispatch:" ~ dispatchId,
                "dispatch_error:" ~ dispatchId,
                -1,
                "error",
                "finish",
                error.msg,
                "",
                dispatch.state,
            );
            catch (Exception) {
            }
            throw error;
        }
    }

    CodexStatusResult status(SessionKey session, string sessionRoot)
    {
        auto record = store.load(session, sessionRoot);
        if (!record.threadId.length) {
            return CodexStatusResult(
                "not_started",
                true,
                record.updatedAt,
                "message",
                "No Codex task has been started in this conversation.",
                false,
            );
        }
        if (record.status == "system_error") return projectedCodexStatus(record, true);
        try {
            gateway.start();
            registerBinding(record);
            auto native = readThread(record.threadId);
            reconcile(session, sessionRoot, record, native);
            return projectedCodexStatus(store.load(session, sessionRoot), true);
        } catch (Exception error) {
            logWarn("Codex status refresh failed for %s/%s: %s",
                session.profileId, session.sessionId, error.msg);
            if (nativeThreadMissing(error.msg)) {
                auto message = "The paired native Codex thread is missing and cannot be replaced.";
                store.setSystemError(session, sessionRoot, message);
                return projectedCodexStatus(store.load(session, sessionRoot), true);
            }
            record = store.load(session, sessionRoot);
            return projectedCodexStatus(record, false);
        }
    }

    CodexLiveEvent[] eventsAfter(
        SessionKey session,
        string sessionRoot,
        long afterSequence,
        long limit = 200,
    )
    {
        return store.eventsAfter(session, sessionRoot, afterSequence, limit);
    }

    void shutdown()
    {
        gateway.shutdown();
    }

    private JSONValue startThread(SessionKey session)
    {
        return gateway.request("thread/start", jsonObject([
            jsonStringField("cwd", workspaceRoot),
            jsonStringField("approvalPolicy", "never"),
            jsonStringField("sandbox", "workspace-write"),
            jsonBoolField("ephemeral", false),
            jsonStringField("threadSource", "wheatley"),
        ]));
    }

    private void resumeThread(string threadId)
    {
        gateway.request("thread/resume", jsonObject([
            jsonStringField("threadId", threadId),
        ]));
    }

    private JSONValue readThread(string threadId)
    {
        return gateway.request("thread/read", jsonObject([
            jsonStringField("threadId", threadId),
            jsonBoolField("includeTurns", true),
        ]));
    }

    private string startTurn(string threadId, string dispatchId, string message)
    {
        auto input = "[" ~ jsonObject([
            jsonStringField("type", "text"),
            jsonStringField("text", wrappedPrompt(dispatchId, message)),
        ]) ~ "]";
        auto result = gateway.request("turn/start", jsonObject([
            jsonStringField("threadId", threadId),
            jsonRawField("input", input),
            jsonStringField("cwd", workspaceRoot),
            jsonStringField("approvalPolicy", "never"),
            jsonStringField("summary", "auto"),
            jsonRawField("sandboxPolicy", jsonObject([
                jsonStringField("type", "workspaceWrite"),
                jsonBoolField("networkAccess", false),
                jsonRawField("writableRoots", "[]"),
            ])),
        ]));
        auto turnId = textAt(result, ["turn", "id"]);
        enforce(turnId.length, "Codex turn/start returned no turn ID");
        return turnId;
    }

    private void steerTurn(
        string threadId,
        string turnId,
        string dispatchId,
        string message,
    )
    {
        auto input = "[" ~ jsonObject([
            jsonStringField("type", "text"),
            jsonStringField("text", dispatchText(dispatchId, message)),
        ]) ~ "]";
        gateway.request("turn/steer", jsonObject([
            jsonStringField("threadId", threadId),
            jsonStringField("expectedTurnId", turnId),
            jsonRawField("input", input),
        ]));
    }

    private void reconcile(
        SessionKey session,
        string sessionRoot,
        CodexSessionRecord record,
        JSONValue native,
    )
    {
        auto threadId = textAt(native, ["thread", "id"]);
        enforce(threadId == record.threadId, "Native Codex thread identity changed");
        auto turnValue = latestNativeTurn(native);
        if (turnValue is null || !record.lastTurnId.length) return;
        auto turn = Json.object(*turnValue);
        if (turn.text("id") != record.lastTurnId) return;
        recoverReasoning(store, session, sessionRoot, record, turn);
        auto local = store.latestTurn(session, sessionRoot);
        auto status = turn.text("status");
        if (status == "inProgress" || local.status != "running") return;
        auto finalText = status == "completed" ? finalAgentMessage(turn) : "";
        auto errorMessage = nativeTurnError(turn);
        store.completeTurn(
            session,
            sessionRoot,
            local.turnId,
            status == "completed" ? "completed" : status,
            finalText,
            errorMessage,
            true,
        );
    }

    private void registerBinding(CodexSessionRecord record)
    {
        if (!record.threadId.length) return;
        auto guard = scopedMutexLock(stateMutex);
        bindingsByThread[record.threadId] = SessionBinding(
            SessionKey(record.profileId, record.sessionId),
            record.sessionRoot,
        );
    }

    private void handleNotificationSafely(JSONValue notification) nothrow
    {
        try handleNotification(notification);
        catch (Throwable) {
        }
    }

    private void handleNotification(JSONValue notification)
    {
        auto json = Json.object(notification);
        auto method = json.opt.textOrEmpty("method");
        auto params = json.opt.object("params");
        if (params.isNull) return;
        auto p = params.get;
        if (method == "wheatley/processFailed") {
            auto message = p.opt.textOrEmpty("message");
            SessionBinding[] bindings;
            {
                auto guard = scopedMutexLock(stateMutex);
                foreach (threadId, binding; bindingsByThread) bindings ~= binding;
            }
            foreach (binding; bindings) {
                auto record = store.load(binding.session, binding.sessionRoot);
                if (record.status != "running" || !record.lastTurnId.length) continue;
                store.completeTurn(
                    binding.session,
                    binding.sessionRoot,
                    record.lastTurnId,
                    "interrupted",
                    "",
                    message.length ? message : "Codex App Server stopped.",
                );
            }
            return;
        }

        auto threadId = p.opt.textOrEmpty("threadId");
        if (!threadId.length) {
            auto thread = p.opt.object("thread");
            if (!thread.isNull) threadId = thread.get.opt.textOrEmpty("id");
        }
        auto binding = bindingFor(threadId);
        if (!binding.session.profileId.length) return;
        auto turnId = p.opt.textOrEmpty("turnId");
        if (!turnId.length) {
            auto turn = p.opt.object("turn");
            if (!turn.isNull) turnId = turn.get.opt.textOrEmpty("id");
        }
        if (!turnId.length) turnId = store.load(binding.session, binding.sessionRoot).lastTurnId;

        if (method == "item/reasoning/summaryPartAdded") {
            store.beginReasoning(
                binding.session,
                binding.sessionRoot,
                turnId,
                p.opt.textOrEmpty("itemId"),
                optionalInteger(p, "summaryIndex", -1),
            );
            return;
        }
        if (method == "item/reasoning/summaryTextDelta") {
            store.appendReasoning(
                binding.session,
                binding.sessionRoot,
                turnId,
                p.opt.textOrEmpty("itemId"),
                optionalInteger(p, "summaryIndex", -1),
                p.opt.textOrEmpty("delta"),
            );
            return;
        }
        if (method == "item/started" || method == "item/completed") {
            auto item = p.opt.object("item");
            if (item.isNull) return;
            handleItem(
                binding,
                turnId,
                item.get,
                method == "item/completed",
            );
            return;
        }
        if (method == "turn/completed") {
            auto turn = p.opt.object("turn");
            auto status = turn.isNull ? "failed" : turn.get.opt.textOrEmpty("status");
            string finalText;
            {
                auto guard = scopedMutexLock(stateMutex);
                auto found = turnId in finalByTurn;
                if (found !is null) {
                    finalText = *found;
                    finalByTurn.remove(turnId);
                }
            }
            auto errorMessage = turn.isNull ? "" : nativeTurnError(turn.get);
            store.completeTurn(
                binding.session,
                binding.sessionRoot,
                turnId,
                status == "completed" ? "completed" : status,
                finalText,
                errorMessage,
            );
        }
    }

    private void handleItem(
        SessionBinding binding,
        string turnId,
        Json item,
        bool completed,
    )
    {
        auto type = item.opt.textOrEmpty("type");
        auto itemId = item.opt.textOrEmpty("id");
        if (type == "agentMessage") {
            if (!completed) return;
            auto text = item.opt.textOrEmpty("text");
            auto phase = item.opt.textOrEmpty("phase");
            if (phase == "final_answer" || !phase.length) {
                auto guard = scopedMutexLock(stateMutex);
                finalByTurn[turnId] = text;
            }
            return;
        }
        if (type == "reasoning") {
            if (!completed) return;
            auto summaries = stringArrayField(item.value, "summary");
            foreach (index, summary; summaries) {
                store.appendItem(
                    binding.session,
                    binding.sessionRoot,
                    turnId,
                    itemId,
                    cast(long) index,
                    "reasoning_summary",
                    "finish",
                    "",
                    "",
                    "completed",
                );
            }
            return;
        }
        if (type == "commandExecution") {
            store.appendItem(
                binding.session,
                binding.sessionRoot,
                turnId,
                itemId,
                -1,
                "tool",
                completed ? "finish" : "start",
                item.opt.textOrEmpty("command"),
                "command",
                completed ? item.opt.textOrEmpty("status") : "running",
            );
            return;
        }
        if (type == "fileChange") {
            store.appendItem(
                binding.session,
                binding.sessionRoot,
                turnId,
                itemId,
                -1,
                "tool",
                completed ? "finish" : "start",
                "",
                "file_change",
                completed ? item.opt.textOrEmpty("status") : "running",
            );
        }
    }

    private SessionBinding bindingFor(string threadId)
    {
        if (!threadId.length) return SessionBinding.init;
        auto guard = scopedMutexLock(stateMutex);
        auto found = threadId in bindingsByThread;
        return found is null ? SessionBinding.init : *found;
    }
}

string codexMessageResultJson(CodexMessageResult result)
{
    return jsonObject([
        jsonBoolField("accepted", result.accepted),
        jsonStringField("message", result.message),
        jsonStringField("dispatch_id", result.dispatchId),
    ]);
}

string codexStatusResultJson(CodexStatusResult result)
{
    return jsonObject([
        jsonStringField("status", result.status),
        jsonBoolField("fresh", result.fresh),
        jsonStringField("updated_at", result.updatedAt),
        jsonStringField("content_kind", result.contentKind),
        jsonStringField("content", result.content),
        jsonBoolField("truncated", result.truncated),
    ]);
}

CodexStatusResult projectedCodexStatus(CodexSessionRecord record, bool fresh)
{
    if (!fresh && record.status == "running" && !record.latestReasoning.length) {
        return CodexStatusResult(
            "unknown",
            false,
            record.updatedAt,
            "error",
            "Codex status is unavailable; no cached progress summary exists.",
            false,
        );
    }
    string kind;
    string content;
    switch (record.status) {
        case "not_started":
        case "idle":
            kind = "message";
            content = "No Codex task is currently running.";
            break;
        case "running":
            kind = "reasoning_summary";
            content = record.latestReasoning.length
                ? recentReasoning(record.latestReasoning)
                : "Codex is running; no progress summary is available yet.";
            break;
        case "completed":
            kind = "final_response";
            content = record.finalText;
            break;
        case "failed":
        case "interrupted":
        case "system_error":
        case "unknown":
            kind = "error";
            content = record.errorMessage;
            break;
        default:
            kind = "error";
            content = "Unknown Codex status: " ~ record.status;
            break;
    }
    auto limit = record.status == "completed" ? 4_000 : 1_500;
    auto truncated = content.length > limit;
    if (truncated) content = record.status == "running"
        ? utf8Tail(content, limit)
        : utf8Prefix(content, limit);
    return CodexStatusResult(
        record.status,
        fresh,
        record.updatedAt,
        kind,
        content,
        truncated,
    );
}

private void recoverReasoning(
    CodexSessionStore store,
    SessionKey session,
    string sessionRoot,
    CodexSessionRecord record,
    Json nativeTurn,
)
{
    if (record.latestReasoning.length) return;
    foreach (itemValue; nativeTurn.array("items").value.array) {
        if (itemValue.type != JSONType.object) continue;
        auto item = Json.object(itemValue);
        if (item.opt.textOrEmpty("type") != "reasoning") continue;
        auto itemId = item.opt.textOrEmpty("id");
        foreach (index, summary; stringArrayField(item.value, "summary")) {
            if (!summary.length) continue;
            store.beginReasoning(
                session,
                sessionRoot,
                nativeTurn.text("id"),
                itemId,
                cast(long) index,
                true,
            );
            store.appendReasoning(
                session,
                sessionRoot,
                nativeTurn.text("id"),
                itemId,
                cast(long) index,
                summary,
                true,
            );
            store.appendItem(
                session,
                sessionRoot,
                nativeTurn.text("id"),
                itemId,
                cast(long) index,
                "reasoning_summary",
                "finish",
                "",
                "",
                "completed",
                true,
            );
        }
    }
}

private string[] stringArrayField(JSONValue value, string name)
{
    if (value.type != JSONType.object) return [];
    auto found = name in value.objectNoRef;
    if (found is null || found.type != JSONType.array) return [];
    string[] result;
    foreach (item; found.array)
        if (item.type == JSONType.string) result ~= item.str;
    return result;
}

private string recentReasoning(string value)
{
    string[] sections;
    foreach (section; value.split("\n\n")) {
        auto clean = section.strip;
        if (clean.length) sections ~= clean;
    }
    auto start = sections.length > 3 ? sections.length - 3 : 0;
    return sections[start .. $].join("\n\n");
}

private string utf8Prefix(string value, size_t limit)
{
    if (value.length <= limit) return value;
    auto end = limit;
    auto bytes = cast(const(ubyte)[]) value;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) end--;
    return value[0 .. end];
}

private string utf8Tail(string value, size_t limit)
{
    if (value.length <= limit) return value;
    auto start = value.length - limit;
    auto bytes = cast(const(ubyte)[]) value;
    while (start < value.length && (bytes[start] & 0xC0) == 0x80) start++;
    return value[start .. $];
}

private JSONValue* latestNativeTurn(ref JSONValue result)
{
    auto thread = objectAt(result, ["thread"]);
    if (thread is null) return null;
    auto turns = Json.object(*thread).array("turns").value.array;
    if (!turns.length) return null;
    return &turns[$ - 1];
}

private string finalAgentMessage(Json turn)
{
    auto items = turn.array("items").value.array;
    string fallback;
    foreach_reverse (itemValue; items) {
        if (itemValue.type != JSONType.object) continue;
        auto item = Json.object(itemValue);
        if (item.opt.textOrEmpty("type") != "agentMessage") continue;
        auto text = item.opt.textOrEmpty("text");
        if (!fallback.length) fallback = text;
        if (item.opt.textOrEmpty("phase") == "final_answer") return text;
    }
    return fallback;
}

private long optionalInteger(Json json, string name, long fallback)
{
    auto value = json.opt.integer(name);
    return value.isNull ? fallback : value.get;
}

private string nativeTurnError(Json turn)
{
    auto error = turn.opt.object("error");
    if (error.isNull) return turn.opt.textOrEmpty("status") == "completed"
        ? ""
        : "Codex turn ended with status " ~ turn.opt.textOrEmpty("status");
    auto message = error.get.opt.textOrEmpty("message");
    return message.length ? message : error.get.value.toString();
}

private string wrappedPrompt(string dispatchId, string message)
{
    return "You are Codex working for the user through Wheatley.\n"
        ~ "Work only inside " ~ messageWorkspacePlaceholder ~ ". Follow the workspace WHEATLEY.md instructions. "
        ~ "Do the requested work end to end when feasible and verify practical changes.\n"
        ~ "Wheatley dispatch: " ~ dispatchId ~ "\n\n"
        ~ message.strip;
}

private enum messageWorkspacePlaceholder = "the configured workspace";

private string dispatchText(string dispatchId, string message)
{
    return "Wheatley dispatch " ~ dispatchId ~ ":\n" ~ message.strip;
}

private string dispatchErrorKind(string message)
{
    return message.canFind("App Server")
        || message.canFind("connection")
        || message.canFind("pipe")
        ? "io"
        : "invalid";
}

private bool nativeThreadMissing(string message)
{
    auto lower = message;
    import std.string : toLower;
    lower = lower.toLower;
    return lower.canFind("invalid thread id")
        || (lower.canFind("thread")
            && (lower.canFind("not found")
                || lower.canFind("not loaded")
                || lower.canFind("does not exist")));
}

private string textAt(JSONValue value, string[] path)
{
    auto found = objectAt(value, path);
    return found is null || found.type != JSONType.string ? "" : found.str;
}

private JSONValue* objectAt(ref JSONValue value, string[] path)
{
    JSONValue* current = &value;
    foreach (part; path) {
        if (current.type != JSONType.object) return null;
        auto object = current.objectNoRef;
        current = part in object;
        if (current is null) return null;
    }
    return current;
}

string codexLiveEventJson(CodexLiveEvent event)
{
    return liveEventJson(event);
}

unittest
{
    assert(recentReasoning("one\n\ntwo\n\nthree\n\nfour") == "two\n\nthree\n\nfour");
    assert(utf8Prefix("abéz", 4) == "abé");
    assert(utf8Tail("abéz", 3) == "éz");
}
