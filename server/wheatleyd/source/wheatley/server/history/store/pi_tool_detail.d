module wheatley.server.history.store.pi_tool_detail;

import std.algorithm : canFind;
import std.exception : enforce;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.server.history.store.json : jsonBool, jsonLong, jsonText;
import wheatley.server.history.store.paths : piSessionJsonlPath, toolsJsonPath;
import wheatley.server.history.store.model_input : ModelInput, loadModelInput;
import wheatley.server.history.store.llm_requests : loadLlmRequests;
import wheatley.server.history.store.pi_session :
    PiPresentationItem,
    PiTurnTranscript,
    loadPiSessionTranscript;
import wheatley.server.history.store.tool_json : turnToolArray;
import wheatley.server.history.store.types : StoredTurn;
import wheatley.common.json.read : Json;

package(wheatley.server.history) string piToolDetailJson(
    StoredTurn turn,
    string sessionRoot,
    long callIndex,
)
{
    if (callIndex == -1) return modelInputDetailJson(turn, sessionRoot);
    enforce(callIndex >= 0, "Tool call index cannot be negative");
    auto stored = storedTool(turn.turnRoot, callIndex);
    if (stored.type == JSONType.object && jsonText(stored, "source") == "scheduler")
        return schedulerToolDetailJson(turn, sessionRoot, stored, callIndex);
    auto transcript = loadPiSessionTranscript(piSessionJsonlPath(sessionRoot));
    auto piTurn = transcript.turn(turn);
    auto pi = piTurn.tool(callIndex - schedulerToolCount(turn));
    if (!pi.id.length) {
        enforce(stored.type == JSONType.object, "Tool call not found");
        auto storedJson = Json.object(stored);
        enforce(storedJson.text("status") == "running", "Tool call not found");
        return jsonObject([
            jsonStringField("schema", "wheatley.tool_detail.v1"),
            jsonRawField("tool", jsonObject([
                jsonLongField("call_index", callIndex),
                jsonStringField("call_id", storedJson.text("id")),
                jsonStringField("name", storedJson.text("name")),
                jsonStringField("source", storedJson.text("source")),
                jsonStringField("status", "running"),
                jsonStringField("started_at", storedJson.text("started_at")),
                jsonStringField("completed_at", ""),
                jsonLongField("duration_ms", jsonLong(stored, "duration_ms")),
                jsonStringField("working_directory", ""),
            ])),
            jsonRawField("arguments", storedJson.object("args").value.toString()),
            jsonRawField("content", "[]"),
            jsonRawField("details", "null"),
            jsonRawField("extension_data", "null"),
        ]);
    }

    auto startedAt = pi.timestamp.length ? pi.timestamp : jsonText(stored, "started_at");
    auto durationMs = jsonLong(stored, "duration_ms");
    auto status = toolStatus(pi, stored);
    auto arguments = pi.arguments;
    auto content = pi.hasResult ? pi.content : parseJSON("[]");
    auto details = pi.hasResult ? pi.details : JSONValue(null);

    return jsonObject([
        jsonStringField("schema", "wheatley.tool_detail.v1"),
        jsonRawField("tool", jsonObject([
            jsonLongField("call_index", callIndex),
            jsonStringField("call_id", pi.toolCallId),
            jsonStringField("name", pi.toolName),
            jsonStringField("source", "pi"),
            jsonStringField("status", status),
            jsonStringField("started_at", startedAt),
            jsonStringField("completed_at", pi.completedAt.length ? pi.completedAt : ""),
            jsonLongField("duration_ms", durationMs >= 0 ? durationMs : 0),
            jsonStringField("working_directory", piTurn.workingDirectory),
        ])),
        jsonRawField("arguments", objectOrEmpty(arguments).toString()),
        jsonRawField("content", arrayOrEmpty(content).toString()),
        jsonRawField("details", details.toString()),
        jsonRawField("extension_data", "null"),
    ]);
}

