import type { ChatMessage } from "../chat/ChatMessage";
import type { ModelInfo } from "../transport/ChatTransport";
import type { ChatSessionSnapshot } from "../chat/ChatSession";
import type { ChatSpeechState } from "../chat/ChatSpeech";
import { ChatActivityView } from "./ChatActivityView";
import { H } from "./h";
import { icon } from "./Icons";
import { imagePresentationText, linkedImageFrame } from "./ImagePresentation";
import {
    formatCompactDuration,
    formatDetailedDuration,
    formatLocalDateTime,
} from "./LocalDateTime";
import { renderMarkdown, updateMarkdown } from "./Markdown";
import { messageActionBar, syncMessageAction } from "./MessageActions";
import { type UiText, uiText } from "./UiText";
import { isActivityMessage } from "../chat/ChatMessage";
import { isNearBottom, reconcileChildren } from "./DomList";
import type { ChatTranscriptHandlers } from "./ChatViewHandlers";
import { imagePageUrl, uploadedImagePageUrl } from "../app/ImagePage";
import { turnMetricsTooltip } from "./TurnMetricsText";
import { modelReasoningModes, reasoningTooltip } from "./ReasoningText";

export class ChatTranscriptView {
    readonly element: HTMLElement;
    readonly activityPane: HTMLElement;
    readonly #messageList: HTMLElement;
    readonly #error: HTMLElement;
    readonly #handlers: ChatTranscriptHandlers;
    readonly #activity: ChatActivityView;
    #renderedMessages = new Map<string, RenderedMessage>();
    #showCompactedContext: boolean;
    #errorVersion: number | undefined;

    constructor(
        handlers: ChatTranscriptHandlers,
        activityPaneOpen: boolean,
        showThinking: boolean,
        showCompactedContext: boolean,
    ) {
        this.#handlers = handlers;
        this.#showCompactedContext = showCompactedContext;
        this.#messageList = H.div().class("message-list").el();
        this.#error = H.div().class("chat-error", "chat-main-error").el();
        this.#activity = new ChatActivityView(
            handlers,
            activityPaneOpen,
            showThinking,
        );
        this.activityPane = this.#activity.pane;
        this.element = H.div()
            .class("chat-transcript")
            .append(this.#messageList, this.#error)
            .el();
    }

