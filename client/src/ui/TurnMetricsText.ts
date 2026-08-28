import type { TextTurnMetrics } from "../transport/ChatTransport";
import { formatDetailedDuration } from "./LocalDateTime";
import type { UiText } from "./UiText";

export function turnMetricsTooltip(
    metrics: TextTurnMetrics | undefined,
    text: UiText,
    includeDuration = false,
): readonly string[] {
    if (metrics === undefined) return [];
    const result: string[] = [];
    if (includeDuration && metrics.durationMs !== undefined)
        result.push(`${text.turnDurationMetric}: ${formatDetailedDuration(metrics.durationMs)}`);
    if (metrics.timeToFirstTokenMs !== undefined) {
        result.push(
            `${text.firstTokenMetric}: ${formatDetailedDuration(metrics.timeToFirstTokenMs)}`,
        );
    }
    if (metrics.inputTokens !== undefined) {
        const percent = metrics.contextWindowTokens === undefined
            ? ""
            : ` ${formatPercent(metrics.inputTokens, metrics.contextWindowTokens)}`;
        result.push(`${text.inputTokensMetric}: ${formatTokens(metrics.inputTokens)}`
            + ` (${formatCompactTokens(metrics.inputTokens)})${percent}`);
    }
    if (metrics.outputTokens !== undefined) {
        const percent = metrics.contextWindowTokens === undefined
            ? ""
            : ` ${formatPercent(metrics.outputTokens, metrics.contextWindowTokens)}`;
        result.push(`${text.outputTokensMetric}: ${formatTokens(metrics.outputTokens)}`
            + ` (${formatCompactTokens(metrics.outputTokens)})${percent}`);
    }
    if (metrics.contextTokens !== undefined) {
        const window = metrics.contextWindowTokens;
        const percent = window === undefined
            ? ""
            : ` ${formatPercent(metrics.contextTokens, window)}`;
        result.push(`${text.usedContextMetric}: ${formatTokens(metrics.contextTokens)}`
            + ` (${formatCompactTokens(metrics.contextTokens)})${percent}`);
    }
    if (metrics.contextWindowTokens !== undefined)
        result.push(`${text.availableContextMetric}: `
            + `${formatTokens(metrics.contextWindowTokens)} `
            + `(${formatCompactTokens(metrics.contextWindowTokens)})`);
    if (metrics.cacheReadTokens !== undefined && metrics.cacheReadTokens > 0)
        result.push(`${text.cacheReadTokensMetric}: ${formatTokens(metrics.cacheReadTokens)}`);
    if (metrics.reasoningTokens !== undefined && metrics.reasoningTokens > 0)
        result.push(`${text.reasoningTokensMetric}: ${formatTokens(metrics.reasoningTokens)}`
            + ` ${text.tokensUnit}`);
    if (
        metrics.outputTokens !== undefined
        && metrics.outputTokens > 0
        && metrics.generationMs !== undefined
        && metrics.generationMs > 0
    ) {
        const rate = metrics.outputTokens / (metrics.generationMs / 1_000);
        result.push(`${text.generationRateMetric}: ${rate.toLocaleString(undefined, {
            maximumFractionDigits: 1,
            useGrouping: false,
        })} ${text.tokensPerSecondUnit}`);
    }
    return result;
}

function formatTokens(value: number): string {
    return value.toString();
}

function formatCompactTokens(value: number): string {
    return `${Math.round(value / 1_024)}K`;
}

function formatPercent(value: number, total: number): string {
    return `${Math.round(value / total * 100)}%`;
}
