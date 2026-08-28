module wheatley.server.turns.text.llm_metrics;

import core.time : MonoTime;

import std.format : format;
import std.utf : stride;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField;
import wheatley.server.turns.text.pi_events : PiEventCollector;

string llmMetricsJson(
    string prompt,
    string assistantText,
    PiEventCollector events,
    bool hasProcessStart,
    MonoTime processStarted,
    MonoTime processEnded,
    bool workerStarted = false,
    MonoTime workerStartedMono = MonoTime.init,
    MonoTime workerReadyMono = MonoTime.init,
    long contextWindowTokens = 0,
)
{
    if (!hasProcessStart) return jsonObject([
        jsonLongField("prompt_chars", utf8CharCount(prompt)),
        jsonLongField("response_chars", utf8CharCount(assistantText)),
    ]);

    auto piProcessMs = cast(long) (processEnded - processStarted).total!"msecs";
    auto hasGeneration = events.hasFirstAssistantDelta;
    auto generationMs = events.assistantGenerationDurationMs;
    auto responseChars = utf8CharCount(assistantText);
    auto compactionMetrics = events.compactionMetricsJson;
    auto usage = events.providerUsage;

    return jsonObject([
        jsonLongField("pi_process_ms", piProcessMs),
        jsonBoolField("pi_worker_started", workerStarted),
        workerStarted
            ? jsonLongField(
                "pi_worker_startup_ms",
                cast(long) (workerReadyMono - workerStartedMono).total!"msecs",
            )
            : "",
        hasGeneration
            ? jsonLongField("ttft_ms", cast(long) (events.firstAssistantDeltaMono - processStarted).total!"msecs")
            : "",
        hasGeneration && generationMs > 0 ? jsonLongField("generation_ms", generationMs) : "",
        jsonLongField("prompt_chars", utf8CharCount(prompt)),
        jsonLongField("response_chars", responseChars),
        hasGeneration && generationMs > 0
            ? jsonRawField("response_chars_per_second", format!"%.2f"(cast(double) responseChars / (cast(double) generationMs / 1_000.0)))
            : "",
        usage.available ? jsonLongField("input_tokens", usage.inputTokens) : "",
        usage.available ? jsonLongField("output_tokens", usage.outputTokens) : "",
        usage.cacheReadTokens > 0
            ? jsonLongField("cache_read_tokens", usage.cacheReadTokens) : "",
        usage.cacheWriteTokens > 0
            ? jsonLongField("cache_write_tokens", usage.cacheWriteTokens) : "",
        usage.reasoningTokens > 0
            ? jsonLongField("reasoning_tokens", usage.reasoningTokens) : "",
        usage.available ? jsonLongField("total_tokens", usage.totalTokens) : "",
        usage.latestContextTokens > 0
            ? jsonLongField("context_tokens", usage.latestContextTokens) : "",
        usage.outputTokens > 0 && generationMs > 0
            ? jsonRawField(
                "decode_tokens_per_second",
                format!"%.2f"(cast(double) usage.outputTokens
                    / (cast(double) generationMs / 1_000.0)),
            ) : "",
        compactionMetrics.length
            ? jsonRawField("compactions", compactionMetrics)
            : "",
        contextWindowTokens > 0
            ? jsonLongField("context_window_tokens", contextWindowTokens)
            : "",
    ]);
}

long utf8CharCount(string text)
{
    long count;
    for (size_t index; index < text.length; count++) {
        index += stride(text, index);
    }
    return count;
}