private string modelInputDetailJson(StoredTurn turn, string sessionRoot)
{
    auto captured = loadLlmRequests(turn.turnRoot);
    if (captured.type == JSONType.object)
        return capturedModelInputDetailJson(turn, sessionRoot, captured);

    auto input = loadModelInput(turn.turnRoot);
    auto hasStoredInput = input.prompt.length > 0;
    if (!input.prompt.length) {
        PiTurnTranscript piTurn;
        auto transcriptPath = piSessionJsonlPath(sessionRoot);
        if (exists(transcriptPath))
            piTurn = loadPiSessionTranscript(transcriptPath).turn(turn);
        enforce(
            piTurn.prompt.length && piTurn.prompt.strip != turn.userText.strip,
            "Model context not found",
        );
        input = ModelInput(
            piTurn.prompt,
            piTurn.promptTimestamp.length ? piTurn.promptTimestamp : turn.startedAt,
            piTurn.workingDirectory,
            piTurn.prompt.canFind("# Current User Request"),
            turn.source == "scheduled_task",
        );
    }
    auto content = "[" ~ jsonObject([
        jsonStringField("type", "text"),
        jsonStringField("text", input.prompt),
    ]) ~ "]";
    return jsonObject([
        jsonStringField("schema", "wheatley.tool_detail.v1"),
        jsonRawField("tool", jsonObject([
            jsonLongField("call_index", -1),
            jsonStringField("call_id", "model-context"),
            jsonStringField("name", "model_context"),
            jsonStringField("source", "wheatley"),
            jsonStringField("status", "succeeded"),
            jsonStringField("started_at", input.startedAt),
            jsonStringField("completed_at", input.startedAt),
            jsonLongField("duration_ms", 0),
            jsonStringField("working_directory", input.workingDirectory),
        ])),
        jsonRawField("arguments", jsonObject([
            jsonStringField("transport", "pi_rpc_prompt"),
            jsonStringField(
                "record_origin",
                hasStoredInput ? "model_input_snapshot" : "legacy_pi_session_prompt",
            ),
            jsonLongField("pi_prompt_rpc_count", 1),
            jsonLongField("pi_user_message_count", 1),
            jsonBoolField("starting_context", input.startingContext),
            jsonBoolField("private_context", input.privateContext),
        ])),
        jsonRawField("content", content),
        jsonRawField("details", "null"),
        jsonRawField("extension_data", "null"),
    ]);
}

private string capturedModelInputDetailJson(
    StoredTurn turn,
    string sessionRoot,
    JSONValue captured,
)
{
    auto root = Json.object(captured);
    auto requests = root.array("requests").value.array;
    enforce(requests.length, "Captured LLM requests are empty");
    auto first = Json.object(requests[0], "requests[0]");
    auto request = first.object("request");
    auto messages = request.array("messages").value.array;
    enforce(messages.length, "Initial LLM request has no messages");
    auto initial = Json.object(messages[0], "request.messages[0]");
    enforce(initial.text("role") == "developer" || initial.text("role") == "system",
        "Initial LLM request does not start with instructions");
    auto prompt = initial.text("content");
    auto requestObject = request.value.object;
    auto tools = "tools" in requestObject;
    auto toolCount = tools !is null && tools.type == JSONType.array
        ? cast(long) tools.array.length : 0;
    auto model = "model" in requestObject;

    string workingDirectory;
    auto transcriptPath = piSessionJsonlPath(sessionRoot);
    if (exists(transcriptPath))
        workingDirectory = loadPiSessionTranscript(transcriptPath).workingDirectory;

    auto content = "[" ~ jsonObject([
        jsonStringField("type", "text"),
        jsonStringField("text", prompt),
    ]) ~ "]";
    return jsonObject([
        jsonStringField("schema", "wheatley.tool_detail.v1"),
        jsonRawField("tool", jsonObject([
            jsonLongField("call_index", -1),
            jsonStringField("call_id", "model-context"),
            jsonStringField("name", "model_context"),
            jsonStringField("source", "wheatley"),
            jsonStringField("status", "succeeded"),
            jsonStringField("started_at", first.text("captured_at")),
            jsonStringField("completed_at", first.text("captured_at")),
            jsonLongField("duration_ms", 0),
            jsonStringField("working_directory", workingDirectory),
        ])),
        jsonRawField("arguments", jsonObject([
            jsonStringField("transport", "openai_chat_completions"),
            jsonStringField("record_origin", "llm_request_capture"),
            jsonLongField("provider_request_count", cast(long) requests.length),
            jsonStringField("pi_version", first.text("pi_version")),
            jsonStringField(
                "model",
                model !is null && model.type == JSONType.string ? model.str : "",
            ),
            jsonLongField("tool_schema_count", toolCount),
            jsonBoolField("starting_context", true),
            jsonBoolField("private_context", turn.source == "scheduled_task"),
        ])),
        jsonRawField("content", content),
        jsonRawField("details", "null"),
        jsonRawField("extension_data", captured.toString()),
    ]);
}

private long schedulerToolCount(StoredTurn turn)
{
    auto path = toolsJsonPath(turn.turnRoot);
    if (!exists(path)) return 0;
    long result;
    foreach (tool; turnToolArray(parseJSON(readText(path))).array)
        if (jsonText(tool, "source") == "scheduler") result++;
    return result;
}

