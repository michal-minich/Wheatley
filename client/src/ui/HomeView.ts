import type { ChatSessionSnapshot } from "../chat/ChatSession";
import type { RecentSessionSummary } from "../transport/ChatTransport";
import { H } from "./h";
import type { RecentChatFilter } from "./RecentChatFilter";
import { RecentSessionsView } from "./RecentSessionsView";

export interface HomeViewHandlers {
    readonly onOpenRecent: (session: RecentSessionSummary) => void;
}

export class HomeView {
    readonly element: HTMLElement;
    readonly #recent: RecentSessionsView;
    readonly #error: HTMLElement;
    #errorVersion: number | undefined;

    constructor(handlers: HomeViewHandlers) {
        this.#recent = new RecentSessionsView({ onOpen: handlers.onOpenRecent });
        this.#error = H.div().class("chat-error", "home-error").el();
        this.element = H.section()
            .class("home-view")
            .append(this.#recent.element, this.#error)
            .el();
    }

    render(snapshot: ChatSessionSnapshot): void {
        this.#recent.render(snapshot);
        this.#error.textContent = snapshot.error ?? "";
        this.#error.hidden = snapshot.error === undefined;
        this.#restartErrorDismissal(snapshot.errorVersion, !this.#error.hidden);
    }

    clearSearch(): void {
        this.#recent.clearSearch();
    }

    setSearch(value: string): void {
        this.#recent.setSearch(value);
    }

    setFilter(filter: RecentChatFilter): void {
        this.#recent.setFilter(filter);
    }

    resetFilter(): void {
        this.#recent.resetFilter();
    }

    #restartErrorDismissal(version: number | undefined, visible: boolean): void {
        if (!visible) {
            this.#errorVersion = undefined;
            return;
        }
        if (this.#errorVersion === version)
            return;
        this.#errorVersion = version;
        this.#error.classList.remove("chat-error-dismissing");
        void this.#error.offsetWidth;
        this.#error.classList.add("chat-error-dismissing");
    }
}
