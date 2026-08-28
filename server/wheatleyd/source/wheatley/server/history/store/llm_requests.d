module wheatley.server.history.store.llm_requests;

import std.exception : enforce;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.history.store.json : writeJsonFileAtomic;
import wheatley.server.history.store.paths : llmRequestsJsonPath;

private enum llmRequestsSchema = "wheatley.llm_requests.v1";

struct LlmRequestCapture
{
    string capturedAt;
    string piVersion;
    JSONValue request;
}

package(wheatley.server.history) long appendLlmRequest(
    string turnRoot,
    LlmRequestCapture capture,
)
{
    enforce(capture.capturedAt.length, "LLM request capture time is required");
    enforce(capture.piVersion.length, "Pi version is required");
    enforce(capture.request.type == JSONType.object, "LLM request must be an object");

    auto path = llmRequestsJsonPath(turnRoot);
    JSONValue[] requests;
    if (exists(path)) {
        auto stored = Json.object(parseJSON(readText(path)));
        enforce(stored.text("schema") == llmRequestsSchema,
            "Unsupported LLM requests schema");
        requests = stored.array("requests").value.array.dup;
    }
    auto index = cast(long) requests.length + 1;
    requests ~= parseJSON(jsonObject([
        jsonLongField("index", index),
        jsonStringField("captured_at", capture.capturedAt),
        jsonStringField("pi_version", capture.piVersion),
        jsonRawField("request", capture.request.toString()),
    ]));
    writeJsonFileAtomic(path, jsonObject([
        jsonStringField("schema", llmRequestsSchema),
        jsonRawField("requests", JSONValue(requests).toString()),
    ]));
    return index;
}

package(wheatley.server.history) JSONValue loadLlmRequests(string turnRoot)
{
    auto path = llmRequestsJsonPath(turnRoot);
    if (!exists(path)) return JSONValue(null);
    auto stored = Json.object(parseJSON(readText(path)));
    enforce(stored.text("schema") == llmRequestsSchema,
        "Unsupported LLM requests schema");
    stored.array("requests");
    return stored.value;
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-llm-requests-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    assert(appendLlmRequest(root, LlmRequestCapture(
        "2026-08-27T13:36:02Z",
        "0.83.0",
        parseJSON(`{"model":"ornith","messages":[{"role":"developer","content":"Pi\n\nWheatley"}]}`),
    )) == 1);
    assert(appendLlmRequest(root, LlmRequestCapture(
        "2026-08-27T13:36:06Z",
        "0.83.0",
        parseJSON(`{"model":"ornith","messages":[{"role":"tool","content":"done"}]}`),
    )) == 2);
    auto stored = loadLlmRequests(root);
    assert(stored.object["requests"].array.length == 2);
    assert(stored.object["requests"].array[0].object["request"]
        .object["messages"].array[0].object["content"].str == "Pi\n\nWheatley");
}
