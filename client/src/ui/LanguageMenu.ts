import type { ChatLanguage } from "../chat/Language";
import { H } from "./h";
import { icon } from "./Icons";
import {
    menuIcon,
    menuDialogLabel,
    menuTextIcon,
    MenuItemButton,
    PopupMenu,
} from "./PopupMenu";
import { uiText } from "./UiText";

export interface LanguageMenuHandlers {
    readonly onChange: (language: ChatLanguage) => void;
    readonly onOpenInstructions: () => void;
    readonly onOpenScheduledTasks: () => void;
}

export class LanguageMenu {
    readonly element: HTMLElement;
    readonly #handlers: LanguageMenuHandlers;
    readonly #menu: PopupMenu;
    readonly #items: Readonly<Record<ChatLanguage, MenuItemButton>>;
    readonly #scheduledTasksItem: MenuItemButton;
    readonly #instructionsItem: MenuItemButton;

    constructor(handlers: LanguageMenuHandlers) {
        this.#handlers = handlers;
        const english = this.#item("en");
        const slovak = this.#item("sk");
        const german = this.#item("de");
        this.#items = { en: english, sk: slovak, de: german };
        this.#scheduledTasksItem = new MenuItemButton("menuitem", () => {
            this.#menu.close();
            this.#handlers.onOpenScheduledTasks();
        });
        this.#instructionsItem = new MenuItemButton("menuitem", () => {
            this.#menu.close();
            this.#handlers.onOpenInstructions();
        });
        const content = H.div()
            .class("popup-menu-items", "language-menu-items")
            .append(
                english.element,
                slovak.element,
                german.element,
                this.#scheduledTasksItem.element,
                this.#instructionsItem.element,
            )
            .el();
        const trigger = H.button()
            .class("chat-button", "chat-button-quiet", "chat-toolbar-icon-button")
            .attr("type", "button")
            .append(icon("/icons/ellipsis.svg"))
            .el();
        this.#menu = new PopupMenu(trigger, content, {
            rootClass: "language-menu",
            popoverClass: "language-menu-popover",
            role: "menu",
        });
        this.element = this.#menu.element;
    }

    setHidden(hidden: boolean): void {
        this.#menu.setHidden(hidden);
    }

    render(
        language: ChatLanguage,
        supported: readonly ChatLanguage[],
        canChange: boolean,
    ): void {
        const text = uiText(language);
        this.#menu.setLabel(text.menu);
        this.#menu.trigger.disabled = !canChange;
        if (!canChange)
            this.#menu.close();
        this.#items.en.setLabel(text.english);
        this.#items.sk.setLabel(text.slovak);
        this.#items.de.setLabel(text.german);
        this.#scheduledTasksItem.setLabel(menuDialogLabel(text.scheduledTasks));
        this.#scheduledTasksItem.setDecorator(menuIcon("/icons/bell.svg"));
        this.#scheduledTasksItem.element.disabled = !canChange;
        this.#instructionsItem.setLabel(menuDialogLabel(text.instructions));
        this.#instructionsItem.setDecorator(menuIcon("/icons/notebook.svg"));
        for (const code of ["en", "sk", "de"] as const) {
            const item = this.#items[code];
            item.setDecorator(menuTextIcon(code));
            item.setChecked(code === language);
            item.element.disabled = !canChange || !supported.includes(code);
        }
    }

    #item(language: ChatLanguage): MenuItemButton {
        return new MenuItemButton("menuitemradio", () => {
            this.#menu.close();
            this.#handlers.onChange(language);
        });
    }
}
