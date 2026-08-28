import type { ChatLanguage } from "../chat/Language";
import type {
    ChatTransport,
    InstructionDocument,
    InstructionDocumentId,
} from "../transport/ChatTransport";
import { H } from "./h";
import { SegmentedTabs } from "./SegmentedTabs";
import { iconActionButton } from "./UiPrimitives";
import { uiText } from "./UiText";

export interface InstructionEditorHandlers {
    readonly onClose: () => void;
}

export class InstructionEditor {
    readonly element: HTMLElement;
    readonly #api: ChatTransport;
    readonly #handlers: InstructionEditorHandlers;
    readonly #save: HTMLButtonElement;
    readonly #cancel: HTMLButtonElement;
    readonly #tabs: SegmentedTabs<InstructionDocumentId>;
    readonly #textarea: HTMLTextAreaElement;
    readonly #workspacePathLabel: HTMLLabelElement;
    readonly #workspacePath: HTMLInputElement;
    readonly #workspacePathField: HTMLElement;
    readonly #note: HTMLElement;
    readonly #error: HTMLElement;
    #profileId = "";
    #language: ChatLanguage = "en";
    #documents: InstructionDocument[] = [];
    #baseline = "";
    #activeId: InstructionDocumentId = "system";
    #busy = false;
    #open = false;
    readonly #scrollTops = new Map<InstructionDocumentId, number>();

    constructor(api: ChatTransport, handlers: InstructionEditorHandlers) {
        this.#api = api;
        this.#handlers = handlers;
        this.#save = iconActionButton("/icons/check.svg", () => void this.#saveAll());
        this.#cancel = iconActionButton("/icons/close.svg", () => this.close());
        this.#tabs = new SegmentedTabs(id => this.#select(id));
        this.#textarea = H.textarea()
            .class("instruction-textarea")
            .attr("spellcheck", "false")
            .on("input", () => this.#updateActiveDocument())
            .el();
        this.#workspacePath = H.input()
            .class("tool-detail-input", "instruction-workspace-path-input")
            .attr("type", "text")
            .attr("spellcheck", "false")
            .on("input", () => this.#renderActions())
            .el();
        this.#workspacePathLabel = document.createElement("label");
        this.#workspacePathLabel.className = "instruction-workspace-path-label";
        this.#workspacePathLabel.htmlFor = "instruction-workspace-path";
        this.#workspacePath.id = "instruction-workspace-path";
        this.#workspacePathField = H.div().class("instruction-workspace-path").append(
            this.#workspacePathLabel,
            this.#workspacePath,
        ).el();
        this.#workspacePathField.hidden = true;
        this.#note = H.div().class("instruction-note").el();
        this.#error = H.div().class("chat-error", "instruction-error").el();
        this.element = H.section()
            .class("instruction-editor")
            .append(
                H.header().class("instruction-header").append(
                    this.#save,
                    this.#tabs.element,
                    this.#cancel,
                ).el(),
                H.div().class("instruction-body").append(
                    this.#textarea,
                    this.#note,
                    this.#error,
                    this.#workspacePathField,
                ).el(),
            )
            .el();
        this.element.hidden = true;
        document.addEventListener("keydown", event => this.#onKeyDown(event));
    }

    get isOpen(): boolean {
        return this.#open;
    }

    async open(profileId: string, language: ChatLanguage): Promise<void> {
        this.#open = true;
        this.#profileId = profileId;
        this.#language = language;
        this.#documents = [];
        this.#workspacePath.value = "";
        this.#baseline = "";
        this.#activeId = "system";
        this.#scrollTops.clear();
        this.#error.hidden = true;
        this.element.hidden = false;
        this.#setBusy(true);
        this.#renderLabels();
        try {
            const snapshot = await this.#api.loadInstructions(profileId);
            this.#documents = snapshot.documents.map(document => ({ ...document }));
            this.#workspacePath.value = snapshot.workspacePath;
            this.#baseline = this.#serializedDocuments();
            this.#renderTabs();
            this.#showActiveDocument();
        } catch (error: unknown) {
            console.error("Loading instructions failed", error);
            this.#showError(error);
        } finally {
            this.#setBusy(false);
        }
    }

    close(): void {
        if (!this.#open || this.#busy) return;
        this.#open = false;
        this.element.hidden = true;
        this.#handlers.onClose();
    }

    setLanguage(language: ChatLanguage): void {
        if (language === this.#language) return;
        this.#language = language;
        if (this.#open) {
            this.#renderLabels();
            this.#renderTabs();
            this.#renderActiveDocumentLanguage();
        }
    }

    async #saveAll(): Promise<void> {
        if (this.#busy || !this.#changed()) return;
        this.#updateActiveDocument();
        this.#setBusy(true);
        this.#error.hidden = true;
        try {
            const snapshot = await this.#api.saveInstructions(
                this.#profileId,
                this.#documents,
                this.#workspacePath.value,
            );
            this.#documents = snapshot.documents.map(document => ({ ...document }));
            this.#workspacePath.value = snapshot.workspacePath;
            this.#baseline = this.#serializedDocuments();
            this.#setBusy(false);
            this.close();
        } catch (error: unknown) {
            console.error("Saving instructions failed", error);
            this.#showError(error);
            this.#setBusy(false);
        }
    }

    #renderLabels(): void {
        const text = uiText(this.#language);
        this.#save.title = text.saveInstructions;
        this.#save.setAttribute("aria-label", text.saveInstructions);
        this.#cancel.title = text.cancelInstructions;
        this.#cancel.setAttribute("aria-label", text.cancelInstructions);
        this.element.setAttribute("aria-label", text.instructions);
        this.#workspacePathLabel.textContent = text.workspacePath;
        this.#workspacePath.setAttribute("aria-label", text.workspacePath);
    }

    #renderTabs(): void {
        const labels = instructionLabels(uiText(this.#language));
        this.#tabs.render(
            this.#documents.map(document => ({
                id: document.id,
                label: labels[document.id],
            })),
            this.#activeId,
            this.#busy,
        );
    }

