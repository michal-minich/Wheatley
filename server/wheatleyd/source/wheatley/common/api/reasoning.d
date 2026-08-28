module wheatley.common.api.reasoning;

import std.algorithm.searching : canFind;
import std.exception : enforce;

import wheatley.common.choice : requireEnum;
import wheatley.common.prompt_text : promptStartsWithThink;

enum ReasoningMode
{
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,
}

ReasoningMode parseReasoningMode(string value)
{
    return requireEnum!ReasoningMode(value);
}

string reasoningModeText(ReasoningMode mode)
{
    final switch (mode) {
        case ReasoningMode.off: return "off";
        case ReasoningMode.minimal: return "minimal";
        case ReasoningMode.low: return "low";
        case ReasoningMode.medium: return "medium";
        case ReasoningMode.high: return "high";
        case ReasoningMode.xhigh: return "xhigh";
        case ReasoningMode.max: return "max";
    }
}

string piThinkingLevel(ReasoningMode mode)
{
    return reasoningModeText(mode);
}

bool reasoningEnabled(ReasoningMode mode)
{
    return mode != ReasoningMode.off;
}

ReasoningMode nearestReasoningMode(ReasoningMode[] available, ReasoningMode requested)
{
    enforce(available.length, "Selected model has no reasoning modes");
    if (available.canFind(requested)) return requested;
    auto requestedRank = cast(int) requested;
    ReasoningMode best = available[0];
    auto bestDistance = int.max;
    foreach (candidate; available) {
        auto difference = cast(int) candidate - requestedRank;
        auto distance = difference < 0 ? -difference : difference;
        if (distance < bestDistance || (distance == bestDistance && candidate > best)) {
            best = candidate;
            bestDistance = distance;
        }
    }
    return best;
}

ReasoningMode turnReasoningMode(ReasoningMode preferred, string prompt)
{
    return promptStartsWithThink(prompt) ? ReasoningMode.max : preferred;
}

unittest
{
    assert(parseReasoningMode("off") == ReasoningMode.off);
    assert(parseReasoningMode("minimal") == ReasoningMode.minimal);
    assert(parseReasoningMode("low") == ReasoningMode.low);
    assert(parseReasoningMode("medium") == ReasoningMode.medium);
    assert(parseReasoningMode("high") == ReasoningMode.high);
    assert(parseReasoningMode("xhigh") == ReasoningMode.xhigh);
    assert(parseReasoningMode("max") == ReasoningMode.max);
    try {
        parseReasoningMode("maybe");
        assert(false);
    } catch (Exception) {
    }
    assert(turnReasoningMode(ReasoningMode.medium, "hello") == ReasoningMode.medium);
    assert(turnReasoningMode(ReasoningMode.off, "hello") == ReasoningMode.off);
    assert(turnReasoningMode(ReasoningMode.off, "think hello") == ReasoningMode.max);
    assert(nearestReasoningMode(
        [ReasoningMode.off, ReasoningMode.low, ReasoningMode.medium, ReasoningMode.xhigh],
        ReasoningMode.high,
    ) == ReasoningMode.xhigh);
    assert(nearestReasoningMode(
        [ReasoningMode.low, ReasoningMode.high],
        ReasoningMode.medium,
    ) == ReasoningMode.high);
}
