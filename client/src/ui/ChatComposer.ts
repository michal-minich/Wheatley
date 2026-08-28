import type { SessionPhase } from "../chat/ChatSession";
import type { ChatLanguage } from "../chat/Language";
import { Er } from "../core/Er";
import type { ModelInfo, ReasoningMode, UserImage } from "../transport/ChatTransport";
import { H } from "./h";
import {
    composerCancelIcon,
    icon,
    imageIcon,
    sendIcon,
    waveformIcon,
} from "./Icons";
import {
    type AudioLevelSource,
    RecordingWaveform,
    type RecordingWaveformMode,
} from "./RecordingWaveform";
import { reasoningBadge, reasoningTooltip } from "./ReasoningText";
import { uiText } from "./UiText";

export interface ChatComposerHandlers {
    readonly onSend: (text: string) => Promise<boolean>;
    readonly onStop: () => void;
    readonly onStartLiveListening: () => void;
    readonly onCancelLiveListening: () => void;
    readonly onSubmitLiveListening: () => void;
    readonly onToggleReasoning: () => void;
    readonly onModelChange: (modelId: string) => void;
    readonly onImageSelected: (file: File | undefined) => void;
    readonly onInteraction: () => void;
}

export class ChatComposer {
    readonly element: HTMLElement;
    readonly #handlers: ChatComposerHandlers;
    readonly #input: HTMLTextAreaElement;
    readonly #waveform: RecordingWaveform;
    readonly #liveButton: HTMLButtonElement;
    readonly #sendButton: HTMLButtonElement;
    readonly #cancelLiveButton: HTMLButtonElement;
    readonly #stopResponseButton: HTMLButtonElement;
    readonly #modelSelect: HTMLSelectElement;
    readonly #reasoningButton: HTMLButtonElement;
    readonly #imageControl: HTMLElement;
    readonly #imageButton: HTMLButtonElement;
    readonly #removeImageButton: HTMLButtonElement;
    readonly #imageInput: HTMLInputElement;
    readonly #models: readonly ModelInfo[];
    #phase: SessionPhase = "launcher";
    #language: ChatLanguage = "en";
    #pendingImage: UserImage | undefined;
    #submitting = false;