    render(snapshot: ChatSessionSnapshot): void {
        const text = uiText(snapshot.language);
        this.#activity.render(
            snapshot.messages,
            snapshot.speech,
            text,
            snapshot.activeActivity,
            snapshot.profileId,
            snapshot.currentSessionId,
        );
        this.#renderMessages(
            snapshot.messages,
            snapshot.speech,
            text,
            snapshot.models,
            snapshot.profileId,
            snapshot.currentSessionId,
        );
        this.#error.textContent = snapshot.error ?? "";
        this.#error.hidden = snapshot.error === undefined || snapshot.phase === "launcher";
        this.#restartErrorDismissal(snapshot.errorVersion, !this.#error.hidden);
    }

    setActivityPaneOpen(open: boolean): void {
        this.#activity.setOpen(open);
    }

    setShowThinking(show: boolean): void {
        this.#activity.setShowThinking(show);
    }

    setShowCompactedContext(show: boolean): void {
        this.#showCompactedContext = show;
        for (const summary of this.#messageList.querySelectorAll<HTMLElement>(
            ".message-compaction-summary",
        )) summary.hidden = !show;
        for (const button of this.#messageList.querySelectorAll<HTMLButtonElement>(
            ".message-compaction-separator",
        )) button.setAttribute("aria-expanded", String(show));
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

    #renderMessages(
        messages: readonly ChatMessage[],
        speech: ChatSpeechState,
        text: UiText,
        models: readonly ModelInfo[],
        profileId: string,
        sessionId?: string,
    ): void {
        const followLatest = isNearBottom(this.#messageList);
        const nextMessages = new Map<string, RenderedMessage>();
        const elements: HTMLElement[] = [];
        const activityPreviews = new Set<HTMLElement>();
        const imageCounts = { generated_image: 0, screen_capture: 0 };
        let uploadedImageCount = 0;
        for (const message of messages) {
            if (isActivityMessage(message)) {
                const preview = this.#activity.previewFor(message);
                if (!activityPreviews.has(preview)) {
                    activityPreviews.add(preview);
                    elements.push(preview);
                }
                continue;
            }
            const imagePageHref = message.generatedImage === undefined || sessionId === undefined
                ? undefined
                : imagePageUrl(
                    message.generatedImage.url,
                    profileId,
                    sessionId,
                    message.generatedImage.kind === "screen_capture"
                        ? "screenshot"
                        : "generated-image",
                    ++imageCounts[message.generatedImage.kind],
                );
            const uploadedImagePageHref = message.userImage === undefined || sessionId === undefined
                ? undefined
                : uploadedImagePageUrl(
                    message.userImage.url,
                    profileId,
                    sessionId,
                    message.userImage.filename,
                    ++uploadedImageCount,
                );
            const current = this.#renderedMessages.get(message.id);
            const playing = messageIsPlaying(message, speech);
            let element: HTMLElement;
            if (message.role === "compaction") {
                element = current !== undefined && sameMessage(current.message, message)
                    ? current.element
                    : compactionMessageView(message, text, this.#showCompactedContext);
            } else if (
                current !== undefined
                && sameMessage(current.message, message)
                && current.playing === playing
                && current.imagePageUrl === imagePageHref
                && current.uploadedImagePageUrl === uploadedImagePageHref
            ) {
                element = current.element;
            } else if (
                current?.message.role === "assistant"
                && message.role === "assistant"
                && (current.message.pending || message.pending)
                && current.element.querySelector(".message-bubble") !== null
            ) {
                updateAssistantView(
                    current.element,
                    message,
                    speech,
                    text,
                    models,
                    this.#handlers,
                    imagePageHref,
                );
                element = current.element;
            } else if (
                current?.message.role === "user"
                && message.role === "user"
                && (current.message.pending || message.pending)
            ) {
                updateUserView(
                    current.element,
                    message,
                    speech,
                    text,
                    this.#handlers,
                    uploadedImagePageHref,
                );
                element = current.element;
            } else {
                element = messageView(
                    message,
                    speech,
                    text,
                    models,
                    this.#handlers,
                    imagePageHref,
                    uploadedImagePageHref,
                );
            }
            nextMessages.set(message.id, {
                element,
                message,
                playing,
                imagePageUrl: imagePageHref,
                uploadedImagePageUrl: uploadedImagePageHref,
            });
            elements.push(element);
        }
        reconcileChildren(this.#messageList, elements);
        this.#renderedMessages = nextMessages;
        if (followLatest)
            this.#messageList.scrollTop = this.#messageList.scrollHeight;
    }
}




interface RenderedMessage {
    readonly element: HTMLElement;
    readonly message: ChatMessage;
    readonly playing: boolean;
    readonly imagePageUrl: string | undefined;
    readonly uploadedImagePageUrl: string | undefined;
}

function messageView(
    message: ChatMessage,
    speech: ChatSpeechState,
    text: UiText,
    models: readonly ModelInfo[],
    handlers: ChatTranscriptHandlers,
    imagePageUrl?: string,
    uploadedImagePageUrl?: string,
): HTMLElement {
    if (
        message.role === "assistant"
        && message.pending
        && message.text.length === 0
        && message.pendingGeneratedImage === undefined
    )
        return waitingAssistantView(text.working);
    const bubble = H.div()
        .class("message-bubble")
        .append(...messageContent(message, text, imagePageUrl, uploadedImagePageUrl))
        .el();
    const tooltip = messageTooltip(message, text, models);
    if (tooltip !== undefined)
        bubble.title = tooltip;
    syncMessageActions(bubble, message, speech, text, handlers);
    const section = H.section().class("message", `message-${message.role}`);
    if (message.role === "user" && message.pending)
        section.class("message-user-pending");
    if (message.role === "user" && message.queueState === "cancelled")
        section.class("message-user-cancelled");
    if (message.failure !== undefined)
        section.class("message-failure");
    return section.append(bubble).el();
}

function compactionMessageView(
    message: ChatMessage,
    text: UiText,
    showSummary: boolean,
): HTMLElement {
    const compaction = message.compaction;
    if (compaction === undefined)
        throw new Error("Compaction message has no compaction event.");
    const summary = H.div()
        .class("message-compaction-summary", "message-markdown")
        .append(renderMarkdown(compaction.summary))
        .el();
    summary.hidden = !showSummary || compaction.summary.length === 0;
    const label = H.span().el();
    const separator = H.button()
        .class("message-compaction-separator")
        .attr("type", "button")
        .attr("aria-expanded", String(!summary.hidden))
        .append(H.span().class("message-compaction-line").el(), label,
            H.span().class("message-compaction-line").el())
        .on("click", () => {
            if (compaction.summary.length === 0)
                return;
            summary.hidden = !summary.hidden;
            separator.setAttribute("aria-expanded", String(!summary.hidden));
        })
        .el();
    const updateLabel = (): void => {
        const durationMs = compaction.status === "compacting"
            ? Math.max(0, Date.now() - Date.parse(compaction.startedAt))
            : compaction.durationMs;
        const title = compaction.status === "compacting" ? text.compactingContext
            : compaction.status === "completed" ? text.contextCompacted
                : text.contextCompactionFailed;
        label.textContent = `${title.replace(/…$/u, "")} · ${formatCompactDuration(durationMs)}`;
    };
    updateLabel();
    if (compaction.status === "compacting") {
        const timer = globalThis.setInterval(() => {
            if (!separator.isConnected) {
                globalThis.clearInterval(timer);
                return;
            }
            updateLabel();
        }, 1_000);
    }
    if (compaction.errorMessage.length > 0)
        separator.title = compaction.errorMessage;
    return H.section()
        .class("message", "message-compaction")
        .append(separator, summary)
        .el();
}

function updateUserView(
    section: HTMLElement,
    message: ChatMessage,
    speech: ChatSpeechState,
    text: UiText,
    handlers: ChatTranscriptHandlers,
    uploadedImagePageUrl?: string,
): void {
    section.classList.toggle("message-user-pending", message.pending);
    section.classList.toggle("message-user-cancelled", message.queueState === "cancelled");
    const bubble = section.querySelector<HTMLElement>(".message-bubble")!;
    const actions = bubble.querySelector<HTMLElement>(":scope > .message-actions");
    bubble.replaceChildren(...messageContent(message, text, undefined, uploadedImagePageUrl));
    if (actions !== null)
        bubble.append(actions);
    syncMessageActions(bubble, message, speech, text, handlers);
}

function waitingAssistantView(label: string): HTMLElement {
    const ornament = document.createElement("img");
    ornament.src = "/icons/leaf.svg";
    ornament.alt = "";
    ornament.setAttribute("aria-hidden", "true");
    return H.section()
        .class("message", "message-assistant-waiting")
        .attr("role", "status")
        .attr("aria-label", label)
        .append(ornament)
        .el();
}

function messageTooltip(
    message: ChatMessage,
    text: UiText,
    models: readonly ModelInfo[],
): string | undefined {
    const time = message.timestamp === undefined
        ? undefined
        : `${text.dateTimeMetric}: ${formatLocalDateTime(message.timestamp)}`;
    const model = message.role === "assistant" && message.modelName !== undefined
        ? `${text.model}: ${modelTooltipName(message.modelName)}`
        : undefined;
    const reasoningBudget = message.role === "assistant" && message.reasoningMode !== undefined
        ? reasoningTooltip(
            text,
            message.modelName === undefined
                ? []
                : modelReasoningModes(models, message.modelName),
            message.reasoningMode,
        )
        : undefined;
    const durationMs = message.reasoningDurationMs
        ?? message.tool?.durationMs
        ?? message.turnMetrics?.durationMs
        ?? message.activityDurationMs;
    const duration = durationMs === undefined
        ? undefined
        : `${text.turnDurationMetric}: ${formatDetailedDuration(durationMs)}`;
    const parts = [time, model, reasoningBudget, duration]
        .filter((part): part is string => part !== undefined);
    const metrics = message.role === "assistant"
        ? turnMetricsTooltip(message.turnMetrics, text)
        : [];
    if (!parts.length && !metrics.length) return undefined;
    return [...parts, ...metrics].filter(part => part.length > 0).join("\n");
}

function modelTooltipName(modelName: string): string {
    return modelName.startsWith("pi:") ? modelName.slice(3) : modelName;
}

function messageText(message: ChatMessage): HTMLElement {
    const text = H.div().class("message-text").el();
    if (message.failure !== undefined) {
        text.append(H.div().class("message-failure-summary").text(message.text).el());
        const summary = document.createElement("summary");
        summary.textContent = message.failure.detailsLabel;
        const detail = document.createElement("pre");
        detail.textContent = `${message.failure.code}: ${message.failure.detail}`;
        const details = document.createElement("details");
        details.classList.add("message-failure-detail");
        details.append(summary, detail);
        text.append(details);
        return text;
    }
    if (message.scheduledTask) {
        const marker = icon("/icons/bell.svg");
        marker.classList.add("message-scheduled-task-icon");
        text.append(marker);
    }
    if (message.role === "assistant" && message.text.length > 0) {
        text.classList.add("message-markdown");
        text.append(renderMarkdown(message.text));
    } else {
        text.textContent = message.text;
    }
    return text;
}

function messageContent(
    message: ChatMessage,
    text: UiText,
    imagePageUrl?: string,
    uploadedImagePageUrl?: string,
): HTMLElement[] {
    const content: HTMLElement[] = [];
    if (message.userImage !== undefined) {
        const image = H.img()
            .class("message-user-image")
            .attr("src", message.userImage.url)
            .attr("alt", message.userImage.filename)
            .el();
        const link = document.createElement("a");
        link.classList.add("message-user-image-link");
        link.href = uploadedImagePageUrl ?? message.userImage.url;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
        link.title = message.userImage.filename;
        link.append(image);
        content.push(link);
    }
    if (message.pendingGeneratedImage !== undefined) {
        const preview = message.pendingGeneratedImage;
        const placeholder = generatedImageFrame(preview.width, preview.height);
        placeholder.classList.add("message-generated-image-placeholder");
        placeholder.setAttribute("role", "status");
        placeholder.setAttribute("aria-label", preview.prompt);
        content.push(placeholder);
        content.push(imagePresentationText(preview.prompt, "message-generated-prompt"));
    } else if (message.generatedImage !== undefined) {
        const modelPageUrl = screenCaptureModelPageUrl(
            message.generatedImage,
            imagePageUrl,
        );
        const link = linkedImageFrame({
            url: message.generatedImage.url,
            ...(imagePageUrl === undefined ? {} : { pageUrl: imagePageUrl }),
            alt: "",
            frameClass: "message-generated-image-link",
            imageClass: "message-generated-image",
            width: message.generatedImage.width,
            height: message.generatedImage.height,
        });
        sizeGeneratedImageFrame(link, message.generatedImage.width, message.generatedImage.height);
        content.push(link);
        const caption = imagePresentationText(
            message.generatedImage.generatedImageId === undefined
                ? message.generatedImage.prompt
                : text.generatedImageLabel(message.generatedImage.generatedImageId)
                    + ` — ${message.generatedImage.prompt}`,
            "message-generated-prompt",
            modelPageUrl,
        );
        if (modelPageUrl !== undefined)
            caption.classList.add("message-screen-capture-prompt");
        content.push(caption);
    }
    content.push(messageText(message));
    return content;
}

function screenCaptureModelPageUrl(
    image: NonNullable<ChatMessage["generatedImage"]>,
    imagePageUrl?: string,
): string | undefined {
    if (
        image.kind !== "screen_capture"
        || imagePageUrl === undefined
        || image.modelWidth === undefined
        || image.modelHeight === undefined
        || image.modelWidth >= image.width
        || image.modelHeight >= image.height
    ) return undefined;
    return `${imagePageUrl}/model`;
}

function generatedImageFrame(width: number, height: number): HTMLDivElement {
    const frame = H.div()
        .class("image-presentation-frame", "message-generated-image-frame")
        .el();
    sizeGeneratedImageFrame(frame, width, height);
    return frame;
}

function sizeGeneratedImageFrame(element: HTMLElement, width: number, height: number): void {
    const viewportHeightWidth = (width / height * 68).toFixed(4);
    element.style.width = `min(${width}px, 720px, 86vw, ${viewportHeightWidth}vh)`;
    element.style.aspectRatio = `${width} / ${height}`;
}

function updateAssistantView(
    section: HTMLElement,
    message: ChatMessage,
    speech: ChatSpeechState,
    text: UiText,
    models: readonly ModelInfo[],
    handlers: ChatTranscriptHandlers,
    imagePageUrl?: string,
): void {
    const bubble = section.querySelector<HTMLElement>(".message-bubble")!;
    if (
        message.pendingGeneratedImage !== undefined
        || message.generatedImage !== undefined
        || bubble.querySelector(".message-generated-image-placeholder") !== null
        || bubble.querySelector(".message-generated-image") !== null
    ) {
        const actions = bubble.querySelector<HTMLElement>(":scope > .message-actions");
        bubble.replaceChildren(...messageContent(message, text, imagePageUrl));
        if (actions !== null)
            bubble.append(actions);
    }
    const currentText = bubble.querySelector<HTMLElement>(".message-text")!;
    if (message.text.length > 0 && currentText.classList.contains("message-markdown")) {
        updateMarkdown(currentText, message.text);
    } else {
        currentText.replaceWith(messageText(message));
    }
    const tooltip = messageTooltip(message, text, models);
    if (tooltip === undefined)
        bubble.removeAttribute("title");
    else
        bubble.title = tooltip;
    syncMessageActions(bubble, message, speech, text, handlers);
}


function sameMessage(left: ChatMessage, right: ChatMessage): boolean {
    return left.role === right.role
        && left.text === right.text
        && left.pending === right.pending
        && left.turnId === right.turnId
        && left.queueItemId === right.queueItemId
        && left.queueState === right.queueState
        && left.queueSequence === right.queueSequence
        && left.itemId === right.itemId
        && left.timestamp === right.timestamp
        && left.modelName === right.modelName
        && left.reasoningMode === right.reasoningMode
        && sameTurnMetrics(left, right)
        && left.scheduledTask === right.scheduledTask
        && left.userAudioUrl === right.userAudioUrl
        && left.userImage?.url === right.userImage?.url
        && left.userImage?.filename === right.userImage?.filename
        && left.generatedImage?.sha256 === right.generatedImage?.sha256
        && left.generatedImage?.modelWidth === right.generatedImage?.modelWidth
        && left.generatedImage?.modelHeight === right.generatedImage?.modelHeight
        && left.pendingGeneratedImage?.callIndex === right.pendingGeneratedImage?.callIndex
        && left.pendingGeneratedImage?.prompt === right.pendingGeneratedImage?.prompt
        && left.pendingGeneratedImage?.width === right.pendingGeneratedImage?.width
        && left.pendingGeneratedImage?.height === right.pendingGeneratedImage?.height
        && left.compaction?.status === right.compaction?.status
        && left.compaction?.durationMs === right.compaction?.durationMs
        && left.compaction?.summary === right.compaction?.summary
        && left.compaction?.errorMessage === right.compaction?.errorMessage
        && left.failure?.code === right.failure?.code
        && left.failure?.detail === right.failure?.detail
        && left.failure?.detailsLabel === right.failure?.detailsLabel;
}

function sameTurnMetrics(left: ChatMessage, right: ChatMessage): boolean {
    return left.turnMetrics?.durationMs === right.turnMetrics?.durationMs
        && left.turnMetrics?.timeToFirstTokenMs === right.turnMetrics?.timeToFirstTokenMs
        && left.turnMetrics?.generationMs === right.turnMetrics?.generationMs
        && left.turnMetrics?.inputTokens === right.turnMetrics?.inputTokens
        && left.turnMetrics?.outputTokens === right.turnMetrics?.outputTokens
        && left.turnMetrics?.cacheReadTokens === right.turnMetrics?.cacheReadTokens
        && left.turnMetrics?.cacheWriteTokens === right.turnMetrics?.cacheWriteTokens
        && left.turnMetrics?.reasoningTokens === right.turnMetrics?.reasoningTokens
        && left.turnMetrics?.totalTokens === right.turnMetrics?.totalTokens
        && left.turnMetrics?.contextTokens === right.turnMetrics?.contextTokens
        && left.turnMetrics?.contextWindowTokens === right.turnMetrics?.contextWindowTokens;
}

function messageIsPlaying(message: ChatMessage, speech: ChatSpeechState): boolean {
    const kind = message.role === "assistant" ? "assistant"
        : message.role === "user" ? "user"
            : undefined;
    return kind !== undefined
        && speech.active?.kind === kind
        && speech.active.turnId === message.turnId
        && speech.active.itemId === (kind === "user" ? undefined : message.itemId);
}

function syncMessageActions(
    bubble: HTMLElement,
    message: ChatMessage,
    speech: ChatSpeechState,
    text: UiText,
    handlers: ChatTranscriptHandlers,
): void {
    const visible = (
        message.text.length > 0
        || !message.pending
        || message.pendingGeneratedImage !== undefined
        || isCancellableQueuedMessage(message)
    )
        && !(message.role === "user" && message.pending
            && !isCancellableQueuedMessage(message));
    let actions = bubble.querySelector<HTMLElement>(":scope > .message-actions");
    if (!visible) {
        actions?.remove();
        return;
    }
    if (actions === null) {
        actions = messageActionBar();
        bubble.append(actions);
    }
    const turnId = message.turnId;
    const itemId = message.itemId;
    if (isCancellableQueuedMessage(message) && message.turnId !== undefined) {
        syncMessageAction(
            actions,
            "cancel",
            "/icons/composer-cancel.svg",
            text.cancelQueuedMessage,
            () => handlers.onCancelQueued(message.queueItemId!, message.turnId!),
        );
    }
    if (
        message.role === "assistant"
        && turnId !== undefined
        && itemId !== undefined
        && message.pendingGeneratedImage === undefined
    ) {
        const playing = speech.active?.kind === "assistant"
            && speech.active.turnId === turnId
            && speech.active.itemId === itemId;
        syncMessageAction(
            actions,
            "playback",
            playing ? "/icons/stop.svg" : "/icons/speaker.svg",
            playing ? text.stopPlayback : text.speakMessage,
            playing ? handlers.onStopPlayback : () => handlers.onSpeak(turnId, itemId),
        );
    } else if (
        message.pendingGeneratedImage !== undefined
        && turnId !== undefined
        && itemId !== undefined
    ) {
        const pending = message.pendingGeneratedImage;
        const playing = speech.active?.kind === "assistant"
            && speech.active.turnId === turnId
            && speech.active.itemId === itemId;
        syncMessageAction(
            actions,
            "playback",
            playing ? "/icons/stop.svg" : "/icons/speaker.svg",
            playing ? text.stopPlayback : text.speakMessage,
            playing
                ? handlers.onStopPlayback
                : () => handlers.onSpeakText(turnId, itemId, pending.prompt),
        );
    }
    const userAudioUrl = message.userAudioUrl;
    if (message.role === "user" && turnId !== undefined && userAudioUrl !== undefined) {
        const playing = speech.active?.kind === "user"
            && speech.active.turnId === turnId;
        syncMessageAction(
            actions,
            "playback",
            playing ? "/icons/stop.svg" : "/icons/speaker.svg",
            playing ? text.stopPlayback : text.playRecording,
            playing
                ? handlers.onStopPlayback
                : () => handlers.onPlayUserAudio(turnId, userAudioUrl),
        );
    }
    const copyText = message.generatedImage?.prompt
        ?? message.pendingGeneratedImage?.prompt
        ?? message.text;
    if (copyText.length > 0) {
        syncMessageAction(
            actions,
            "copy",
            "/icons/copy.svg",
            text.copyMessage,
            () => void navigator.clipboard.writeText(copyText),
        );
    }
    if (
        !message.pending
        && turnId !== undefined
        && !turnId.startsWith("codex:")
        && message.pendingGeneratedImage === undefined
    ) {
        const kind = message.role === "user" ? "user"
            : message.generatedImage !== undefined ? "artifact"
                : message.role === "assistant" ? "assistant"
                    : undefined;
        if (kind !== undefined) syncMessageAction(
            actions,
            "branch",
            "/icons/branch.svg",
            text.branchChatHere,
            () => handlers.onBranch({ turnId, kind, itemId: itemId ?? "" }),
        );
    }
}

function isCancellableQueuedMessage(message: ChatMessage): boolean {
    return message.role === "user"
        && message.pending
        && message.queueItemId !== undefined
        && (message.queueState === "preparing" || message.queueState === "ready");
}