    #select(id: InstructionDocumentId): void {
        if (this.#busy || id === this.#activeId) return;
        this.#updateActiveDocument();
        this.#scrollTops.set(this.#activeId, this.#textarea.scrollTop);
        this.#activeId = id;
        this.#renderTabs();
        this.#showActiveDocument();
    }

    #showActiveDocument(): void {
        const document = this.#documents.find(candidate => candidate.id === this.#activeId);
        this.#textarea.value = document?.content ?? "";
        this.#textarea.scrollTop = this.#scrollTops.get(this.#activeId) ?? 0;
        this.#renderActiveDocumentLanguage();
        this.#renderActions();
    }

    #renderActiveDocumentLanguage(): void {
        const text = uiText(this.#language);
        this.#textarea.setAttribute("aria-label", instructionLabels(text)[this.#activeId]);
        this.#note.textContent = this.#activeId === "auto_memory" ? text.autoMemoryNote : "";
        this.#note.hidden = this.#activeId !== "auto_memory";
        this.#workspacePathField.hidden = this.#activeId !== "workspace";
    }

    #updateActiveDocument(): void {
        const index = this.#documents.findIndex(document => document.id === this.#activeId);
        if (index >= 0) {
            const document = this.#documents[index];
            if (document !== undefined) this.#documents[index] = {
                ...document,
                content: this.#textarea.value,
            };
        }
        this.#renderActions();
    }

    #setBusy(busy: boolean): void {
        this.#busy = busy;
        this.#textarea.disabled = busy;
        this.#workspacePath.disabled = busy;
        this.#cancel.disabled = busy;
        this.#renderTabs();
        this.#renderActions();
    }

    #renderActions(): void {
        this.#save.disabled = this.#busy || !this.#changed();
    }

    #changed(): boolean {
        return this.#documents.length > 0 && this.#serializedDocuments() !== this.#baseline;
    }

    #serializedDocuments(): string {
        return JSON.stringify({
            workspacePath: this.#workspacePath.value,
            documents: this.#documents.map(document => [document.id, document.content]),
        });
    }

    #showError(error: unknown): void {
        const message = error instanceof Error ? error.message : String(error);
        this.#error.textContent = message;
        this.#error.hidden = false;
    }

    #onKeyDown(event: KeyboardEvent): void {
        if (!this.#open) return;
        if (event.key === "Escape") {
            event.preventDefault();
            this.close();
        } else if (event.key.toLocaleLowerCase() === "s" && (event.metaKey || event.ctrlKey)) {
            event.preventDefault();
            void this.#saveAll();
        }
    }
}

function instructionLabels(text: ReturnType<typeof uiText>): Record<InstructionDocumentId, string> {
    return {
        system: text.instructionSystem,
        user: text.instructionUser,
        workspace: text.instructionWorkspace,
        auto_memory: text.instructionMemory,
        memory_rules: text.instructionMemoryRules,
    };
}
