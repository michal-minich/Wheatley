module wheatley.server.history.store.turn_metrics;

import std.datetime : SysTime;
import std.json : JSONType, JSONValue, parseJSON;

import wheatley.common.api.text_turn : TextTurnMetrics;
import wheatley.server.history.store.json : objectField;

TextTurnMetrics inspectionMetrics(
    string metricsJson,
    string startedAt,
    string completedAt,
)
{
    auto metrics = metricsJson.length ? parseJSON(metricsJson) : JSONValue(null);
    auto llm = objectField(metrics, "llm");
    auto turn = objectField(metrics, "turn");
    auto durationMs = optionalLong(turn, "total_ms");
    if (durationMs < 0) durationMs = timestampDurationMs(startedAt, completedAt);
    return TextTurnMetrics(
        durationMs,
        optionalLong(llm, "ttft_ms"),
        optionalLong(llm, "generation_ms"),
        optionalLong(llm, "input_tokens"),
        optionalLong(llm, "output_tokens"),
        optionalLong(llm, "cache_read_tokens"),
        optionalLong(llm, "cache_write_tokens"),
        optionalLong(llm, "reasoning_tokens"),
        optionalLong(llm, "total_tokens"),
        optionalLong(llm, "context_tokens"),
        optionalLong(llm, "context_window_tokens"),
    );
}

private long optionalLong(JSONValue value, string name)
{
    if (value.type != JSONType.object) return -1;
    auto field = name in value.objectNoRef;
    if (field is null) return -1;
    if (field.type == JSONType.integer && field.integer >= 0) return field.integer;
    if (field.type == JSONType.uinteger && field.uinteger <= cast(ulong) long.max)
        return cast(long) field.uinteger;
    return -1;
}

private long timestampDurationMs(string startedAt, string completedAt)
{
    if (!startedAt.length || !completedAt.length) return -1;
    try {
        auto duration = SysTime.fromISOExtString(completedAt)
            - SysTime.fromISOExtString(startedAt);
        return duration.total!"msecs" >= 0 ? duration.total!"msecs" : -1;
    } catch (Exception) {
        return -1;
    }
}

unittest
{
    auto metrics = inspectionMetrics(
        `{"llm":{"input_tokens":100,"output_tokens":20,"ttft_ms":75,"generation_ms":400,"context_tokens":90,"context_window_tokens":1000},"turn":{"total_ms":500}}`,
        "",
        "",
    );
    assert(metrics.durationMs == 500);
    assert(metrics.inputTokens == 100);
    assert(metrics.outputTokens == 20);
    assert(metrics.cacheReadTokens == -1);
}
