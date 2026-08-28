import { Er } from "../core/Er";
import type { ModelInfo, ReasoningMode } from "../transport/ChatTransport";
import type { UiText } from "./UiText";

export function reasoningTooltip(
    text: UiText,
    modes: readonly ReasoningMode[],
    mode: ReasoningMode,
): string {
    const metric = isBinaryReasoning(modes)
        ? text.reasoningMetric
        : text.reasoningBudgetMetric;
    return `${metric}: ${reasoningValue(text, modes, mode)}`;
}

export function reasoningBadge(
    modes: readonly ReasoningMode[],
    mode: ReasoningMode,
): string {
    if (isBinaryReasoning(modes) || mode === "off") return "";
    switch (mode) {
        case "minimal": return "Min";
        case "low": return "L";
        case "medium": return "M";
        case "high": return "H";
        case "xhigh": return "XH";
        case "max": return "Max";
        default: return Er.internal("Unknown reasoning mode.");
    }
}

export function modelReasoningModes(
    models: readonly ModelInfo[],
    runtimeModelName: string,
): readonly ReasoningMode[] {
    const modelId = runtimeModelName.startsWith("pi:")
        ? runtimeModelName.slice(3)
        : runtimeModelName;
    return models.find(model => model.id === modelId)?.reasoningModes ?? [];
}

function reasoningValue(
    text: UiText,
    modes: readonly ReasoningMode[],
    mode: ReasoningMode,
): string {
    if (isBinaryReasoning(modes) && mode !== "off") return text.reasoningBudgetOn;
    switch (mode) {
        case "off": return text.reasoningBudgetOff;
        case "minimal": return text.reasoningBudgetMinimal;
        case "low": return text.reasoningBudgetLow;
        case "medium": return text.reasoningBudgetMedium;
        case "high": return text.reasoningBudgetHigh;
        case "xhigh": return text.reasoningBudgetXHigh;
        case "max": return text.reasoningBudgetMax;
        default: return Er.internal("Unknown reasoning mode.");
    }
}

function isBinaryReasoning(modes: readonly ReasoningMode[]): boolean {
    return modes.length === 2 && modes.includes("off");
}
