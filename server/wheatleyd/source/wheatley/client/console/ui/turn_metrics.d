module wheatley.client.console.ui.turn_metrics;

import std.conv : to;
import std.format : format;
import std.string : replace;

import wheatley.common.api.text_turn : TextTurnMetrics;

string compactConsoleDuration(long durationMs)
{
    auto milliseconds = durationMs < 0 ? 0 : durationMs;
    if (milliseconds < 1_000) return milliseconds.to!string ~ "ms";

    auto seconds = milliseconds / 1_000;
    if (seconds < 60) {
        if (milliseconds < 10_000) {
            auto value = format!"%.1f"(cast(double) milliseconds / 1_000.0);
            if (value[$ - 2 .. $] == ".0") value = value[0 .. $ - 2];
            return value ~ "s";
        }
        return seconds.to!string ~ "s";
    }

    auto minutes = seconds / 60;
    auto remainingSeconds = seconds % 60;
    if (minutes < 60)
        return minutes.to!string ~ "min " ~ remainingSeconds.to!string ~ "s";
    auto hours = minutes / 60;
    auto remainingMinutes = minutes % 60;
    return hours.to!string ~ "h " ~ remainingMinutes.to!string ~ "min";
}

string consoleTurnMetricsText(TextTurnMetrics metrics, string language)
{
    if (metrics.contextTokens < 0 || metrics.contextWindowTokens <= 0
        || metrics.outputTokens < 0 || metrics.generationMs <= 0
        || metrics.durationMs < 0) return "";

    auto context = tokenK(metrics.contextTokens);
    auto window = tokenK(metrics.contextWindowTokens);
    auto percent = (metrics.contextTokens * 100 + metrics.contextWindowTokens / 2)
        / metrics.contextWindowTokens;
    auto rate = format!"%.1f"(
        cast(double) metrics.outputTokens / (cast(double) metrics.generationMs / 1_000.0),
    );
    auto localizedDecimal = language == "sk" || language == "de";
    if (localizedDecimal) rate = rate.replace(".", ",");
    auto contextLabel = language == "en" ? "Context " : "Kontext ";
    auto tokenLabel = language == "sk" ? " tokenov · " : " tokens · ";
    auto rateLabel = language == "sk" ? " tokenov/s · " : " tokens/s · ";
    if (language == "de") {
        tokenLabel = " Token · ";
        rateLabel = " Token/s · ";
    }
    return contextLabel
        ~ context ~ " / " ~ window ~ " (" ~ percent.to!string ~ "%) · "
        ~ metrics.outputTokens.to!string ~ tokenLabel
        ~ rate ~ rateLabel
        ~ compactConsoleDuration(metrics.durationMs);
}

private string tokenK(long tokens)
{
    return ((tokens + 512) / 1_024).to!string ~ "K";
}

unittest
{
    assert(compactConsoleDuration(340) == "340ms");
    assert(compactConsoleDuration(9_600) == "9.6s");
    assert(compactConsoleDuration(206_000) == "3min 26s");
    auto metrics = TextTurnMetrics();
    metrics.durationMs = 206_000;
    metrics.generationMs = 88_229;
    metrics.outputTokens = 847;
    metrics.contextTokens = 43_008;
    metrics.contextWindowTokens = 131_072;
    assert(consoleTurnMetricsText(metrics, "en")
        == "Context 42K / 128K (33%) · 847 tokens · 9.6 tokens/s · 3min 26s");
    assert(consoleTurnMetricsText(metrics, "sk")
        == "Kontext 42K / 128K (33%) · 847 tokenov · 9,6 tokenov/s · 3min 26s");
    assert(consoleTurnMetricsText(metrics, "de")
        == "Kontext 42K / 128K (33%) · 847 Token · 9,6 Token/s · 3min 26s");
}
