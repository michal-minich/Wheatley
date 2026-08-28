module wheatley.common.api.text_turn;

import std.exception : enforce;
import std.json : JSONValue;
import std.string : strip;
import std.uuid : randomUUID;

import wheatley.common.api.reasoning :
    ReasoningMode,
    reasoningModeText;
import wheatley.common.json.object :
    jsonArrayRaw,
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

struct TextTurnMetrics
{
    long durationMs = -1;
    long timeToFirstTokenMs = -1;
    long generationMs = -1;
    long inputTokens = -1;
    long outputTokens = -1;
    long cacheReadTokens = -1;
    long cacheWriteTokens = -1;
    long reasoningTokens = -1;
    long totalTokens = -1;
    long contextTokens = -1;
    long contextWindowTokens = -1;
}

struct TextTurnRequest
{
    string sessionId;
    string text;
    string submissionId;
    string deviceId;
    string language;
    string source;
    bool loadMemory;
    ReasoningMode reasoningMode;
    string model;
    long afterSequence;
}

struct TextTurnResponseTurn
{
    string turnId;
    string profileId;
    string deviceId;
    string source;
    string status;
    string startedAt;
    string completedAt;
    string modelName;
    string language;
    string userText;
    string assistantText;
    long audioCount;
    long artifactCount;
    long toolCount;
    TextTurnMetrics metrics;
}

struct TextTurnResponse
{
    TextTurnResponseTurn turn;
    bool stopped;
    string eventsJson;
}

TextTurnRequest textTurnRequestFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return TextTurnRequest(
        json.text("session_id"),
        json.text("text"),
        json.nonEmpty("submission_id"),
        json.text("device_id"),
        json.text("language"),
        json.text("source"),
        json.boolean("load_memory"),
        json.enumeration!ReasoningMode("reasoning_mode"),
        json.text("model"),
        json.nonNegativeInt("after_sequence"),
    );
}

string textTurnRequestJson(TextTurnRequest request)
{
    return jsonObject([
        jsonStringField("session_id", request.sessionId),
        jsonStringField("text", request.text),
        jsonStringField("submission_id", request.submissionId),
        jsonStringField("device_id", request.deviceId),
        jsonStringField("language", request.language),
        jsonStringField("source", request.source),
        jsonBoolField("load_memory", request.loadMemory),
        jsonStringField("reasoning_mode", reasoningModeText(request.reasoningMode)),
        jsonStringField("model", request.model),
        jsonLongField("after_sequence", request.afterSequence),
    ]);
}

TextTurnResponse textTurnResponseFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return TextTurnResponse(
        textTurnResponseTurnFromJson(json.object("turn")),
        json.boolean("stopped"),
        json.arrayRaw("events"),
    );
}

string textTurnResponseJson(TextTurnResponse response)
{
    return jsonObject([
        jsonRawField("turn", textTurnResponseTurnJson(response.turn)),
        jsonBoolField("stopped", response.stopped),
        jsonRawField("events", jsonArrayRaw(response.eventsJson)),
    ]);
}

string newSubmissionId(string prefix)
{
    auto clean = prefix.strip;
    enforce(clean.length, "Submission ID prefix is required");
    return clean ~ "-" ~ randomUUID().toString();
}

string textTurnSubmissionId(TextTurnRequest request)
{
    enforce(request.submissionId.length, "Submission ID is required");
    return request.submissionId;
}

string textTurnSource(TextTurnRequest request, string fallbackSource)
{
    return request.source.length ? request.source : fallbackSource;
}

private TextTurnResponseTurn textTurnResponseTurnFromJson(Json json)
{
    return TextTurnResponseTurn(
        json.text("turn_id"),
        json.text("profile_id"),
        json.text("device_id"),
        json.text("source"),
        json.text("status"),
        json.text("started_at"),
        json.text("completed_at"),
        json.text("model_name"),
        json.token("language"),
        json.text("user_text"),
        json.text("assistant_text"),
        json.integer("audio_count"),
        json.integer("artifact_count"),
        json.integer("tool_count"),
        optionalTextTurnMetrics(json),
    );
}

