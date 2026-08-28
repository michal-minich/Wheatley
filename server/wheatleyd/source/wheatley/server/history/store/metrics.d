module wheatley.server.history.store.metrics;

import std.algorithm : canFind;
import std.array : appender;
import std.exception : enforce;
import std.file : exists, readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.history.rows.text_turn_record : TextTurnRecord;
import wheatley.common.api.reasoning : reasoningModeText;
import wheatley.server.history.store.paths : errorsJsonPath;
import wheatley.server.history.store.json : writeJsonFile, writeJsonFileAtomic;

package(wheatley.server.history) void attachUserAudioMetricsToTurn(
    string turnRoot,
    UserAudioArtifactRecord userAudio,
    long attachAudioMs,
)
{
    auto path = buildPath(turnRoot, "turn.json");
    if (!exists(path)) return;

    auto payload = parseJSON(readText(path));
    ensureObjectField(payload, "metrics");
    ensureObjectField(payload.object["metrics"], "audio");
    ensureObjectField(payload.object["metrics"], "storage");

    if (userAudio.hasDuration && ("accepted_seconds" in payload.object["metrics"].object["audio"].object) is null) {
        payload.object["metrics"].object["audio"].object["accepted_seconds"] =
            parseJSON(format!"%.3f"(userAudio.durationSeconds));
    }
    if (userAudio.hasOpusEncodeMs) {
        payload.object["metrics"].object["audio"].object["opus_encode_ms"] =
            JSONValue(userAudio.opusEncodeMs);
    }
    payload.object["metrics"].object["storage"].object["attach_audio_ms"] =
        JSONValue(attachAudioMs);

    writeJsonFile(path, payload.toString());
}

package(wheatley.server.history) void mergeAllowedClientMetrics(
    ref JSONValue payload,
    JSONValue incomingMetrics,
)
{
    Json.object(incomingMetrics);
    ensureObjectField(payload, "metrics");
    mergeAllowedClientMetricGroup(
        payload.object["metrics"],
        incomingMetrics,
        "audio",
        [
            "client_audio_bytes",
            "client_sent_bytes",
            "client_frames_sent",
            "client_encode_ms",
            "client_encode_realtime_ratio",
            "client_send_ms",
            "client_max_send_backlog_ms",
            "client_audio_format",
        ],
    );
    mergeAllowedClientMetricGroup(
        payload.object["metrics"],
        incomingMetrics,
        "user",
        ["total_ms"],
    );
    mergeAllowedClientMetricGroup(
        payload.object["metrics"],
        incomingMetrics,
        "tts",
        ["model", "first_audio_ms", "synthesis_ms", "chunks", "spoken_audio_seconds"],
    );
    mergeAllowedClientMetricGroup(
        payload.object["metrics"],
        incomingMetrics,
        "turn",
        ["endpoint_to_first_spoken_audio_ms"],
    );
}

package(wheatley.server.history) void writeTurnJson(TextTurnRecord turn, string turnRoot)
{
    auto metricsJson = turn.metricsJson.length
        ? preserveExistingReadyMetrics(turnRoot, jsonObjectRaw(turn.metricsJson))
        : "{}";
    writeJsonFileAtomic(buildPath(turnRoot, "turn.json"), jsonObject([
        jsonStringField("source", turn.source),
        turn.source == "scheduled_task"
            ? jsonLongField("scheduled_task_trigger_call_index", 0)
            : "",
        jsonStringField("status", turn.status),
        turn.submissionId.length ? jsonStringField("submission_id", turn.submissionId) : "",
        turn.executionId.length ? jsonStringField("execution_id", turn.executionId) : "",
        turn.submissionJson.length
            ? jsonRawField("submission", jsonObjectRaw(turn.submissionJson))
            : "",
        jsonBoolField("user_audio_required", turn.userAudioRequired),
        turn.hasUserImage ? jsonRawField("user_image", jsonObject([
            jsonStringField("filename", turn.userImage.filename),
            jsonStringField("media_type", turn.userImage.mediaType),
            jsonLongField("bytes", cast(long) turn.userImage.bytes),
        ])) : "",
        jsonStringField("reasoning_mode", reasoningModeText(turn.reasoningMode)),
        jsonStringField("completed_at", turn.completedAt),
        turn.hasPiExitStatus && turn.piExitStatus != 0
            ? jsonLongField("pi_exit_status", turn.piExitStatus)
            : "",
        jsonRawField("metrics", metricsJson),
    ]));
}

package(wheatley.server.history) void writeSessionAutoMemoryRequestJson(
    string turnRoot,
    long sessionCount,
    long messageCount,
    long inputChars,
)
{
    writeJsonFile(buildPath(turnRoot, "turn.json"), jsonObject([
        jsonStringField("source", "memory_consolidation"),
        jsonStringField("reasoning_mode", "off"),
        jsonRawField("metrics", jsonObject([
            jsonRawField("memory", jsonObject([
                jsonLongField("sessions", sessionCount),
                jsonLongField("user_messages", messageCount),
                jsonLongField("input_chars", inputChars),
            ])),
        ])),
    ]));
}

