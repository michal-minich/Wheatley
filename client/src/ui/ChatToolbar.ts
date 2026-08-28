import type { ChatSessionSnapshot } from "../chat/ChatSession";
import type { ChatLanguage } from "../chat/Language";
import type { AccentId } from "../theme/Accents";
import type { ProfileSummary } from "../transport/ChatTransport";
import { AccentMenu } from "./AccentMenu";
import { ChatOptionsMenu } from "./ChatOptionsMenu";
import { H } from "./h";
import { icon } from "./Icons";
import { LanguageMenu } from "./LanguageMenu";
import type { RecentChatFilter } from "./RecentChatFilter";
import { RecentChatFilterMenu } from "./RecentChatFilterMenu";
import { uiText } from "./UiText";
import { chatPath, isUnmodifiedLeftClick } from "../app/ChatRoute";
import { formatRelativeTime } from "./LocalDateTime";

export interface ChatToolbarHandlers {
  readonly onHome: () => void;
  readonly onNewChat: () => void;
  readonly onOpenRecent: (session: ChatSessionSnapshot["recentSessions"][number]) => void;
  readonly onLanguageChange: (language: ChatLanguage) => void;
  readonly onDelete: () => void;
  readonly onProfileChange: (profileId: string) => void;
  readonly onSearchChats: (query: string) => void;
  readonly onFilterChats: (filter: RecentChatFilter) => void;
  readonly onAccentChange: (accentId: AccentId) => void;
  readonly onToggleAutoSpeak: () => void;
  readonly onTogglePlayMusic: () => void;
  readonly onToggleKeepMicrophoneOn: () => void;
  readonly onStopPlayback: () => void;
  readonly onSpeechCommitDelayChange: (seconds: number) => void;
  readonly onShowThinkingChange: (show: boolean) => void;
  readonly onCompactNow: () => void;
  readonly onShowCompactedContextChange: (show: boolean) => void;
  readonly onOpenInstructions: () => void;
  readonly onOpenScheduledTasks: () => void;
  readonly onToggleScreenShare: () => void;
}

export class ChatToolbar {
    readonly element: HTMLElement;
    readonly #profileSelect: HTMLSelectElement;
    readonly #accentMenu: AccentMenu;
    readonly #chatOptionsMenu: ChatOptionsMenu;
    readonly #languageMenu: LanguageMenu;
    readonly #identityControl: HTMLElement;
    readonly #homeButton: HTMLAnchorElement;
    readonly #newChatButton: HTMLAnchorElement;
    readonly #homeControl: HTMLElement;
    readonly #homeRecent: HTMLElement;
    readonly #stopPlaybackButton: HTMLButtonElement;
    readonly #search: HTMLInputElement;
    readonly #clearSearch: HTMLButtonElement;
    readonly #recentFilterMenu: RecentChatFilterMenu;
    readonly #searchControl: HTMLElement;
    readonly #handlers: ChatToolbarHandlers;
    #homeRecentCloseTimer: number | undefined;

