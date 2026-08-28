import type { ChatMessage } from "../chat/ChatMessage";
import type { ActiveChatActivity } from "../chat/ChatTranscript";
import type { ChatSpeechState } from "../chat/ChatSpeech";
import type { WebImageReference } from "../transport/ChatTransport";
import { H } from "./h";
import { imagePresentationText, linkedImageFrame } from "./ImagePresentation";
import { messageActionBar, syncMessageAction } from "./MessageActions";
import type { ChatTranscriptHandlers } from "./ChatViewHandlers";
import type { UiText } from "./UiText";
import { isActivityMessage } from "../chat/ChatMessage";
import { isNearBottom, reconcileChildren } from "./DomList";
import { imagePageUrl } from "../app/ImagePage";
import { formatCompactDuration, formatDetailedDuration } from "./LocalDateTime";
import { turnMetricsTooltip } from "./TurnMetricsText";

export class ChatActivityView {
    readonly pane: HTMLElement;
    readonly #paneList: HTMLElement;
    readonly #handlers: ChatTranscriptHandlers;
    readonly #previews = new Map<string, ActivityRunPreview>();
    readonly #messagePreviewKeys = new Map<string, string>();
    readonly #loadingReasoning = new Set<string>();
    #renderedActivity = new Map<string, RenderedActivityMessage>();
    #hasActivity = false;
    #latestPreviewKey: string | undefined;
    #selectedActivityKey: string | undefined;
    #open: boolean;
    #showAllThinking: boolean;
    #text: UiText | undefined;