    constructor(
        handlers: ChatComposerHandlers,
        recordingLevels: AudioLevelSource,
        models: readonly ModelInfo[],
    ) {
        this.#handlers = handlers;
        this.#models = models;
        this.#waveform = new RecordingWaveform(recordingLevels);
        this.#input = H.textarea()
            .class("composer-input")
            .attr("rows", "1")
            .on("keydown", event => {
                if (event.key === "Enter" && !event.shiftKey) {
                    event.preventDefault();
                    void this.#submit();
                }
            })
            .on("input", () => {
                handlers.onInteraction();
                this.#renderActions();
                this.#resize();
            })
            .el();
        this.#liveButton = H.button()
            .class("chat-button", "chat-button-quiet", "composer-icon-button")
            .attr("type", "button")
            .on("click", handlers.onStartLiveListening)
            .append(waveformIcon())
            .el();
        this.#sendButton = H.button()
            .class("chat-button", "chat-button-primary", "composer-icon-button")
            .attr("type", "button")
            .on("click", () => void this.#submit())
            .append(sendIcon())
            .el();
        this.#cancelLiveButton = H.button()
            .class("chat-button", "chat-button-cancel", "composer-icon-button")
            .attr("type", "button")
            .on("click", handlers.onCancelLiveListening)
            .append(composerCancelIcon())
            .el();
        this.#stopResponseButton = H.button()
            .class("chat-button", "chat-button-cancel", "composer-icon-button")
            .attr("type", "button")
            .on("click", handlers.onStop)
            .append(composerCancelIcon())
            .el();
        this.#modelSelect = H.select()
            .class("composer-model-select")
            .on("change", () => handlers.onModelChange(this.#modelSelect.value))
            .el();
        this.#modelSelect.replaceChildren(...models.map(model => H.option()
            .attr("value", model.id)
            .text(model.name)
            .el()));
        this.#reasoningButton = H.button()
            .class("chat-button", "chat-button-quiet", "composer-icon-button",
                "chat-reasoning-button")
            .attr("type", "button")
            .on("click", handlers.onToggleReasoning)
            .append(icon("/icons/brain.svg"))
            .el();
        this.#imageInput = H.input()
            .attr("type", "file")
            .attr("accept", "image/*")
            .class("composer-image-input")
            .on("change", () => {
                const file = this.#imageInput.files?.item(0) ?? undefined;
                this.#imageInput.value = "";
                if (file !== undefined)
                    handlers.onImageSelected(file);
            })
            .el();
        this.#imageButton = H.button()
            .class("chat-button", "chat-button-quiet", "composer-icon-button",
                "composer-image-button")
            .attr("type", "button")
            .on("click", () => this.#imageInput.click())
            .append(imageIcon())
            .el();
        this.#removeImageButton = H.button()
            .class("composer-image-remove")
            .attr("type", "button")
            .text("×")
            .on("click", () => handlers.onImageSelected(undefined))
            .el();
        this.#imageControl = H.div()
            .class("composer-image-control")
            .append(this.#imageButton, this.#removeImageButton, this.#imageInput)
            .el();
        const modelControl = H.div()
            .class("composer-model-control")
            .append(this.#reasoningButton, this.#modelSelect)
            .el();
        const actions = H.div()
            .class("composer-actions")
            .append(
                this.#cancelLiveButton,
                this.#liveButton,
                this.#sendButton,
                this.#stopResponseButton,
            )
            .el();
        this.element = H.div()
            .class("composer")
            .append(modelControl, this.#imageControl, this.#input,
                this.#waveform.element, actions)
            .el();
    }

    render(
        phase: SessionPhase,
        continuousMicrophone: boolean,
        language: ChatLanguage,
        profileName: string,
        modelId: string,
        reasoningMode: ReasoningMode,
        pendingImage: UserImage | undefined,
        visionRequired: boolean,
    ): void {
        this.#phase = phase;
        this.#language = language;
        this.#pendingImage = pendingImage;
        const text = uiText(language);
        const active = phase === "preparing" || phase === "ready"
            || phase === "streaming" || phase === "stopping" || phase === "scheduled-yield";
        const liveActive = phase === "requesting-live-microphone"
            || phase === "live-listening" || phase === "live-transcribing";
        const canCompose = phase === "preparing" || phase === "ready" || phase === "streaming";
        const placeholder = text.messageFor(profileName);
        this.element.hidden = !(active || liveActive);
        const waveformMode = recordingWaveformMode(phase, continuousMicrophone);
        this.#input.hidden = waveformMode !== "hidden";
        this.#input.disabled = !canCompose || this.#submitting;
        this.#input.placeholder = placeholder;
        this.#input.setAttribute("aria-label", placeholder);
        this.#waveform.render(
            waveformMode,
            waveformMode === "sending"
                ? text.finalizingLiveSpeech
                : text.liveListening,
        );
        this.#modelSelect.value = modelId;
        for (const option of this.#modelSelect.options) {
            const model = this.#models.find(candidate => candidate.id === option.value)!;
            option.disabled = (visionRequired || pendingImage !== undefined) && !model.vision;
        }
        this.#modelSelect.setAttribute("aria-label", text.model);
        this.#modelSelect.title = this.#model().name;
        const model = this.#model();
        const effectiveReasoningMode = model.reasoningModes.includes(reasoningMode)
            ? reasoningMode
            : model.reasoningModes[0]!;
        const reasoningEnabled = effectiveReasoningMode !== "off";
        this.#reasoningButton.disabled = !model.reasoning || model.reasoningModes.length < 2;
        this.#reasoningButton.classList.toggle(
            "chat-reasoning-button-active",
            reasoningEnabled,
        );
        this.#reasoningButton.setAttribute("aria-pressed", String(reasoningEnabled));
        const reasoningLevelBadge = reasoningBadge(
            model.reasoningModes,
            effectiveReasoningMode,
        );
        if (reasoningLevelBadge.length === 0)
            delete this.#reasoningButton.dataset["level"];
        else
            this.#reasoningButton.dataset["level"] = reasoningLevelBadge;
        label(this.#reasoningButton, reasoningTooltip(
            text,
            model.reasoningModes,
            effectiveReasoningMode,
        ));
        const imageSupported = this.#model().vision;
        this.#imageControl.hidden = !imageSupported;
        const image = pendingImage;
        this.#imageButton.replaceChildren(image === undefined
            ? imageIcon()
            : H.img().attr("src", image.url).attr("alt", image.filename).el());
        this.#imageButton.classList.toggle("composer-image-button-selected", image !== undefined);
        label(this.#imageButton, image === undefined ? text.chooseImage : text.replaceImage);
        this.#removeImageButton.hidden = image === undefined;
        label(this.#removeImageButton, text.removeImage);
        this.#renderActions();
        if (active && waveformMode === "hidden")
            this.#resize();
    }

    async #submit(): Promise<void> {
        if (this.#phase === "live-listening") {
            this.#handlers.onSubmitLiveListening();
            return;
        }
        const text = this.#input.value.trim();
        if (text.length === 0 && this.#pendingImage === undefined)
            return;
        if (this.#submitting)
            return;
        this.#submitting = true;
        this.#renderActions();
        this.#input.disabled = true;
        try {
            if (await this.#handlers.onSend(text)) {
                this.#input.value = "";
                this.#resize();
            }
        } finally {
            this.#submitting = false;
            this.#input.disabled = !(this.#phase === "preparing"
                || this.#phase === "ready" || this.#phase === "streaming");
            this.#renderActions();
        }
    }

    #renderActions(): void {
        const text = uiText(this.#language);
        const idle = this.#phase === "preparing" || this.#phase === "ready";
        const canCompose = idle || this.#phase === "streaming";
        const liveRequesting = this.#phase === "requesting-live-microphone";
        const liveListening = this.#phase === "live-listening";
        const liveTranscribing = this.#phase === "live-transcribing";
        const liveCapture = liveRequesting || liveListening || liveTranscribing;
        const responding = this.#phase === "streaming" || this.#phase === "stopping";
        const hasText = this.#input.value.trim().length > 0;
        const hasImage = this.#pendingImage !== undefined;

        this.#liveButton.hidden = !(idle && !hasText);
        label(this.#liveButton, text.liveListen);

        this.#sendButton.hidden = !(canCompose && (hasText || hasImage)) && !liveCapture;
        this.#sendButton.disabled = this.#submitting || liveRequesting || liveTranscribing;
        label(
            this.#sendButton,
            liveCapture ? text.submitLiveSpeech : text.send,
        );

        this.#cancelLiveButton.hidden = !liveCapture;
        label(this.#cancelLiveButton, text.cancelLiveSpeech);

        this.#stopResponseButton.hidden = !responding || hasText || hasImage;
        this.#stopResponseButton.disabled = this.#phase === "stopping";
        label(
            this.#stopResponseButton,
            this.#phase === "stopping" ? text.stopping : text.stop,
        );
    }

    #resize(): void {
        const style = window.getComputedStyle(this.#input);
        const parsedLineHeight = Number.parseFloat(style.lineHeight);
        const lineHeight = Number.isFinite(parsedLineHeight) ? parsedLineHeight : 20;
        const padding = Number.parseFloat(style.paddingTop)
            + Number.parseFloat(style.paddingBottom);
        const border = Number.parseFloat(style.borderTopWidth)
            + Number.parseFloat(style.borderBottomWidth);
        const maxHeight = lineHeight * 6 + padding + border;
        this.#input.style.height = "auto";
        this.#input.style.height = `${Math.min(this.#input.scrollHeight + border, maxHeight)}px`;
    }

    #model(): ModelInfo {
        return this.#models.find(model => model.id === this.#modelSelect.value)
            ?? Er.internal(`Selected model ${this.#modelSelect.value} is unavailable.`);
    }
}

function recordingWaveformMode(
    phase: SessionPhase,
    continuousMicrophone: boolean,
): RecordingWaveformMode {
    if (continuousMicrophone && (phase === "requesting-live-microphone"
        || phase === "live-listening" || phase === "live-transcribing"))
        return "live";
    if (phase === "requesting-live-microphone" || phase === "live-listening")
        return "live";
    if (phase === "live-transcribing")
        return "sending";
    return "hidden";
}

function label(button: HTMLButtonElement, value: string): void {
    button.setAttribute("aria-label", value);
    button.title = value;
}
