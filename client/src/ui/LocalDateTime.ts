export function formatLocalDateTime(timestamp: string): string {
    const value = new Date(timestamp);
    const day = value.getDate().toString().padStart(2, "0");
    const month = (value.getMonth() + 1).toString().padStart(2, "0");
    const hours = value.getHours().toString().padStart(2, "0");
    const minutes = value.getMinutes().toString().padStart(2, "0");
    return `${day}.${month}.${value.getFullYear()} ${hours}:${minutes}`;
}

export function formatRelativeTime(timestamp: string, now = Date.now()): string {
    const value = new Date(timestamp).valueOf();
    if (Number.isNaN(value)) return timestamp;

    let seconds = Math.max(0, Math.floor((now - value) / 1_000));
    const parts: string[] = [];
    for (const unit of relativeTimeUnits) {
        const amount = Math.floor(seconds / unit.seconds);
        if (amount === 0 && parts.length === 0) continue;
        if (amount > 0) parts.push(`${amount}${unit.label}`);
        seconds %= unit.seconds;
        if (parts.length === 2) break;
    }
    return parts.length === 0 ? "0s" : parts.join(" ");
}

/** Compact elapsed time shared by chat activity, transcript tooltips, and
 * detail dialogs. Durations intentionally stop after two non-zero units. */
export function formatCompactDuration(durationMs: number): string {
    const milliseconds = Math.max(0, Math.floor(durationMs));
    if (milliseconds < 1_000) return `${milliseconds}ms`;
    if (milliseconds < 10_000) {
        const seconds = (milliseconds / 1_000).toFixed(1).replace(/\.0$/u, "");
        return `${seconds}s`;
    }
    let remaining = Math.floor(milliseconds / 1_000);
    const parts: string[] = [];
    for (const unit of durationUnits) {
        const amount = Math.floor(remaining / unit.seconds);
        if (amount === 0) continue;
        parts.push(`${amount}${unit.label}`);
        remaining %= unit.seconds;
        if (parts.length === 2) break;
    }
    return parts.length === 0 ? "0s" : parts.join(" ");
}

export function formatDetailedDuration(durationMs: number): string {
    let remaining = Math.max(0, Math.floor(durationMs));
    if (remaining < 1_000) return `${remaining}ms`;
    const parts: string[] = [];
    for (const unit of detailedDurationUnits) {
        const amount = Math.floor(remaining / unit.milliseconds);
        if (amount > 0) parts.push(`${amount}${unit.label}`);
        remaining %= unit.milliseconds;
    }
    return parts.join(" ");
}

interface RelativeTimeUnit {
    readonly label: string;
    readonly seconds: number;
}

const relativeTimeUnits: readonly RelativeTimeUnit[] = [
    { label: "y", seconds: 365 * 24 * 60 * 60 },
    { label: "m", seconds: 30 * 24 * 60 * 60 },
    { label: "w", seconds: 7 * 24 * 60 * 60 },
    { label: "d", seconds: 24 * 60 * 60 },
    { label: "h", seconds: 60 * 60 },
    { label: "min", seconds: 60 },
    { label: "s", seconds: 1 },
];

const durationUnits: readonly RelativeTimeUnit[] = [
    { label: "d", seconds: 24 * 60 * 60 },
    { label: "h", seconds: 60 * 60 },
    { label: "min", seconds: 60 },
    { label: "s", seconds: 1 },
];

interface DetailedDurationUnit {
    readonly label: string;
    readonly milliseconds: number;
}

const detailedDurationUnits: readonly DetailedDurationUnit[] = [
    { label: "d", milliseconds: 24 * 60 * 60 * 1_000 },
    { label: "h", milliseconds: 60 * 60 * 1_000 },
    { label: "min", milliseconds: 60 * 1_000 },
    { label: "s", milliseconds: 1_000 },
    { label: "ms", milliseconds: 1 },
];