    constructor(
        handlers: ChatTranscriptHandlers,
        open: boolean,
        showThinking: boolean,
    ) {
        this.#handlers = handlers;
        this.#open = open;
        this.#showAllThinking = showThinking;
        const closeIcon = document.createElement("img");
        closeIcon.src = "/icons/x.svg";
        closeIcon.alt = "";
        closeIcon.setAttribute("aria-hidden", "true");
        const close = H.button()
            .class(
                "chat-button",
                "chat-toolbar-icon-button",
                "activity-pane-close",
            )
            .attr("type", "button")
            .append(closeIcon)
            .el();
        close.addEventListener("click", () => this.#setOpen(false));
        this.#paneList = H.div().class("activity-pane-list").el();
        this.pane = H.section()
            .class("activity-pane")
            .append(close, this.#paneList)
            .el();
    }

    render(
        messages: readonly ChatMessage[],
        speech: ChatSpeechState,
        text: UiText,
        activeActivity?: ActiveChatActivity,
        profileId?: string,
        sessionId?: string,
    ): void {
        const activity = messages.filter(isActivityMessage);
        const activityRuns = groupActivityRuns(messages);
        this.#latestPreviewKey = activityRuns.at(-1)?.key;
        const activeRunKey = activeActivity === undefined
            ? undefined
            : activityRuns.findLast(run => run.turnKey === activeActivity.turnId)?.key;
        const activePreviewKeys = new Set(activityRuns.map(run => run.key));
        if (
            this.#showAllThinking
            && (this.#selectedActivityKey === undefined
                || !activePreviewKeys.has(this.#selectedActivityKey))
        ) this.#selectedActivityKey = this.#latestPreviewKey;
        this.#hasActivity = activity.length > 0;
        this.#text = text;
        this.pane.hidden = !this.#hasActivity || !this.#open;
        this.#syncLabels(text);
        for (const [key, preview] of this.#previews) {
            if (!activePreviewKeys.has(key)) {
                preview.dispose();
                this.#previews.delete(key);
            }
        }
        this.#messagePreviewKeys.clear();
        for (const run of activityRuns) {
            let preview = this.#previews.get(run.key);
            if (preview === undefined) {
                preview = new ActivityRunPreview(
                    () => this.#toggleRun(run.key),
                    this.#handlers,
                );
                this.#previews.set(run.key, preview);
            }
            for (const message of run.activity)
                this.#messagePreviewKeys.set(message.id, run.key);
            preview.render(
                run.activity,
                text,
                this.#runIsOpen(run.key),
                activeRunKey === run.key
                    ? activeActivity?.startedMono
                    : undefined,
            );
        }
        this.#syncPreviewVisibility();
        if (!this.#hasActivity) {
            this.#paneList.replaceChildren();
            this.#renderedActivity.clear();
            return;
        }
        this.#renderPane(activity, speech, text, profileId, sessionId);
    }

    previewFor(message: ChatMessage): HTMLElement {
        const key = this.#messagePreviewKeys.get(message.id);
        const preview = key === undefined ? undefined : this.#previews.get(key);
        if (preview === undefined)
            throw new Error(`Missing activity preview for ${message.id}`);
        return preview.element;
    }

    setOpen(open: boolean): void {
        this.#open = open;
        this.pane.hidden = !this.#hasActivity || !open;
        this.#syncPreviewLabels();
    }

    setShowThinking(show: boolean): void {
        if (this.#showAllThinking === show)
            return;
        this.#showAllThinking = show;
        if (show)
            this.#selectedActivityKey = this.#latestPreviewKey;
        this.#syncPreviewVisibility();
        this.#syncPaneSelection();
        this.#syncPreviewLabels();
        this.#paneList.scrollTop = show ? 0 : this.#paneList.scrollHeight;
    }

    #toggleRun(key: string): void {
        if (!this.#showAllThinking) {
            this.#setOpen(!this.#open);
            return;
        }
        if (this.#open && this.#selectedActivityKey === key) {
            this.#setOpen(false);
            return;
        }
        this.#selectedActivityKey = key;
        this.#syncPaneSelection();
        this.#paneList.scrollTop = 0;
        this.#setOpen(true);
    }

    #setOpen(open: boolean): void {
        const changed = this.#open !== open;
        this.setOpen(open);
        if (changed)
            this.#handlers.onActivityPaneOpenChange(open);
    }

    #syncLabels(text: UiText): void {
        const close = this.pane.querySelector<HTMLButtonElement>(".activity-pane-close")!;
        close.ariaLabel = text.closeActivity;
        close.removeAttribute("title");
    }

    #syncPreviewVisibility(): void {
        for (const [key, preview] of this.#previews)
            preview.element.hidden = !this.#showAllThinking && key !== this.#latestPreviewKey;
    }

    #syncPreviewLabels(): void {
        if (this.#text === undefined)
            return;
        for (const [key, preview] of this.#previews)
            preview.syncLabel(
                this.#text,
                this.#runIsOpen(key),
            );
    }

    #runIsOpen(key: string): boolean {
        return this.#open
            && (!this.#showAllThinking || this.#selectedActivityKey === key);
    }

    #syncPaneSelection(): void {
        for (const [messageId, activity] of this.#renderedActivity)
            activity.element.hidden = this.#showAllThinking
                && this.#messagePreviewKeys.get(messageId) !== this.#selectedActivityKey;
    }

    #renderPane(
        activity: readonly ChatMessage[],
        speech: ChatSpeechState,
        text: UiText,
        profileId?: string,
        sessionId?: string,
    ): void {
        const followLatest = isNearBottom(this.#paneList);
        const nextActivity = new Map<string, RenderedActivityMessage>();
        const elements: HTMLElement[] = [];
        let searchImageIndex = 0;
        for (const message of activity) {
            if (message.role === "reasoning" && message.reasoningTruncated === true)
                this.#loadFullReasoning(message);
            const current = this.#renderedActivity.get(message.id);
            const element = current?.role === message.role
                ? current.element
                : activityMessageView(message);
            updateActivityMessageView(
                element,
                message,
                speech,
                text,
                this.#handlers,
                (profileId === undefined || sessionId === undefined)
                    ? undefined
                    : message.tool?.webImages?.map(image => imagePageUrl(
                        image.imageUrl,
                        profileId,
                        sessionId,
                        "search-image",
                        ++searchImageIndex,
                    )),
            );
            nextActivity.set(message.id, {
                element,
                role: message.role,
            });
            elements.push(element);
        }
        reconcileChildren(this.#paneList, elements);
        this.#renderedActivity = nextActivity;
        this.#syncPaneSelection();
        if (followLatest)
            this.#paneList.scrollTop = this.#paneList.scrollHeight;
    }

    #loadFullReasoning(message: ChatMessage): void {
        const turnId = message.turnId!;
        const itemId = message.itemId!;
        const key = `${turnId}:${itemId}`;
        if (this.#loadingReasoning.has(key))
            return;
        this.#loadingReasoning.add(key);
        void this.#handlers.onLoadReasoning(turnId, itemId)
            .catch((error: unknown) => console.error("Loading reasoning failed", error))
            .finally(() => this.#loadingReasoning.delete(key));
    }
}

class ActivityRunPreview {
    readonly element: HTMLElement;
    readonly #button: HTMLElement;
    readonly #handlers: ChatTranscriptHandlers;
    readonly #duration: HTMLElement;
    readonly #lines: HTMLElement;
    readonly #images: HTMLElement;
    readonly #actions: HTMLElement;
    readonly #resizeObserver: ResizeObserver;
    readonly #entries = new Map<string, HTMLElement>();
    #timer: number | undefined;
    #activeStartedMono: number | undefined;
    #durationMs: number | undefined;
    #text: UiText | undefined;

    constructor(onToggle: () => void, handlers: ChatTranscriptHandlers) {
        this.#handlers = handlers;
        this.#duration = H.div().class("activity-preview-duration").el();
        this.#lines = H.div().class("activity-preview-lines").el();
        this.#images = H.div()
            .class("tool-image-carousel", "activity-preview-images")
            .el();
        this.#actions = messageActionBar();
        this.#resizeObserver = new ResizeObserver(() => this.#syncClipping());
        this.#resizeObserver.observe(this.#lines);
        this.#button = H.div()
            .class("activity-preview-button")
            .attr("role", "button")
            .attr("tabindex", "0")
            .append(this.#duration, this.#lines)
            .el();
        this.#button.addEventListener("click", () => onToggle());
        this.#button.addEventListener("keydown", event => {
            if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                onToggle();
            }
        });
        const card = H.div()
            .class("activity-preview-card")
            .append(this.#button, this.#images, this.#actions)
            .el();
        this.element = H.section()
            .class("message", "message-activity-preview")
            .append(card)
            .el();
    }

    render(
        activity: readonly ChatMessage[],
        text: UiText,
        open: boolean,
        activeStartedMono?: number,
    ): void {
        this.#durationMs = activity.findLast(message =>
            message.activityDurationMs !== undefined)?.activityDurationMs;
        this.#activeStartedMono = activeStartedMono;
        this.#text = text;
        this.#syncDuration();
        if (activeStartedMono === undefined)
            this.#stopTimer();
        else if (this.#timer === undefined)
            this.#timer = window.setInterval(() => this.#syncDuration(), 250);
        this.#renderEntries(activity.slice(-8));
        renderWebImageCarousel(
            this.#images,
            activity.flatMap(message => message.tool?.webImages ?? []),
        );
        this.#syncBranchAction(activity, text, activeStartedMono === undefined);
        this.syncLabel(text, open);
        this.#syncClipping();
    }

    syncLabel(text: UiText, open: boolean): void {
        const label = open ? text.closeActivity : text.openActivity;
        this.#button.ariaLabel = label;
        this.#button.removeAttribute("title");
    }

    dispose(): void {
        this.#stopTimer();
        this.#resizeObserver.disconnect();
    }

    #renderEntries(activity: readonly ChatMessage[]): void {
        const activeIds = new Set(activity.map(message => message.id));
        for (const id of this.#entries.keys()) {
            if (!activeIds.has(id))
                this.#entries.delete(id);
        }
        const elements = activity.map(message => {
            let entry = this.#entries.get(message.id);
            if (entry === undefined) {
                entry = H.div().class("activity-preview-entry").el();
                this.#entries.set(message.id, entry);
            }
            if (message.role === "tool" && !(entry instanceof HTMLButtonElement)) {
                entry = H.button()
                    .class("activity-preview-entry")
                    .attr("type", "button")
                    .el();
                this.#entries.set(message.id, entry);
            }
            updatePreviewEntry(entry, message, this.#handlers, this.#text!);
            return entry;
        });
        reconcileChildren(this.#lines, elements);
    }

    #syncDuration(): void {
        const text = this.#text;
        if (text === undefined)
            return;
        const duration = this.#activeStartedMono === undefined
            ? this.#durationMs
            : performance.now() - this.#activeStartedMono;
        this.#duration.hidden = duration === undefined;
        this.#duration.textContent = duration === undefined
            ? ""
            : this.#activeStartedMono === undefined
                ? text.workedFor(formatCompactDuration(duration))
                : text.workingFor(formatCompactDuration(duration));
    }

    #syncBranchAction(
        activity: readonly ChatMessage[],
        text: UiText,
        finished: boolean,
    ): void {
        const message = finished ? activity.findLast(item =>
            !item.pending
            && item.turnId !== undefined
            && !item.turnId.startsWith("codex:")
            && item.itemId !== undefined
            && (item.role === "reasoning"
                || (item.role === "tool" && item.tool?.status !== "running"))) : undefined;
        if (message === undefined) {
            this.#actions.querySelector("[data-message-action=\"branch\"]")?.remove();
            return;
        }
        syncMessageAction(
            this.#actions,
            "branch",
            "/icons/branch.svg",
            text.branchChatHere,
            () => this.#handlers.onBranch({
                turnId: message.turnId!,
                kind: message.role === "reasoning" ? "reasoning" : "artifact",
                itemId: message.itemId!,
            }),
        );
    }

    #stopTimer(): void {
        if (this.#timer === undefined)
            return;
        window.clearInterval(this.#timer);
        this.#timer = undefined;
    }

    #syncClipping(): void {
        this.#lines.scrollTop = this.#lines.scrollHeight;
        const clipped = this.#lines.scrollHeight > this.#lines.clientHeight + 1;
        this.#lines.classList.toggle("activity-preview-clipped", clipped);
    }
}


function activityTurnKey(message: ChatMessage): string {
    return message.turnId ?? message.id;
}

interface ActivityRun {
    readonly key: string;
    readonly turnKey: string;
    readonly activity: readonly ChatMessage[];
}

function groupActivityRuns(messages: readonly ChatMessage[]): readonly ActivityRun[] {
    const runs: ActivityRun[] = [];
    let activity: ChatMessage[] = [];
    let turnKey = "";
    const finish = (): void => {
        if (activity.length === 0)
            return;
        runs.push({
            key: `activity-run:${turnKey}:${activity[0]!.id}`,
            turnKey,
            activity,
        });
        activity = [];
        turnKey = "";
    };
    for (const message of messages) {
        if (!isActivityMessage(message)) {
            finish();
            continue;
        }
        const messageTurnKey = activityTurnKey(message);
        if (activity.length > 0 && messageTurnKey !== turnKey)
            finish();
        turnKey = messageTurnKey;
        activity.push(message);
    }
    finish();
    return runs;
}


function updatePreviewEntry(
    entry: HTMLElement,
    message: ChatMessage,
    handlers: ChatTranscriptHandlers,
    text: UiText,
): void {
    entry.textContent = message.text;
    entry.className = `activity-preview-entry activity-preview-${message.role}`;
    if (message.role === "tool" && message.tool?.status !== undefined) {
        entry.classList.add(`activity-preview-${message.tool.status}`);
        const tooltip = toolTooltip(message, text);
        if (tooltip.length === 0) entry.removeAttribute("title");
        else entry.title = tooltip;
        if (entry instanceof HTMLButtonElement) {
            entry.onclick = event => {
                event.stopPropagation();
                if (message.turnId !== undefined && message.tool !== undefined)
                    handlers.onInspectTool(
                        message.turnId,
                        message.tool.callIndex,
                        message.tool.name,
                    );
            };
        }
    }
}

function activityMessageView(
    message: ChatMessage,
): HTMLElement {
    return H.section()
        .class("message", `message-${message.role}`)
        .el();
}

function updateActivityMessageView(
    section: HTMLElement,
    message: ChatMessage,
    speech: ChatSpeechState,
    text: UiText,
    handlers: ChatTranscriptHandlers,
    imagePageUrls?: readonly string[],
): void {
    if (message.role === "tool") {
        updateToolView(section, message, text, handlers, imagePageUrls);
        return;
    }
    updateReasoningView(
        section,
        message,
        speech,
        text,
        handlers,
    );
}

function updateToolView(
    section: HTMLElement,
    message: ChatMessage,
    text: UiText,
    handlers: ChatTranscriptHandlers,
    imagePageUrls?: readonly string[],
): void {
    const indicator = message.tool;
    section.className = "message message-tool";
    if (indicator?.status !== undefined)
        section.classList.add(`message-tool-${indicator.status}`);
    const turnId = message.turnId;
    const callIndex = indicator?.callIndex;
    const toolName = indicator?.name;
    let card = section.querySelector<HTMLElement>(".message-tool-card");
    if (card === null) {
        card = H.div().class("message-tool-card").el();
        section.replaceChildren(card);
    }
    if (callIndex !== undefined && turnId !== undefined) {
        let button = card.querySelector<HTMLButtonElement>(".message-tool-button");
        if (button === null) {
            button = H.button()
                .class("message-event", "message-tool-button")
                .attr("type", "button")
                .el();
            card.prepend(button);
        }
        button.textContent = message.text;
        const tooltip = toolTooltip(message, text);
        if (tooltip.length === 0) button.removeAttribute("title");
        else button.title = tooltip;
        button.onclick = () => handlers.onInspectTool(
            turnId,
            callIndex,
            toolName,
        );
        syncToolImages(card, indicator?.webImages ?? [], imagePageUrls);
        return;
    }
    let event = card.querySelector<HTMLElement>(".message-event:not(button)");
    if (event === null) {
        event = H.div().class("message-event").el();
        card.prepend(event);
    }
    event.textContent = message.text;
    const tooltip = toolTooltip(message, text);
    if (tooltip.length === 0) event.removeAttribute("title");
    else event.title = tooltip;
    syncToolImages(card, indicator?.webImages ?? [], imagePageUrls);
}

function toolTooltip(message: ChatMessage, text: UiText): string {
    if (message.tool?.name === "model_context")
        return turnMetricsTooltip(message.turnMetrics, text, true).join("\n");
    return message.tool?.durationMs === undefined
        ? ""
        : `${text.turnDurationMetric}: ${formatDetailedDuration(message.tool.durationMs)}`;
}

function syncToolImages(
    card: HTMLElement,
    images: readonly WebImageReference[],
    imagePageUrls?: readonly string[],
): void {
    let carousel = card.querySelector<HTMLElement>(".tool-image-carousel");
    if (carousel === null) {
        carousel = H.div().class("tool-image-carousel").el();
        card.append(carousel);
    }
    renderWebImageCarousel(carousel, images, imagePageUrls);
}

function renderWebImageCarousel(
    carousel: HTMLElement,
    images: readonly WebImageReference[],
    imagePageUrls?: readonly string[],
): void {
    carousel.hidden = images.length === 0;
    carousel.replaceChildren(...images.map((image, index) => {
        const previewLink = linkedImageFrame({
            url: image.imageUrl,
            ...(imagePageUrls?.[index] === undefined
                ? {}
                : { pageUrl: imagePageUrls[index] }),
            alt: "",
            frameClass: "tool-image-preview-link",
            imageClass: "tool-image-preview",
            ...(image.width === undefined ? {} : { width: image.width }),
            ...(image.height === undefined ? {} : { height: image.height }),
            lazy: true,
        });
        const caption = imagePresentationText(
            image.title,
            "tool-image-caption",
            image.sourceUrl,
        );
        return H.div()
            .class("tool-image-card")
            .append(previewLink, caption)
            .el();
    }));
}

function updateReasoningView(
    section: HTMLElement,
    message: ChatMessage,
    speech: ChatSpeechState,
    text: UiText,
    handlers: ChatTranscriptHandlers,
): void {
    let box = section.querySelector<HTMLElement>(".reasoning-box");
    if (box === null) {
        const viewport = H.div().class("reasoning-viewport").el();
        box = H.div()
            .class("reasoning-box")
            .append(viewport, messageActionBar())
            .el();
        section.replaceChildren(box);
    }
    section.className = "message message-reasoning";
    const viewport = box.querySelector<HTMLElement>(".reasoning-viewport")!;
    viewport.textContent = message.text;
    if (message.reasoningDurationMs === undefined) box.removeAttribute("title");
    else box.title = `${text.turnDurationMetric}: `
        + formatDetailedDuration(message.reasoningDurationMs);
    syncReasoningActions(box, message, speech, text, handlers);
}

function syncReasoningActions(
    box: HTMLElement,
    message: ChatMessage,
    speech: ChatSpeechState,
    text: UiText,
    handlers: ChatTranscriptHandlers,
): void {
    const turnId = message.turnId!;
    const itemId = message.itemId!;
    const actions = box.querySelector<HTMLElement>(":scope > .message-actions")!;
    const playing = speech.active?.kind === "reasoning"
        && speech.active.turnId === turnId
        && speech.active.itemId === itemId;
    syncMessageAction(
        actions,
        "playback",
        playing ? "/icons/stop.svg" : "/icons/speaker.svg",
        playing ? text.stopPlayback : text.speakReasoning,
        playing ? handlers.onStopPlayback : () => handlers.onSpeakReasoning(turnId, itemId),
    );
    syncMessageAction(
        actions,
        "copy",
        "/icons/copy.svg",
        text.copyReasoning,
        () => void handlers.onLoadReasoning(turnId, itemId)
            .then(value => navigator.clipboard.writeText(value))
            .catch((error: unknown) => console.error("Copying reasoning failed", error)),
    );
    if (!message.pending && !turnId.startsWith("codex:")) syncMessageAction(
        actions,
        "branch",
        "/icons/branch.svg",
        text.branchChatHere,
        () => handlers.onBranch({ turnId, kind: "reasoning", itemId }),
    );
}

interface RenderedActivityMessage {
    readonly element: HTMLElement;
    readonly role: ChatMessage["role"];
}
