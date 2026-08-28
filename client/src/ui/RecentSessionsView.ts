import type { ChatSessionSnapshot } from "../chat/ChatSession";
import type { ChatLanguage } from "../chat/Language";
import type { RecentSessionSummary } from "../transport/ChatTransport";
import { formatLocalDateTime } from "./LocalDateTime";
import { H } from "./h";
import { icon } from "./Icons";
import {
    matchesRecentChatFilter,
    recentChatFilterOptions,
    type RecentChatFilter,
} from "./RecentChatFilter";
import { type UiText, uiText } from "./UiText";
import { chatPath, isUnmodifiedLeftClick } from "../app/ChatRoute";

export interface RecentSessionsViewHandlers {
    readonly onOpen: (session: RecentSessionSummary) => void;
}

export class RecentSessionsView {
    readonly element: HTMLElement;
    readonly #list: HTMLElement;
    readonly #handlers: RecentSessionsViewHandlers;
    #sessions: readonly RecentSessionSummary[] = [];
    #currentSessionId: string | undefined;
    #profileId = "";
    #language: ChatLanguage = "en";
    #disabled = false;
    #query = "";
    #filter: RecentChatFilter = "all";

    constructor(handlers: RecentSessionsViewHandlers) {
        this.#handlers = handlers;
        this.#list = H.div().class("recent-list").el();
        this.element = H.section()
            .class("recent-sessions")
            .append(this.#list)
            .el();
    }

    render(snapshot: ChatSessionSnapshot): void {
        this.#sessions = snapshot.recentSessions;
        this.#currentSessionId = snapshot.currentSessionId;
        this.#profileId = snapshot.profileId;
        this.#language = snapshot.language;
        this.#disabled = !snapshot.canSwitchChats;
        const text = uiText(snapshot.language);
        this.element.setAttribute("aria-label", text.recentChats);
        this.element.setAttribute("aria-busy", String(snapshot.recentSessionsLoading));
        this.#renderRows();
    }

    setSearch(value: string): void {
        this.#query = value.trim().toLocaleLowerCase();
        this.#renderRows();
    }

    clearSearch(): void {
        this.setSearch("");
    }

    setFilter(filter: RecentChatFilter): void {
        if (this.#filter === filter)
            return;
        this.#filter = filter;
        this.#renderRows();
    }

    resetFilter(): void {
        this.setFilter("all");
    }

    #renderRows(): void {
        const sessions = this.#sessions.filter(session =>
            matchesRecentChatFilter(session, this.#filter)
            && (this.#query.length === 0
                || session.initialUserText.toLocaleLowerCase().includes(this.#query)));
        this.#list.replaceChildren(...sessions.map(session => this.#row(session)));
    }

    #row(session: RecentSessionSummary): HTMLAnchorElement {
        const current = session.sessionId === this.#currentSessionId;
        const content = H.span().class("recent-row-content").el();
        if (current || session.processing) {
            const currentText = uiText(this.#language).current;
            const marker = H.span().class("recent-marker").attr("aria-hidden", "true").el();
            if (session.processing)
                marker.append(H.img().class("recent-processing")
                    .attr("src", "/icons/session-processing.svg").attr("alt", "").el());
            if (current)
                marker.append(H.span().class("recent-current").attr("title", currentText).el());
            content.append(marker);
        }
        content.append(H.span().class("recent-prompt").text(session.initialUserText).el());
        const text = uiText(this.#language);
        const activity = H.span().class("recent-activity").el();
        for (const option of recentChatFilterOptions) {
            if (option.id === "all" || !matchesRecentChatFilter(session, option.id))
                continue;
            activity.append(recentActivityIcon(option.icon, activityTitle(text, option.id)));
        }
        if (activity.childElementCount > 0)
            content.append(activity);
        const row = H.a()
            .class("recent-row")
            .attr("href", chatPath(this.#profileId, session.sessionId))
            .append(
                content,
                H.span()
                    .class("recent-date")
                    .text(formatLocalDateTime(session.startedAt))
                    .el(),
            )
            .on("click", event => {
                if (!isUnmodifiedLeftClick(event) || (this.#disabled && !current))
                    return;
                event.preventDefault();
                this.#handlers.onOpen(session);
            })
            .el();
        if (current) row.setAttribute("aria-current", "true");
        if (this.#disabled && !current) row.setAttribute("aria-disabled", "true");
        return row;
    }
}

function recentActivityIcon(source: string, title: string): HTMLImageElement {
    const result = icon(source);
    result.classList.add("recent-activity-icon");
    result.title = title;
    return result;
}

function activityTitle(text: UiText, filter: Exclude<RecentChatFilter, "all">): string {
    switch (filter) {
        case "tool": return text.chatUsedTools;
        case "web": return text.chatUsedWebSearch;
        case "image": return text.chatGeneratedImage;
        case "scheduled": return text.chatHasScheduledTurn;
        case "compaction": return text.chatCompactedContext;
        case "screen": return text.chatUsedScreenCapture;
    }
}
