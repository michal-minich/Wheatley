import type { ChatLanguage } from "../chat/Language";
import { Er } from "../core/Er";
import { accentText } from "../ui/UiText";

interface AccentDefinition<Id extends string> {
    readonly id: Id;
    readonly color: number;
    readonly background: number;
}

function defineAccent<const Id extends string>(
    id: Id,
    color: number,
    background: number,
): AccentDefinition<Id> {
    return { id, color, background };
}

export const accents = [
    defineAccent("slate", 0x8ea4c4, 0x243040),
    defineAccent("sky", 0x6eb0d4, 0x1f3340),
    defineAccent("teal", 0x5eb8a8, 0x1d3534),
    defineAccent("mint", 0x6cc49a, 0x1f3830),
    defineAccent("sage", 0x8fbf7a, 0x28362a),
    defineAccent("olive", 0xa8b86a, 0x313628),
    defineAccent("gold", 0xd0b45c, 0x3a3420),
    defineAccent("amber", 0xddb05a, 0x3a3020),
    defineAccent("orange", 0xd99662, 0x3a2c22),
    defineAccent("coral", 0xd8847c, 0x3a2828),
    defineAccent("rose", 0xd87a92, 0x3a2430),
    defineAccent("pink", 0xcc82a8, 0x352434),
    defineAccent("magenta", 0xb884c0, 0x302438),
    defineAccent("purple", 0xa488dc, 0x2a2438),
    defineAccent("violet", 0x8c8ee0, 0x26283a),
    defineAccent("indigo", 0x7a94dc, 0x242a3a),
    defineAccent("blue", 0x6a9ee0, 0x22303c),
    defineAccent("cyan", 0x5ab0cc, 0x1f3338),
    defineAccent("steel", 0x9aa8b8, 0x2a3038),
    defineAccent("pearl", 0xb4c0d0, 0x2c323c),
    defineAccent("sand", 0xc0b498, 0x343028),
    defineAccent("clay", 0xb89882, 0x342c28),
    defineAccent("copper", 0xc08870, 0x382a24),
    defineAccent("wine", 0xa87080, 0x34242c),
] as const;

export type AccentId = typeof accents[number]["id"];
export type Accent = typeof accents[number];

export function accent(id: AccentId): Accent {
    return accents.find(item => item.id === id) ?? Er.internal(`Unknown accent ${id}.`);
}

export function findAccentId(value: unknown): AccentId | undefined {
    return typeof value === "string"
        ? accents.find(item => item.id === value)?.id
        : undefined;
}

export function accentLabel(value: Accent, language: ChatLanguage): string {
    return accentText(language, value.id);
}

export function cssColor(value: number): string {
    return `#${value.toString(16).padStart(6, "0")}`;
}