private string schedulerToolDetailJson(
    StoredTurn turn,
    string sessionRoot,
    JSONValue stored,
    long callIndex,
)
{
    auto args = parseJSON(Json.object(stored).object("args").value.toString());
    auto result = Json.object(stored).object("result").value;
    auto details = Json.object(result).opt.object("details").isNull
        ? JSONValue(null) : Json.object(result).opt.object("details").get.value;
    if (details.type == JSONType.object) {
        details = parseJSON(details.toString());
        details.object.remove("injected_prompt");
    }

    PiTurnTranscript piTurn;
    auto transcriptPath = piSessionJsonlPath(sessionRoot);
    if (exists(transcriptPath))
        piTurn = loadPiSessionTranscript(transcriptPath).turn(turn);
    auto input = loadModelInput(turn.turnRoot);
    auto hasPromptEvent = piTurn.promptEvent.type == JSONType.object;
    auto promptRecord = hasPromptEvent ? piTurn.promptEvent.toString() : input.prompt;

    args.object["record_origin"] = JSONValue(
        hasPromptEvent ? "pi_session_jsonl" : "model_input_snapshot",
    );
    args.object["pi_prompt_rpc_count"] = JSONValue(1);
    args.object["pi_user_message_count"] = JSONValue(1);
    auto content = promptRecord.length ? "[" ~ jsonObject([
        jsonStringField("type", hasPromptEvent ? "json" : "text"),
        jsonStringField("text", promptRecord),
    ]) ~ "]" : "[]";
    auto lifecycleStatus = details.type == JSONType.object
        ? Json.object(details).opt.textOrEmpty("lifecycle_status") : "";
    auto status = lifecycleStatus == "queued" || lifecycleStatus == "running"
        ? "running"
        : Json.object(stored).boolean("ok") ? "succeeded" : "failed";
    auto completedAt = lifecycleStatus == "completed" || lifecycleStatus == "failed"
        ? turn.completedAt : "";
    return jsonObject([
        jsonStringField("schema", "wheatley.tool_detail.v1"),
        jsonRawField("tool", jsonObject([
            jsonLongField("call_index", callIndex),
            jsonStringField("call_id", Json.object(stored).text("id")),
            jsonStringField("name", Json.object(stored).text("name")),
            jsonStringField("source", "scheduler"),
            jsonStringField("status", status),
            jsonStringField("started_at", Json.object(stored).text("started_at")),
            jsonStringField("completed_at", completedAt),
            jsonLongField("duration_ms", jsonLong(stored, "duration_ms")),
            jsonStringField("working_directory", ""),
        ])),
        jsonRawField("arguments", args.toString()),
        jsonRawField("content", content),
        jsonRawField("details", details.toString()),
        jsonRawField("extension_data", jsonObject([
            jsonStringField("record_origin", "scheduler_provenance"),
            jsonRawField("record", stored.toString()),
        ])),
    ]);
}

private JSONValue storedTool(string turnRoot, long callIndex)
{
    auto path = toolsJsonPath(turnRoot);
    if (!exists(path)) return JSONValue(null);
    foreach (tool; turnToolArray(parseJSON(readText(path))).array) {
        if (jsonLong(tool, "index") == callIndex) return tool;
    }
    return JSONValue(null);
}

private string toolStatus(PiPresentationItem pi, JSONValue stored)
{
    if (pi.hasResult) return pi.isError ? "failed" : "succeeded";
    if (stored.type == JSONType.object) return jsonText(stored, "status");
    return "running";
}

private JSONValue objectOrEmpty(JSONValue value)
{
    return value.type == JSONType.object ? value : parseJSON("{}");
}

