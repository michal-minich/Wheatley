import type { ChatLanguage } from "../chat/Language";
import { H } from "./h";
import { icon } from "./Icons";
import { menuIcon, MenuItemButton, PopupMenu } from "./PopupMenu";
import {
    recentChatFilterOptions,
    type RecentChatFilter,
} from "./RecentChatFilter";
import { type UiText, uiText } from "./UiText";

export interface RecentChatFilterMenuHandlers {
    readonly onChange: (filter: RecentChatFilter) => void;
}

export class RecentChatFilterMenu {
    readonly element: HTMLElement;
    readonly #handlers: RecentChatFilterMenuHandlers;
    readonly #menu: PopupMenu;
    readonly #items = new Map<RecentChatFilter, MenuItemButton>();
    readonly #hoverLabel: HTMLElement;
    #filter: RecentChatFilter = "all";
    #language: ChatLanguage;

    constructor(handlers: RecentChatFilterMenuHandlers, language: ChatLanguage) {
        this.#handlers = handlers;
        this.#language = language;
        const grid = H.div().class("popup-menu-items", "recent-filter-items").el();
        this.#hoverLabel = H.div().class("recent-filter-hover-label").el();
        for (const option of recentChatFilterOptions) {
            const item = new MenuItemButton("menuitemradio", () => this.#select(option.id));
            item.setDecorator(menuIcon(option.icon));
            item.element.addEventListener("mouseenter", () => {
                this.#hoverLabel.textContent = filterLabel(uiText(this.#language), option.id);
            });
            item.element.addEventListener("mouseleave", () => this.#renderHoverLabel());
            this.#items.set(option.id, item);
            grid.append(item.element);
        }
        grid.append(H.span()
            .class("recent-filter-inert").attr("aria-hidden", "true").el());
        const content = H.div()
            .class("recent-filter-content")
            .append(grid, this.#hoverLabel)
            .el();
        const trigger = H.button()
            .class("chat-button", "recent-filter-trigger")
            .attr("type", "button")
            .el();
        this.#menu = new PopupMenu(trigger, content, {
            rootClass: "recent-filter-menu",
            popoverClass: "recent-filter-popover",
            role: "menu",
        });
        this.element = this.#menu.element;
        this.#render();
    }

    setFilter(filter: RecentChatFilter): void {
        if (this.#filter === filter)
            return;
        this.#filter = filter;
        this.#render();
    }

    setHidden(hidden: boolean): void {
        this.#menu.setHidden(hidden);
    }

    render(language: ChatLanguage): void {
        if (this.#language === language)
            return;
        this.#language = language;
        this.#render();
    }

    #select(filter: RecentChatFilter): void {
        this.#menu.close();
        if (this.#filter === filter)
            return;
        this.#filter = filter;
        this.#render();
        this.#handlers.onChange(filter);
    }

    #render(): void {
        const text = uiText(this.#language);
        for (const option of recentChatFilterOptions) {
            const item = this.#items.get(option.id)!;
            item.setLabel(filterLabel(text, option.id));
            item.setTooltip(filterLabel(text, option.id));
            item.setChecked(option.id === this.#filter);
        }
        const selected = recentChatFilterOptions.find(option => option.id === this.#filter)!;
        this.#menu.trigger.replaceChildren(icon(selected.icon));
        this.#menu.trigger.setAttribute("aria-pressed", String(this.#filter !== "all"));
        this.#menu.setLabel(filterLabel(text, selected.id));
        this.#renderHoverLabel();
    }

    #renderHoverLabel(): void {
        this.#hoverLabel.textContent = filterLabel(uiText(this.#language), this.#filter);
    }
}

function filterLabel(text: UiText, filter: RecentChatFilter): string {
    switch (filter) {
        case "all": return text.allChats;
        case "tool": return text.chatsWithToolUse;
        case "web": return text.chatsWithWebSearch;
        case "image": return text.chatsWithGeneratedImages;
        case "scheduled": return text.chatsWithScheduledTasks;
        case "compaction": return text.chatsWithCompactedContext;
        case "screen": return text.chatsWithScreenCaptures;
    }
}
