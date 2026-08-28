module wheatley.server.history.store.tool_json;

import std.array : appender;
import std.exception : enforce;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.history.store.json :
    jsonBool,
    jsonFieldJson,
    jsonLong,
    jsonText,
    objectField,
    preview;
import wheatley.server.history.store.paths : toolsJsonPath;
import wheatley.server.tools.types : ExecutedTool, ToolResult;

enum runtimeToolSchema = "wheatley.runtime_tools.v1";

package(wheatley.server.history) string runtimeToolsJson(ExecutedTool[] tools)
{
    auto output = appender!string;
    output.put(`{"schema":"wheatley.runtime_tools.v1","tools":[`);
    foreach (index, tool; tools) {
        if (index) output.put(",");
        output.put(jsonObject([
            jsonStringField("id", tool.eventId),
            jsonLongField("index", tool.callIndex),
            jsonStringField("name", tool.call.name),
            jsonStringField("source", tool.source),
            jsonStringField("started_at", tool.timestamp),
            jsonLongField("duration_ms", cast(long) (tool.durationSeconds * 1_000)),
            jsonBoolField("ok", tool.result.ok),
            jsonStringField("status", tool.status.length
                ? tool.status : tool.result.ok ? "succeeded" : "failed"),
            jsonRawField("args", toolArgsJson(tool.call.argumentsJson)),
            jsonRawField("result", runtimeToolResultJson(tool.result)),
        ]));
    }
    output.put("]}");
    return output.data;
}

package(wheatley.server.history) long toolEventCount(string turnRoot)
{
    auto path = toolsJsonPath(turnRoot);
    if (!exists(path)) return 0;
    auto payload = parseJSON(readText(path));
    return cast(long) turnToolArray(payload).array.length;
}

package(wheatley.server.history) JSONValue turnToolArray(JSONValue payload)
{
    auto json = Json.object(payload);
    enforce(json.text("schema") == runtimeToolSchema, "Unsupported turn tools schema");
    auto tools = json.array("tools");
    foreach (tool; tools.value.array) validateRuntimeTool(tool);
    return tools.value;
}

private void validateRuntimeTool(JSONValue tool)
{
    auto json = Json.object(tool);
    json.nonEmpty("id");
    json.nonEmpty("name");
    json.nonEmpty("source");
    json.nonEmpty("started_at");
    json.integer("index");
    json.integer("duration_ms");
    json.boolean("ok");
    if ("status" in json.value.objectNoRef)
        json.choice!("running", "succeeded", "failed")("status");
    json.object("args");
    json.object("result");
}

private string toolArgsJson(string argumentsJson)
{
    return jsonObjectRaw(argumentsJson);
}

private string runtimeToolResultJson(ToolResult result)
{
    auto content = parseJSON(jsonObjectRaw(result.contentJson));

    auto text = jsonText(content, "text");
    auto stdoutText = jsonText(content, "stdout");
    auto stderrText = jsonText(content, "stderr");

    auto truncated = jsonBool(content, "truncated");
    if (text.length > 65_536) {
        text = preview(text, 65_536);
        truncated = true;
    }
    if (stdoutText.length > 65_536) {
        stdoutText = preview(stdoutText, 65_536);
        truncated = true;
    }
    if (stderrText.length > 65_536) {
        stderrText = preview(stderrText, 65_536);
        truncated = true;
    }

    auto artifacts = jsonFieldJson(content, "artifacts", "[]");
    auto details = jsonFieldJson(content, "details", "null");
    if (!artifacts.length) artifacts = "[]";
    return jsonObject([
        jsonStringField("text", text),
        jsonLongField("exit_status", hasJsonField(content, "exit_status") ? jsonLong(content, "exit_status") : 0),
        jsonStringField("stdout", stdoutText),
        jsonStringField("stderr", stderrText),
        jsonRawField("artifacts", artifacts),
        jsonRawField("details", details.length ? details : "null"),
        jsonBoolField("truncated", truncated),
    ]);
}

private bool hasJsonField(JSONValue payload, string name)
{
    if (payload.type != JSONType.object) return false;
    return (name in payload.objectNoRef) !is null;
}

unittest
{
    auto legacy = parseJSON(`{
      "schema":"wheatley.runtime_tools.v1",
      "tools":[{
        "id":"legacy-tool","index":0,"name":"read_file","source":"legacy_runtime",
        "started_at":"2026-07-05T16:04:59Z","duration_ms":12,"ok":true,
        "args":{},"result":{"text":"done"}
      }]
    }`);
    assert(turnToolArray(legacy).array.length == 1);
}