private JSONValue arrayOrEmpty(JSONValue value)
{
    return value.type == JSONType.array ? value : parseJSON("[]");
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-pi-tool-detail-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto turnRoot = buildPath(root, "turn");
    mkdirRecurse(turnRoot);
    write(
        buildPath(root, "pi_session.jsonl"),
        `{"type":"session","version":3,"id":"session","timestamp":"2026-07-07T14:55:00Z","cwd":"/tmp"}` ~ "\n"
        ~ `{"type":"message","id":"user","parentId":null,"timestamp":"2026-07-07T14:55:01Z","message":{"role":"user","content":[{"type":"text","text":"Search"}]}}` ~ "\n"
        ~ `{"type":"message","id":"assistant","parentId":"user","timestamp":"2026-07-07T14:55:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"web_search","arguments":{"query":"weather"}}]}}` ~ "\n"
        ~ `{"type":"message","id":"result","parentId":"assistant","timestamp":"2026-07-07T14:55:03Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"web_search","content":[{"type":"text","text":"sunny"}],"isError":false}}` ~ "\n",
    );
    write(
        buildPath(turnRoot, "tools.json"),
        `{"schema":"wheatley.runtime_tools.v1","tools":[{"id":"legacy","index":0,"name":"web_search","source":"legacy_runtime","started_at":"2026-07-07T14:55:02Z","duration_ms":1000,"ok":true,"status":"succeeded","args":{},"result":{}}]}`,
    );

    StoredTurn turn;
    turn.id = "tester/sessions/2026/07/07/14_55_00/turns/14_55_01_000000";
    turn.status = "completed";
    turn.startedAt = "2026-07-07T14:55:01Z";
    turn.completedAt = "2026-07-07T14:55:04Z";
    turn.userText = "Search";
    turn.turnRoot = turnRoot;

    auto detail = parseJSON(piToolDetailJson(turn, root, 0));
    assert(detail.object["tool"].object["source"].str == "pi");
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import wheatley.server.history.store.model_input : ModelInput, writeModelInput;

    auto root = buildPath(tempDir(), "wheatley-model-input-detail-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto turnRoot = buildPath(root, "turn");
    mkdirRecurse(turnRoot);
    auto prompt = "Private scheduler context\n\n# Current User Request\n\nTell a joke.\n";
    writeModelInput(turnRoot, ModelInput(prompt, "2026-08-18T12:00:00Z", "/work", true, true));
    write(
        buildPath(root, "pi_session.jsonl"),
        `{"type":"session","version":3,"id":"session","timestamp":"2026-08-18T12:00:00Z","cwd":"/work"}` ~ "\n"
        ~ `{"type":"message","id":"user","parentId":null,"timestamp":"2026-08-18T12:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Unrelated Pi event."}]}}` ~ "\n",
    );

    StoredTurn turn;
    turn.id = "tester/sessions/2026/08/18/12_00_00/turns/12_00_00_000000";
    turn.turnRoot = turnRoot;
    turn.status = "completed";
    turn.startedAt = "2026-08-18T12:00:00Z";
    turn.completedAt = "2026-08-18T12:00:01Z";
    turn.userText = "Tell a joke.";
    auto detail = parseJSON(piToolDetailJson(turn, root, -1));
    assert(detail.object["tool"].object["source"].str == "wheatley");
    assert(detail.object["tool"].object["call_index"].integer == -1);
    assert(detail.object["content"].array[0].object["type"].str == "text");
    assert(detail.object["content"].array[0].object["text"].str == prompt);
    assert(detail.object["arguments"].object["record_origin"].str
        == "model_input_snapshot");
    assert(detail.object["arguments"].object["pi_prompt_rpc_count"].integer == 1);
    assert(detail.object["arguments"].object["pi_user_message_count"].integer == 1);
    assert(detail.object["arguments"].object["private_context"].boolean);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import wheatley.server.history.store.llm_requests :
        LlmRequestCapture,
        appendLlmRequest;

    auto root = buildPath(tempDir(), "wheatley-captured-context-detail-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto turnRoot = buildPath(root, "turn");
    mkdirRecurse(turnRoot);
    write(
        buildPath(root, "pi_session.jsonl"),
        `{"type":"session","version":3,"id":"session","timestamp":"2026-08-27T13:36:01Z","cwd":"/work"}` ~ "\n",
    );
    appendLlmRequest(turnRoot, LlmRequestCapture(
        "2026-08-27T13:36:02Z",
        "0.83.0",
        parseJSON(`{"model":"ornith","messages":[{"role":"developer","content":"Pi\n\nWheatley"},{"role":"user","content":[{"type":"text","text":"Hello"}]}],"tools":[{"type":"function","function":{"name":"read"}}]}`),
    ));
    appendLlmRequest(turnRoot, LlmRequestCapture(
        "2026-08-27T13:36:03Z",
        "0.83.0",
        parseJSON(`{"model":"ornith","messages":[{"role":"developer","content":"Pi\n\nWheatley"},{"role":"tool","content":"done"}],"tools":[]}`),
    ));

    StoredTurn turn;
    turn.id = "tester/sessions/2026/08/27/13_36_01/turns/13_36_02_000000";
    turn.turnRoot = turnRoot;
    turn.status = "completed";
    turn.startedAt = "2026-08-27T13:36:02Z";
    turn.completedAt = "2026-08-27T13:36:04Z";
    turn.userText = "Hello";
    auto detail = parseJSON(piToolDetailJson(turn, root, -1));
    assert(detail.object["content"].array[0].object["text"].str == "Pi\n\nWheatley");
    assert(detail.object["arguments"].object["record_origin"].str
        == "llm_request_capture");
    assert(detail.object["arguments"].object["provider_request_count"].integer == 2);
    assert(detail.object["arguments"].object["tool_schema_count"].integer == 1);
    assert(detail.object["extension_data"].object["requests"].array.length == 2);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import wheatley.server.history.store.model_input : ModelInput, writeModelInput;

    auto root = buildPath(tempDir(), "wheatley-scheduler-detail-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto turnRoot = buildPath(root, "turn");
    mkdirRecurse(turnRoot);
    write(
        buildPath(turnRoot, "tools.json"),
        `{"schema":"wheatley.runtime_tools.v1","tools":[{"id":"scheduled-task:occurrence","index":0,"name":"scheduled_task_trigger","source":"scheduler","started_at":"2026-08-18T12:00:00Z","duration_ms":0,"ok":true,"status":"running","args":{"task_id":"task"},"result":{"text":"Scheduled task started.","details":{"injected_prompt":[{"kind":"task_request","text":"Tell a joke."}]}}}]}`,
    );
    writeModelInput(
        turnRoot,
        ModelInput("Private context\n\nTell a joke.", "2026-08-18T12:00:00Z", "/work", false, true),
    );

    StoredTurn turn;
    turn.id = "tester/sessions/2026/08/18/12_00_00/turns/12_00_00_000000";
    turn.turnRoot = turnRoot;
    auto detail = parseJSON(piToolDetailJson(turn, root, 0));
    assert(detail.object["arguments"].object["pi_prompt_rpc_count"].integer == 1);
    assert(detail.object["arguments"].object["pi_user_message_count"].integer == 1);
    assert(detail.object["content"].array[0].object["text"].str
        == "Private context\n\nTell a joke.");
    assert("injected_prompt" !in detail.object["details"].object);
    auto raw = detail.object["extension_data"].object["record"];
    assert(raw.object["source"].str == "scheduler");
    assert(raw.object["result"].object["details"].object["injected_prompt"].array.length == 1);
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-pi-tool-detail-search-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto turnRoot = buildPath(root, "turn");
    mkdirRecurse(turnRoot);
    write(
        buildPath(root, "pi_session.jsonl"),
        `{"type":"session","version":3,"id":"session","timestamp":"2026-07-07T14:55:00Z","cwd":"/tmp"}` ~ "\n"
        ~ `{"type":"message","id":"user","parentId":null,"timestamp":"2026-07-07T14:55:01Z","message":{"role":"user","content":[{"type":"text","text":"Search"}]}}` ~ "\n"
        ~ `{"type":"message","id":"assistant","parentId":"user","timestamp":"2026-07-07T14:55:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"web_search","arguments":{"query":"weather"}}]}}` ~ "\n"
        ~ `{"type":"message","id":"result","parentId":"assistant","timestamp":"2026-07-07T14:55:03Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"web_search","content":[{"type":"text","text":"sunny"}],"details":{"searchId":"s1"},"isError":false}}` ~ "\n"
        ~ `{"type":"custom","customType":"web-search-results","timestamp":"2026-07-07T14:55:03Z","data":{"id":"s1","results":[{"title":"Secret extra"}]}}` ~ "\n",
    );
    write(
        buildPath(turnRoot, "tools.json"),
        `{"schema":"wheatley.runtime_tools.v1","tools":[{"id":"legacy","index":0,"name":"web_search","source":"pi","started_at":"2026-07-07T14:55:02Z","duration_ms":1000,"ok":true,"status":"succeeded","args":{"query":"weather"},"result":{"text":"sunny","details":null}}]}`,
    );

    StoredTurn turn;
    turn.id = "tester/sessions/2026/07/07/14_55_00/turns/14_55_01_000000";
    turn.status = "completed";
    turn.startedAt = "2026-07-07T14:55:01Z";
    turn.completedAt = "2026-07-07T14:55:04Z";
    turn.userText = "Search";
    turn.turnRoot = turnRoot;

    auto detail = parseJSON(piToolDetailJson(turn, root, 0));
    assert(detail.object["content"].array[0].object["text"].str == "sunny");
    assert(detail.object["details"].object["searchId"].str == "s1");
    assert(detail.object["extension_data"].type == JSONType.null_);
}