package(wheatley.server.history) void writeSessionAutoMemoryTurnJson(
    string turnRoot,
    string completedAt,
    long sessionCount,
    long messageCount,
    long inputChars,
    long outputChars,
    string llmMetricsJson,
)
{
    writeJsonFile(buildPath(turnRoot, "turn.json"), jsonObject([
        jsonStringField("source", "memory_consolidation"),
        jsonStringField("reasoning_mode", "off"),
        jsonStringField("completed_at", completedAt),
        jsonRawField("metrics", jsonObject([
            jsonRawField("memory", jsonObject([
                jsonLongField("sessions", sessionCount),
                jsonLongField("user_messages", messageCount),
                jsonLongField("input_chars", inputChars),
                jsonLongField("output_chars", outputChars),
            ])),
            llmMetricsJson.length ? jsonRawField("llm", jsonObjectRaw(llmMetricsJson)) : "",
        ])),
    ]));
}

package(wheatley.server.history) void writeSessionAutoMemoryFailureJson(
    string turnRoot,
    string completedAt,
    long sessionCount,
    long messageCount,
    long inputChars,
    string llmMetricsJson,
    string errorMessage,
)
{
    writeJsonFile(buildPath(turnRoot, "turn.json"), jsonObject([
        jsonStringField("source", "memory_consolidation"),
        jsonStringField("reasoning_mode", "off"),
        jsonStringField("completed_at", completedAt),
        jsonRawField("metrics", jsonObject([
            jsonRawField("memory", jsonObject([
                jsonLongField("sessions", sessionCount),
                jsonLongField("user_messages", messageCount),
                jsonLongField("input_chars", inputChars),
            ])),
            llmMetricsJson.length ? jsonRawField("llm", jsonObjectRaw(llmMetricsJson)) : "",
        ])),
    ]));
    writeJsonFile(errorsJsonPath(turnRoot), jsonObject([
        jsonRawField("errors", "[" ~ jsonObject([
            jsonStringField("stage", "memory_consolidation"),
            jsonStringField("recorded_at", completedAt),
            jsonStringField("message", errorMessage),
        ]) ~ "]"),
    ]));
}

package(wheatley.server.history) void appendTurnError(string turnRoot, string errorJson)
{
    auto output = appender!string;
    output.put(`{"errors":[`);
    auto path = errorsJsonPath(turnRoot);
    bool hasItem;
    if (exists(path)) {
        auto payload = Json.parse(readText(path));
        if ("errors" in payload.value.objectNoRef) {
            foreach (item; payload.array("errors").value.array) {
                if (hasItem) output.put(",");
                output.put(item.toString());
                hasItem = true;
            }
        }
    }
    if (hasItem) output.put(",");
    output.put(errorJson);
    output.put("]}");
    writeJsonFile(path, output.data);
}

package(wheatley.server.history) string turnMetricsJson(string turnRoot)
{
    auto path = buildPath(turnRoot, "turn.json");
    if (!exists(path)) return "{}";
    return Json.parse(readText(path)).object("metrics").value.toString();
}

package(wheatley.server.history) void ensureObjectField(ref JSONValue value, string name)
{
    Json.object(value);
    auto existing = name in value.object;
    if (existing is null) {
        value.object[name] = parseJSON("{}");
        return;
    }
    Json.object(*existing, name);
}

private void mergeAllowedClientMetricGroup(
    ref JSONValue targetMetrics,
    JSONValue incomingMetrics,
    string groupName,
    string[] allowedFields,
)
{
    auto group = groupName in incomingMetrics.object;
    if (group is null) return;
    Json.object(*group, groupName);

    ensureObjectField(targetMetrics, groupName);
    foreach (name, value; group.objectNoRef) {
        if (!allowedFields.canFind(name)) continue;
        enforce(
            isClientMetricScalar(value),
            "Client metric " ~ groupName ~ "." ~ name ~ " must be a string or number",
        );
        targetMetrics.object[groupName].object[name] = value;
    }
}

private bool isClientMetricScalar(JSONValue value)
{
    final switch (value.type) {
        case JSONType.string:
        case JSONType.integer:
        case JSONType.uinteger:
        case JSONType.float_:
            return true;
        case JSONType.object:
        case JSONType.array:
        case JSONType.true_:
        case JSONType.false_:
        case JSONType.null_:
            return false;
    }
}

private string preserveExistingReadyMetrics(string turnRoot, string metricsJson)
{
    auto path = buildPath(turnRoot, "turn.json");
    if (!exists(path) || !metricsJson.length) return metricsJson;
    auto payload = Json.parse(readText(path));
    auto existingMetrics = payload.object("metrics");

    auto metrics = parseJSON(metricsJson);
    preserveExistingMetricGroup(metrics, existingMetrics.value, "audio");
    preserveExistingMetricGroup(metrics, existingMetrics.value, "storage");
    return metrics.toString();
}

private void preserveExistingMetricGroup(ref JSONValue metrics, JSONValue existingMetrics, string groupName)
{
    Json.object(existingMetrics);
    auto existingGroup = groupName in existingMetrics.object;
    if (existingGroup is null) return;
    enforce(existingGroup.type == JSONType.object, "JSON " ~ groupName);

    ensureObjectField(metrics, groupName);
    foreach (name, value; existingGroup.objectNoRef) {
        if ((name in metrics.object[groupName].object) is null) {
            metrics.object[groupName].object[name] = value;
        }
    }
}
