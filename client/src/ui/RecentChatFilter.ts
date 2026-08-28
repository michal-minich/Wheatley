import type { RecentSessionSummary } from "../transport/ChatTransport";

export const recentChatFilterOptions = [
    { id: "all", icon: "/icons/chat.svg" },
    { id: "tool", icon: "/icons/tool.svg" },
    { id: "web", icon: "/icons/globe.svg" },
    { id: "image", icon: "/icons/image.svg" },
    { id: "scheduled", icon: "/icons/bell.svg" },
    { id: "compaction", icon: "/icons/press.svg" },
    { id: "screen", icon: "/icons/camera.svg" },
] as const;

export type RecentChatFilter = (typeof recentChatFilterOptions)[number]["id"];

export function matchesRecentChatFilter(
    session: RecentSessionSummary,
    filter: RecentChatFilter,
): boolean {
    switch (filter) {
        case "all": return true;
        case "tool": return session.hasToolUse;
        case "web": return session.hasWebSearch;
        case "image": return session.hasGeneratedImage;
        case "scheduled": return session.hasScheduledTurn;
        case "compaction": return session.hasCompaction;
        case "screen": return session.hasScreenCapture;
    }
}
