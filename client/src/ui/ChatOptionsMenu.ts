import type { ChatLanguage } from "../chat/Language";
import { H } from "./h";
import { icon } from "./Icons";
import {
    menuIcon,
    menuDialogLabel,
    MenuItemButton,
    PopupMenu,
} from "./PopupMenu";
import { uiText } from "./UiText";
import { canKeepMicrophoneOn } from "../audio/MicrophonePolicy";

export interface ChatOptionsMenuHandlers {
    readonly onDelete: () => void;
    readonly onToggleAutoSpeak: () => void;
    readonly onTogglePlayMusic: () => void;
    readonly onToggleKeepMicrophoneOn: () => void;
    readonly onSpeechCommitDelayChange: (seconds: number) => void;
    readonly onShowThinkingChange: (show: boolean) => void;
    readonly onCompactNow: () => void;
    readonly onShowCompactedContextChange: (show: boolean) => void;
    readonly onOpenScheduledTasks: () => void;
    readonly onToggleScreenShare: () => void;
}

export class ChatOptionsMenu {
    readonly element: HTMLElement;
    readonly #handlers: ChatOptionsMenuHandlers;
    readonly #menu: PopupMenu;
    readonly #title: HTMLElement;
    readonly #slots: HTMLElement;
    readonly #musicItem: MenuItemButton;
    readonly #speechItem: MenuItemButton;
    readonly #keepMicrophoneItem: MenuItemButton;
    readonly #thinkingItem: MenuItemButton;
    readonly #compactItem: MenuItemButton;
    readonly #compactedContextItem: MenuItemButton;
    readonly #scheduledTasksItem: MenuItemButton;
    readonly #screenShareItem: MenuItemButton;
    readonly #deleteItem: MenuItemButton;
    readonly #actions: HTMLElement;
    #seconds: number;
    #showThinking: boolean;
    #showCompactedContext: boolean;
    #screenShareActive = false;
    #language: ChatLanguage;