private string textTurnResponseTurnJson(TextTurnResponseTurn turn)
{
    return jsonObject([
        jsonStringField("turn_id", turn.turnId),
        jsonStringField("profile_id", turn.profileId),
        jsonStringField("device_id", turn.deviceId),
        jsonStringField("source", turn.source.length ? turn.source : "api_text"),
        jsonStringField("status", turn.status),
        jsonStringField("started_at", turn.startedAt),
        jsonStringField("completed_at", turn.completedAt),
        jsonStringField("model_name", turn.modelName),
        jsonStringField("language", turn.language),
        jsonStringField("user_text", turn.userText),
        jsonStringField("assistant_text", turn.assistantText),
        jsonLongField("audio_count", turn.audioCount),
        jsonLongField("artifact_count", turn.artifactCount),
        jsonLongField("tool_count", turn.toolCount),
        jsonRawField("metrics", textTurnMetricsJson(turn.metrics)),
    ]);
}

TextTurnMetrics textTurnMetricsFromJson(Json json)
{
    return TextTurnMetrics(
        optionalMetric(json, "duration_ms"),
        optionalMetric(json, "time_to_first_token_ms"),
        optionalMetric(json, "generation_ms"),
        optionalMetric(json, "input_tokens"),
        optionalMetric(json, "output_tokens"),
        optionalMetric(json, "cache_read_tokens"),
        optionalMetric(json, "cache_write_tokens"),
        optionalMetric(json, "reasoning_tokens"),
        optionalMetric(json, "total_tokens"),
        optionalMetric(json, "context_tokens"),
        optionalMetric(json, "context_window_tokens"),
    );
}

string textTurnMetricsJson(TextTurnMetrics metrics)
{
    return jsonObject([
        optionalMetricField("duration_ms", metrics.durationMs),
        optionalMetricField("time_to_first_token_ms", metrics.timeToFirstTokenMs),
        optionalMetricField("generation_ms", metrics.generationMs),
        optionalMetricField("input_tokens", metrics.inputTokens),
        optionalMetricField("output_tokens", metrics.outputTokens),
        optionalMetricField("cache_read_tokens", metrics.cacheReadTokens),
        optionalMetricField("cache_write_tokens", metrics.cacheWriteTokens),
        optionalMetricField("reasoning_tokens", metrics.reasoningTokens),
        optionalMetricField("total_tokens", metrics.totalTokens),
        optionalMetricField("context_tokens", metrics.contextTokens),
        optionalMetricField("context_window_tokens", metrics.contextWindowTokens),
    ]);
}

private long optionalMetric(Json json, string name)
{
    auto value = json.opt.integer(name, 0);
    return value.isNull ? -1 : value.get;
}

private string optionalMetricField(string name, long value)
{
    return value < 0 ? "" : jsonLongField(name, value);
}

private TextTurnMetrics optionalTextTurnMetrics(Json json)
{
    auto metrics = json.opt.object("metrics");
    return metrics.isNull ? TextTurnMetrics() : textTurnMetricsFromJson(metrics.get);
}

unittest
{
    import std.json : parseJSON;

    auto legacy = textTurnResponseFromJson(parseJSON(
        `{"turn":{"turn_id":"turn-1","profile_id":"tester","device_id":"web",`
        ~ `"source":"api_text","status":"completed",`
        ~ `"started_at":"2026-08-20T10:00:00Z",`
        ~ `"completed_at":"2026-08-20T10:00:01Z","model_name":"model",`
        ~ `"language":"en","user_text":"Hi","assistant_text":"Hello",`
        ~ `"audio_count":0,"artifact_count":0,"tool_count":0},`
        ~ `"stopped":false,"events":[]}`,
    ));
    assert(legacy.turn.metrics.durationMs == -1);

    legacy.turn.metrics = TextTurnMetrics(1_000, 100, 800, 20, 10);
    auto roundTrip = textTurnResponseFromJson(parseJSON(textTurnResponseJson(legacy)));
    assert(roundTrip.turn.metrics.durationMs == 1_000);
    assert(roundTrip.turn.metrics.inputTokens == 20);
}