    constructor(
        handlers: ChatToolbarHandlers,
        profiles: readonly ProfileSummary[],
        profileId: string,
        accentId: AccentId,
        language: ChatLanguage,
        showThinking: boolean,
        showCompactedContext: boolean,
        speechCommitDelaySeconds: number,
    ) {
        this.#handlers = handlers;
        this.#profileSelect = H.select()
            .class("chat-select")
            .attr("aria-label", uiText(language).profile)
            .on("change", () => handlers.onProfileChange(this.#profileSelect.value))
            .el();
        this.#profileSelect.replaceChildren(
            ...profiles.map((profile) =>
                H.option().attr("value", profile.id).text(profileName(profile.id)).el(),
            ),
        );
        this.#profileSelect.value = profileId;
        this.#accentMenu = new AccentMenu(
            { onChange: handlers.onAccentChange },
            accentId,
            language,
        );
        this.#chatOptionsMenu = new ChatOptionsMenu(
            {
                onDelete: handlers.onDelete,
                onToggleAutoSpeak: handlers.onToggleAutoSpeak,
                onTogglePlayMusic: handlers.onTogglePlayMusic,
                onToggleKeepMicrophoneOn: handlers.onToggleKeepMicrophoneOn,
                onSpeechCommitDelayChange: handlers.onSpeechCommitDelayChange,
                onShowThinkingChange: handlers.onShowThinkingChange,
                onCompactNow: handlers.onCompactNow,
                onShowCompactedContextChange: handlers.onShowCompactedContextChange,
                onOpenScheduledTasks: handlers.onOpenScheduledTasks,
                onToggleScreenShare: handlers.onToggleScreenShare,
            },
            speechCommitDelaySeconds,
            showThinking,
            showCompactedContext,
            language,
            profileName(profileId),
        );
        this.#homeButton = iconLink("/icons/house.svg", "/", handlers.onHome);
        this.#languageMenu = new LanguageMenu({
            onChange: handlers.onLanguageChange,
            onOpenInstructions: handlers.onOpenInstructions,
            onOpenScheduledTasks: handlers.onOpenScheduledTasks,
        });
        this.#newChatButton = iconLink(
            "/icons/square-pen.svg",
            "/new",
            handlers.onNewChat,
        );
        this.#homeRecent = document.createElement("nav");
        this.#homeRecent.className = "home-recent";
        this.#homeControl = H.div()
            .class("home-chat-control")
            .append(this.#homeButton, this.#homeRecent)
            .el();
        this.#homeControl.addEventListener("mouseenter", () => this.#openHomeRecent());
        this.#homeControl.addEventListener("mouseleave", () => this.#scheduleHomeRecentClose());
        this.#homeControl.addEventListener("focusin", () => this.#openHomeRecent());
        this.#homeControl.addEventListener("focusout", event => {
            if (!(event.relatedTarget instanceof Node)
                || !this.#homeControl.contains(event.relatedTarget))
                this.#scheduleHomeRecentClose();
        });
        this.#homeRecent.addEventListener("mouseenter", () => this.#openHomeRecent());
        this.#stopPlaybackButton = iconButton(
            "/icons/stop.svg",
            handlers.onStopPlayback,
        );
        this.#recentFilterMenu = new RecentChatFilterMenu({
            onChange: handlers.onFilterChats,
        }, language);
        this.#search = H.input()
            .class("recent-search")
            .attr("type", "search")
            .on("input", () => {
                this.#renderSearchClear();
                handlers.onSearchChats(this.#search.value);
            })
            .el();
        this.#clearSearch = H.button()
            .class("recent-search-clear")
            .attr("type", "button")
            .text("×")
            .on("click", () => {
                this.clearSearch();
                handlers.onSearchChats("");
                this.#search.focus();
            })
            .el();
        const searchField = H.div()
            .class("recent-search-field")
            .append(this.#search, this.#clearSearch)
            .el();
        this.#searchControl = H.div()
            .class("chat-search-control")
            .append(this.#recentFilterMenu.element, searchField)
            .el();
        this.#identityControl = H.div()
            .class("chat-identity-control")
            .append(this.#accentMenu.element, this.#profileSelect)
            .el();
        this.element = H.header()
            .class("chat-header")
            .append(
                H.div()
                    .class("chat-toolbar-left")
                    .append(
                        this.#newChatButton,
                        this.#homeControl,
                    )
                    .el(),
                this.#identityControl,
                H.div()
                    .class("chat-toolbar-right")
                    .append(
                        this.#searchControl,
                        this.#stopPlaybackButton,
                        this.#languageMenu.element,
                        this.#chatOptionsMenu.element,
                    )
                    .el(),
            )
            .el();
    }

    get profileName(): string {
        return profileName(this.#profileSelect.value);
    }

    selectProfile(profileId: string): void {
        this.#profileSelect.value = profileId;
    }

    clearSearch(): void {
        this.#search.value = "";
        this.#renderSearchClear();
    }

    resetRecentFilter(): void {
        this.#recentFilterMenu.setFilter("all");
    }

    setAccent(accentId: AccentId): void {
        this.#accentMenu.setAccent(accentId);
    }

    setShowThinking(show: boolean): void {
        this.#chatOptionsMenu.setShowThinking(show);
    }

    setShowCompactedContext(show: boolean): void {
        this.#chatOptionsMenu.setShowCompactedContext(show);
    }

    setScreenShareActive(active: boolean): void {
        this.#chatOptionsMenu.setScreenShareActive(active);
    }

    render(snapshot: ChatSessionSnapshot): void {
        const text = uiText(snapshot.language);
        const home = snapshot.panel === "home";
        const canStart = snapshot.canSwitchChats;
        this.element.classList.toggle("chat-header-chat", !home);
        this.#identityControl.hidden = !home;
        this.#profileSelect.disabled = false;
        this.#profileSelect.setAttribute("aria-label", text.profile);
        this.#accentMenu.setLanguage(snapshot.language);
        this.#chatOptionsMenu.setHidden(home);
        this.#languageMenu.setHidden(!home);
        this.#searchControl.hidden = !home;
        this.#recentFilterMenu.setHidden(!home);
        this.#recentFilterMenu.render(snapshot.language);
        this.#search.placeholder = text.searchChats;
        this.#search.setAttribute("aria-label", text.searchChats);
        this.#clearSearch.setAttribute("aria-label", text.clearSearch);
        this.#renderSearchClear();

        this.#homeControl.hidden = home;
        if (home) this.#closeHomeRecent();
        setLabel(this.#homeButton, text.home);
        setLabel(this.#newChatButton, text.newChat);
        this.#newChatButton.hidden = false;
        this.#newChatButton.setAttribute("aria-disabled", String(!canStart));
        this.#renderHomeRecent(snapshot, canStart);
        this.#languageMenu.render(
            snapshot.language,
            snapshot.supportedLanguages,
            canStart,
        );

        this.#chatOptionsMenu.render(
            snapshot.language,
            snapshot.playMusic,
            snapshot.musicTitle,
            snapshot.speech.autoEnabled,
            snapshot.keepMicrophoneOn,
            snapshot.hasDeletableChat,
            snapshot.canDeleteChat,
            this.profileName,
            snapshot.canCompactNow,
            snapshot.compacting,
            snapshot.messages.length > 0,
        );
        const playing = snapshot.speech.active !== undefined;
        setLabel(this.#stopPlaybackButton, text.stopPlayback);
        this.#stopPlaybackButton.hidden = home || !playing;
    }

    #renderSearchClear(): void {
        this.#clearSearch.hidden = this.#search.value.length === 0;
    }

    #openHomeRecent(): void {
        if (this.#homeRecent.hidden) return;
        if (this.#homeRecentCloseTimer !== undefined) {
            globalThis.clearTimeout(this.#homeRecentCloseTimer);
            this.#homeRecentCloseTimer = undefined;
        }
        this.#refreshHomeRecentTimes();
        this.#homeControl.classList.add("home-recent-open");
    }

    #scheduleHomeRecentClose(): void {
        if (this.#homeRecentCloseTimer !== undefined)
            globalThis.clearTimeout(this.#homeRecentCloseTimer);
        this.#homeRecentCloseTimer = globalThis.setTimeout(() => {
            this.#homeRecentCloseTimer = undefined;
            this.#homeControl.classList.remove("home-recent-open");
        }, 140);
    }

    #closeHomeRecent(): void {
        if (this.#homeRecentCloseTimer !== undefined) {
            globalThis.clearTimeout(this.#homeRecentCloseTimer);
            this.#homeRecentCloseTimer = undefined;
        }
        this.#homeControl.classList.remove("home-recent-open");
    }

    #refreshHomeRecentTimes(): void {
        for (const element of this.#homeRecent.querySelectorAll<HTMLElement>(".home-recent-date"))
            element.textContent = formatRelativeTime(element.dataset["timestamp"]!);
    }

    #renderHomeRecent(
        snapshot: ChatSessionSnapshot,
        enabled: boolean,
    ): void {
        const cutoff = Date.now() - 3 * 24 * 60 * 60 * 1_000;
        const recent = snapshot.recentSessions.filter(session =>
            Date.parse(session.startedAt) >= cutoff).slice(0, 12);
        for (const session of snapshot.recentSessions) {
            if (recent.length >= 3) break;
            if (!recent.includes(session)) recent.push(session);
        }
        this.#homeRecent.replaceChildren(...recent.map(session => H.a()
            .class("home-recent-link")
            .attr("href", chatPath(snapshot.profileId, session.sessionId))
            .append(
                H.span().class("home-recent-title").text(session.initialUserText).el(),
                H.span().class("home-recent-date")
                    .attr("data-timestamp", session.startedAt)
                    .text(formatRelativeTime(session.startedAt)).el(),
            )
            .on("click", event => {
                if (!enabled || !isUnmodifiedLeftClick(event)) return;
                event.preventDefault();
                this.#handlers.onOpenRecent(session);
            }).el()));
        this.#homeRecent.hidden = recent.length === 0;
        if (recent.length === 0) this.#closeHomeRecent();
    }
}

function profileName(profileId: string): string {
    return profileId.replace(/^./u, (letter) => letter.toLocaleUpperCase());
}

function iconButton(source: string, onClick: () => void): HTMLButtonElement {
    return H.button()
        .class("chat-button", "chat-button-quiet", "chat-toolbar-icon-button")
        .attr("type", "button")
        .append(icon(source))
        .on("click", onClick)
        .el();
}

function iconLink(source: string, href: string, onClick: () => void): HTMLAnchorElement {
    return H.a()
        .class("chat-button", "chat-button-quiet", "chat-toolbar-icon-button")
        .attr("href", href)
        .append(icon(source))
        .on("click", event => {
            if (!isUnmodifiedLeftClick(event)) return;
            event.preventDefault();
            const link = event.currentTarget as HTMLAnchorElement;
            if (link.getAttribute("aria-disabled") !== "true") onClick();
        })
        .el();
}

function setLabel(button: HTMLElement, label: string): void {
    button.setAttribute("aria-label", label);
    button.title = label;
}