    constructor(
        handlers: ChatOptionsMenuHandlers,
        seconds: number,
        showThinking: boolean,
        showCompactedContext: boolean,
        language: ChatLanguage,
        profileName: string,
    ) {
        this.#handlers = handlers;
        this.#seconds = seconds;
        this.#showThinking = showThinking;
        this.#showCompactedContext = showCompactedContext;
        this.#language = language;
        this.#title = H.div().class("chat-options-title").el();
        this.#slots = H.div().class("chat-options-slots").attr("role", "group").el();
        this.#musicItem = new MenuItemButton("menuitemcheckbox", () => {
            this.#handlers.onTogglePlayMusic();
        });
        this.#speechItem = new MenuItemButton("menuitemcheckbox", () => {
            this.#handlers.onToggleAutoSpeak();
        });
        this.#keepMicrophoneItem = new MenuItemButton("menuitemcheckbox", () => {
            this.#handlers.onToggleKeepMicrophoneOn();
        });
        this.#thinkingItem = new MenuItemButton("menuitemcheckbox", () => {
            this.#selectShowThinking(!this.#showThinking);
        });
        this.#compactItem = new MenuItemButton("menuitem", () => {
            this.#menu.close();
            this.#handlers.onCompactNow();
        });
        this.#compactedContextItem = new MenuItemButton("menuitemcheckbox", () => {
            this.#selectShowCompactedContext(!this.#showCompactedContext);
        });
        this.#scheduledTasksItem = new MenuItemButton("menuitem", () => {
            this.#menu.close();
            this.#handlers.onOpenScheduledTasks();
        });
        this.#screenShareItem = new MenuItemButton("menuitemcheckbox", () => {
            this.#handlers.onToggleScreenShare();
        });
        this.#deleteItem = new MenuItemButton("menuitem", () => {
            const text = uiText(this.#language);
            if (globalThis.confirm(text.deleteConfirmation)) {
                this.#menu.close();
                this.#handlers.onDelete();
            }
        });
        this.#deleteItem.element.classList.add("popup-menu-item-danger");
        this.#actions = H.div()
            .class("popup-menu-items", "chat-options-items")
            .attr("role", "menu")
            .append(
                this.#musicItem.element,
                this.#speechItem.element,
                this.#keepMicrophoneItem.element,
                this.#thinkingItem.element,
                this.#compactedContextItem.element,
                this.#compactItem.element,
                this.#scheduledTasksItem.element,
                this.#screenShareItem.element,
                this.#deleteItem.element,
            )
            .el();
        const content = H.div()
            .class("chat-options-content")
            .append(this.#title, this.#slots, this.#actions)
            .el();
        const trigger = H.button()
            .class("chat-button", "chat-button-quiet", "chat-toolbar-icon-button")
            .attr("type", "button")
            .append(icon("/icons/ellipsis.svg"))
            .el();
        this.#menu = new PopupMenu(trigger, content, {
            rootClass: "chat-options-menu",
            popoverClass: "chat-options-popover",
            role: "dialog",
        });
        this.element = this.#menu.element;
        this.#renderSettings(profileName);
    }

    setShowThinking(show: boolean): void {
        this.#showThinking = show;
        this.#thinkingItem.setDecorator(menuIcon("/icons/brain.svg"));
        this.#thinkingItem.setChecked(!show);
    }

    setShowCompactedContext(show: boolean): void {
        this.#showCompactedContext = show;
        this.#compactedContextItem.setChecked(show);
    }

    setHidden(hidden: boolean): void {
        this.#menu.setHidden(hidden);
    }

    setScreenShareActive(active: boolean): void {
        this.#screenShareActive = active;
        this.#screenShareItem.setChecked(active);
    }

    render(
        language: ChatLanguage,
        playMusic: boolean,
        musicTitle: string | undefined,
        automaticallySpeak: boolean,
        keepMicrophoneOn: boolean,
        hasDeletableChat: boolean,
        canDeleteChat: boolean,
        profileName: string,
        canCompactNow = false,
        compacting = false,
        hasTurns = false,
    ): void {
        this.#language = language;
        const text = uiText(language);
        this.#menu.setLabel(text.chatSettings);
        this.#title.textContent = text.secondsBeforeSending;
        this.#slots.setAttribute("aria-label", text.secondsBeforeSending);
        this.#musicItem.setLabel(text.playMusic);
        this.#musicItem.setTooltip(musicTitle);
        this.#musicItem.setDecorator(menuIcon("/icons/music-note.svg"));
        this.#musicItem.setChecked(playMusic);
        this.#speechItem.setLabel(text.automaticallySpeakResponses);
        this.#speechItem.setDecorator(menuIcon("/icons/speaker.svg"));
        this.#speechItem.setChecked(automaticallySpeak);
        this.#keepMicrophoneItem.setLabel(text.keepMicrophoneOn);
        this.#keepMicrophoneItem.setDecorator(menuIcon("/icons/microphone-vintage.svg"));
        this.#keepMicrophoneItem.setChecked(keepMicrophoneOn);
        this.#keepMicrophoneItem.element.hidden = !canKeepMicrophoneOn(
            playMusic,
            automaticallySpeak,
        );
        this.#thinkingItem.setLabel(text.showOnlyRecentThinking);
        this.#thinkingItem.setDecorator(menuIcon("/icons/brain.svg"));
        this.#thinkingItem.setChecked(!this.#showThinking);
        this.#compactItem.setLabel(compacting ? text.compactingContext : text.compactNow);
        this.#compactItem.setDecorator(menuIcon("/icons/press.svg"));
        this.#compactItem.element.hidden = !hasTurns;
        this.#compactItem.element.disabled = !canCompactNow;
        this.#scheduledTasksItem.setLabel(menuDialogLabel(text.scheduledTasks));
        this.#scheduledTasksItem.setDecorator(menuIcon("/icons/bell.svg"));
        this.#compactedContextItem.setLabel(text.showCompactedContext);
        this.#compactedContextItem.setDecorator(menuIcon("/icons/notebook.svg"));
        this.#compactedContextItem.setChecked(this.#showCompactedContext);
        this.#screenShareItem.setLabel(
            this.#screenShareActive
                ? text.stopSharingScreen
                : menuDialogLabel(text.shareScreen(profileName)),
        );
        this.#screenShareItem.setDecorator(menuIcon("/icons/camera.svg"));
        this.#screenShareItem.setChecked(this.#screenShareActive);
        this.#deleteItem.setLabel(menuDialogLabel(text.deleteChat));
        this.#deleteItem.setDecorator(menuIcon("/icons/trash.svg"));
        this.#deleteItem.element.hidden = !hasDeletableChat;
        this.#deleteItem.element.disabled = !canDeleteChat;
        this.#renderSeconds(text);
    }

    #select(seconds: number): void {
        if (this.#seconds === seconds)
            return;
        this.#seconds = seconds;
        this.#renderSeconds(uiText(this.#language));
        this.#handlers.onSpeechCommitDelayChange(seconds);
    }

    #selectShowThinking(show: boolean): void {
        if (this.#showThinking === show)
            return;
        this.setShowThinking(show);
        this.#handlers.onShowThinkingChange(show);
    }

    #selectShowCompactedContext(show: boolean): void {
        if (this.#showCompactedContext === show)
            return;
        this.setShowCompactedContext(show);
        this.#handlers.onShowCompactedContextChange(show);
    }

    #renderSettings(profileName: string): void {
        this.render(this.#language, false, undefined, false, true, false, false, profileName);
    }

    #renderSeconds(text: ReturnType<typeof uiText>): void {
        this.#slots.replaceChildren(...visibleSpeechCommitDelays(this.#seconds).map(seconds => {
            const button = H.button()
                .class("chat-options-second", "toggle-selection")
                .attr("type", "button")
                .attr("aria-label", text.sendAfterSeconds(seconds))
                .attr("aria-pressed", String(seconds === this.#seconds))
                .text(String(seconds))
                .on("click", () => this.#select(seconds))
                .el();
            return button;
        }));
    }
}

function visibleSpeechCommitDelays(selected: number): readonly number[] {
    const first = Math.min(Math.max(selected - 3, 1), 6);
    return [0, 1, 2, 3, 4, 5, 6].map(offset => first + offset);
}
