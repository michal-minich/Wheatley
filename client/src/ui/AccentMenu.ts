import type { ChatLanguage } from "../chat/Language";
import {
    accent,
    accentLabel,
    accents,
    cssColor,
    type AccentId,
} from "../theme/Accents";
import { H } from "./h";
import { PopupMenu } from "./PopupMenu";

export interface AccentMenuHandlers {
    readonly onChange: (id: AccentId) => void;
}

export class AccentMenu {
    readonly element: HTMLElement;
    readonly #handlers: AccentMenuHandlers;
    readonly #menu: PopupMenu;
    readonly #grid: HTMLElement;
    #accentId: AccentId;
    #language: ChatLanguage;

    constructor(
        handlers: AccentMenuHandlers,
        accentId: AccentId,
        language: ChatLanguage,
    ) {
        this.#handlers = handlers;
        this.#accentId = accentId;
        this.#language = language;
        const trigger = H.button()
            .class("accent-menu-trigger", "chat-button")
            .el();
        this.#grid = H.div().class("accent-menu-grid").el();
        this.#menu = new PopupMenu(trigger, this.#grid, {
            rootClass: "accent-menu",
            popoverClass: "accent-menu-popover",
            role: "menu",
        });
        this.element = this.#menu.element;
        this.#render();
    }

    setAccent(id: AccentId): void {
        if (this.#accentId === id)
            return;
        this.#accentId = id;
        this.#render();
    }

    setLanguage(language: ChatLanguage): void {
        if (this.#language === language)
            return;
        this.#language = language;
        this.#render();
    }

    #render(): void {
        const selected = accent(this.#accentId);
        const selectedLabel = accentLabel(selected, this.#language);
        this.#menu.trigger.replaceChildren(this.#swatch(cssColor(selected.color)));
        this.#menu.setLabel(selectedLabel);

        this.#grid.replaceChildren(...accents.map(item => {
            const label = accentLabel(item, this.#language);
            const button = H.button()
                .class("accent-menu-swatch")
                .attr("title", label)
                .attr("aria-label", label)
                .on("click", () => {
                    this.#menu.close();
                    this.#handlers.onChange(item.id);
                })
                .el();
            button.style.background = cssColor(item.color);
            button.classList.toggle("accent-menu-swatch-active", item.id === this.#accentId);
            return button;
        }));
    }

    #swatch(color: string): HTMLElement {
        const swatch = H.span().class("accent-menu-trigger-swatch").el();
        swatch.style.background = color;
        return swatch;
    }
}
