import { Er } from "../core/Er";
import type { ChatLanguage } from "../chat/Language";
import type { ToolDetail, ToolDetailStatus, ToolDetailSource } from "../transport/ChatTransport";
import { H } from "./h";
import { detailField, iconActionButton } from "./UiPrimitives";
import { toolDetailText, type ToolDetailLabels } from "./UiText";
import { formatCompactDuration, formatLocalDateTime } from "./LocalDateTime";

type LoadToolDetail = (turnId: string, callIndex: number) => Promise<ToolDetail>;

export class ToolDetailDialog {
    readonly element: HTMLDialogElement;
    readonly #title: HTMLHeadingElement;
    readonly #content: HTMLElement;
    readonly #close: HTMLButtonElement;
    readonly #load: LoadToolDetail;
    #requestId = 0;

    constructor(load: LoadToolDetail) {
        this.#load = load;
        this.element = document.createElement("dialog");
        this.element.className = "tool-detail-dialog";
        this.#title = H.h2().class("tool-detail-title").el();
        this.#content = H.div().class("tool-detail-content").el();
        this.#close = iconActionButton("/icons/close.svg", () => this.element.close());
        this.element.append(
            H.header()
                .class("tool-detail-header", "tool-detail-header-centered")
                .append(this.#title, this.#close)
                .el(),
            this.#content,
        );
        this.element.addEventListener("cancel", event => event.preventDefault());
    }

    async open(
        turnId: string,
        callIndex: number,
        toolName: string | undefined,
        language: ChatLanguage,
    ): Promise<void> {
        const labels = toolDetailText(language).labels;
        const requestId = ++this.#requestId;
        this.#title.textContent = toolName === undefined
            ? labels.title
            : `${labels.title}: ${friendlyToolName(toolName, language)}`;
        this.#close.ariaLabel = labels.close;
        this.#content.replaceChildren(statusMessage(labels.loading));
        if (!this.element.open)
            this.element.showModal();

        try {
            const detail = await this.#load(turnId, callIndex);
            if (requestId !== this.#requestId)
                return;
            this.#title.replaceChildren(
                document.createTextNode(friendlyToolName(detail.tool.name, language)),
                statusIcon(detail.tool.status),
            );
            this.#content.replaceChildren(detailView(detail, labels, language));
        } catch (error: unknown) {
            console.error("Loading tool detail failed", error);
            if (requestId === this.#requestId)
                this.#content.replaceChildren(statusMessage(labels.unavailable, true));
        }
    }
}

function detailView(
    detail: ToolDetail,
    labels: ToolDetailLabels,
    language: ChatLanguage,
): DocumentFragment {
    const view = document.createDocumentFragment();
    view.append(section(labels.common, [
        field(labels.source, friendlySource(detail.tool.source, language)),
        field(labels.started, formatLocalDateTime(detail.tool.startedAt)),
        field(
            labels.duration,
            formatCompactDuration(detail.tool.durationMs),
        ),
        ...(detail.tool.workingDirectory.length === 0
            ? []
            : [field(labels.workingDirectory, detail.tool.workingDirectory)]),
    ]));
    view.append(valueSection(
        labels.arguments,
        detail.arguments,
        detail.tool.name,
        labels,
        language,
    ));
    if (detail.tool.name === "model_context") {
        view.append(initialInstructionsSection(detail.content, labels));
        if (detail.extensionData !== null && detail.extensionData !== undefined)
            view.append(section(labels.llmRequests, [
                rawDisclosure(detail.extensionData, labels),
            ]));
    } else {
        view.append(contentSection(labels.returnedContent, detail.content, labels, language));
    }
    // Scheduler snapshots live in details because the transcript line is only a title.
    if (detail.tool.source === "scheduler"
        && detail.details !== null
        && detail.details !== undefined)
        view.append(valueSection(
            labels.details,
            detail.details,
            detail.tool.name,
            labels,
            language,
        ));
    return view;
}

function initialInstructionsSection(
    content: readonly unknown[],
    labels: ToolDetailLabels,
): HTMLElement {
    const first = content[0];
    const text = isRecord(first) && typeof first["text"] === "string"
        ? first["text"] : labels.empty;
    return section(labels.initialInstructions, [field(labels.content, text)]);
}

function valueSection(
    title: string,
    value: unknown,
    toolName: string,
    labels: ToolDetailLabels,
    language: ChatLanguage,
): HTMLElement {
    const readable = readableJson(value);
    const fields = isRecord(readable)
        ? recordFields(readable, toolName, labels, language)
        : [field(labels.value, readable)];
    fields.push(rawDisclosure(value, labels));
    return section(title, fields);
}

function contentSection(
    title: string,
    content: readonly unknown[],
    labels: ToolDetailLabels,
    language: ChatLanguage,
): HTMLElement {
    const parts: HTMLElement[] = [];
    content.forEach((part, index) => {
        if (isImagePart(part)) {
            parts.push(imageField(labels.imageIndexed(index), part, labels, language));
            return;
        }
        if (isRecord(part) && typeof part["text"] === "string") {
            parts.push(field(contentLabel(part, index, labels), part["text"]));
            const metadata = objectWithout(part, ["text", "type"]);
            if (Object.keys(metadata).length > 0)
                parts.push(...recordFields(metadata, "", labels, language));
            return;
        }
        parts.push(field(labels.part(index), part));
    });
    if (parts.length === 0)
        parts.push(field(labels.content, labels.empty));
    parts.push(rawDisclosure(content, labels));
    return section(title, parts);
}

function readableJson(value: unknown): unknown {
    if (typeof value !== "string") return value;
    try {
        return JSON.parse(value) as unknown;
    } catch {
        return value;
    }
}

function rawDisclosure(value: unknown, labels: ToolDetailLabels): HTMLElement {
    const details = document.createElement("details");
    details.className = "tool-detail-raw";
    const summary = document.createElement("summary");
    summary.textContent = labels.raw;
    details.append(summary, highlightedJson(value));
    return details;
}

function highlightedJson(value: unknown): HTMLElement {
    const source = typeof value === "string" ? value : JSON.stringify(value, null, 2);
    const pre = document.createElement("pre");
    pre.className = "tool-detail-json";
    const pattern = new RegExp(
        "(\"(?:\\\\.|[^\"\\\\])*\"(?=\\s*:)|\"(?:\\\\.|[^\"\\\\])*\""
            + "|\\b(?:true|false|null)\\b|-?\\d+(?:\\.\\d+)?(?:e[+-]?\\d+)?)",
        "giu",
    );
    let offset = 0;
    for (const match of source.matchAll(pattern)) {
        const index = match.index;
        pre.append(document.createTextNode(source.slice(offset, index)));
        const token = document.createElement("span");
        token.className = match[0].startsWith("\"")
            ? (source.slice(index + match[0].length).trimStart().startsWith(":")
                ? "json-key" : "json-string")
            : match[0] === "true" || match[0] === "false" || match[0] === "null"
                ? "json-literal" : "json-number";
        token.textContent = match[0];
        pre.append(token);
        offset = index + match[0].length;
    }
    pre.append(document.createTextNode(source.slice(offset)));
    return pre;
}

function statusIcon(status: ToolDetailStatus): HTMLElement {
    const icon = document.createElement("span");
    icon.className = `tool-detail-title-status tool-detail-title-status-${status}`;
    icon.textContent = status === "running" ? "…" : status === "succeeded" ? "✓" : "×";
    icon.setAttribute("aria-label", status);
    return icon;
}

function recordFields(
    value: Readonly<Record<string, unknown>>,
    toolName: string,
    labels: ToolDetailLabels,
    language: ChatLanguage,
): HTMLElement[] {
    return Object.entries(value).flatMap(([key, item]) => {
        if (key === "artifacts" && Array.isArray(item))
            return artifactFields(item, labels, language);
        return [field(friendlyFieldName(toolName, key, language), item)];
    });
}

function artifactFields(
    artifacts: readonly unknown[],
    labels: ToolDetailLabels,
    language: ChatLanguage,
): HTMLElement[] {
    return artifacts.flatMap((artifact, index) => {
        if (!isRecord(artifact))
            return [field(labels.artifact(index), artifact)];
        const mimeType = stringProperty(
            artifact,
            ["mime", "mime_type", "mimeType", "media_type"],
        );
        const url = stringProperty(artifact, ["url", "audio_url"]);
        if (mimeType?.startsWith("image/") === true && url !== undefined)
            return [imageField(labels.artifact(index), artifact, labels, language)];
        if (url !== undefined)
            return [downloadField(labels.artifact(index), artifact, labels, language)];
        return recordFields(artifact, "", labels, language);
    });
}

function downloadField(
    label: string,
    value: Readonly<Record<string, unknown>>,
    labels: ToolDetailLabels,
    language: ChatLanguage,
): HTMLElement {
    const url = stringProperty(value, ["url", "audio_url"]);
    if (url === undefined)
        return field(label, value);
    const filename = stringProperty(value, ["filename", "name"]);
    const link = document.createElement("a");
    link.className = "tool-detail-artifact-link";
    link.href = url;
    link.download = filename ?? "";
    link.textContent = filename === undefined ? labels.download : `${labels.download}: ${filename}`;
    const container = detailField(label, link);
    const metadata = objectWithout(value, ["url", "audio_url"]);
    if (Object.keys(metadata).length > 0)
        container.append(...recordFields(metadata, "", labels, language));
    return container;
}

function field(label: string, value: unknown): HTMLElement {
    return detailField(label, valueView(value, label));
}

function valueView(value: unknown, empty: string): HTMLElement {
    const text = valueText(value, empty);
    if (typeof value === "string" && value.length <= 160 && !value.includes("\n"))
        return H.div().class("tool-detail-value").text(text).el();
    if (typeof value === "number" || typeof value === "boolean" || value === null)
        return H.div().class("tool-detail-value").text(text).el();
    const area = H.textarea()
        .class("tool-detail-textarea")
        .attr("readonly", "")
        .attr("rows", "30")
        .el();
    area.value = text;
    return area;
}

function imageField(
    label: string,
    value: Readonly<Record<string, unknown>>,
    labels: ToolDetailLabels,
    language: ChatLanguage,
): HTMLElement {
    const image = document.createElement("img");
    image.className = "tool-detail-image";
    image.alt = "";
    image.src = imageSource(value);
    const link = document.createElement("a");
    link.className = "tool-detail-image-link";
    link.href = image.src;
    link.target = "_blank";
    link.rel = "noopener";
    link.ariaLabel = labels.openImage;
    link.append(image);
    const container = detailField(label, link);
    container.classList.add("tool-detail-image-field");
    const metadata = objectWithout(value, ["data"]);
    if (Object.keys(metadata).length > 0)
        container.append(...recordFields(metadata, "", labels, language));
    return container;
}

function imageSource(value: Readonly<Record<string, unknown>>): string {
    const url = stringProperty(value, ["url"]);
    if (url !== undefined)
        return url;
    const data = typeof value["data"] === "string" ? value["data"] : "";
    const mimeType = stringProperty(value, ["mime", "mimeType", "mime_type", "media_type"])
        ?? "image/png";
    return `data:${mimeType};base64,${data}`;
}

function section(title: string, fields: readonly HTMLElement[]): HTMLElement {
    const heading = document.createElement("h3");
    heading.textContent = title;
    return H.section()
        .class("tool-detail-section")
        .append(heading, ...fields)
        .el();
}

function statusMessage(message: string, failed = false): HTMLElement {
    return H.div()
        .class("tool-detail-status", ...(failed ? ["tool-detail-status-error"] : []))
        .text(message)
        .el();
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isImagePart(value: unknown): value is Readonly<Record<string, unknown>> {
    if (!isRecord(value))
        return false;
    if (value["type"] === "image" && typeof value["data"] === "string")
        return true;
    const mimeType = stringProperty(value, ["mime_type", "mimeType", "media_type"]);
    return mimeType?.startsWith("image/") === true
        && stringProperty(value, ["url"]) !== undefined;
}

function stringProperty(
    value: Readonly<Record<string, unknown>>,
    names: readonly string[],
): string | undefined {
    for (const name of names) {
        const item = value[name];
        if (typeof item === "string")
            return item;
    }
    return undefined;
}

function objectWithout(
    value: Readonly<Record<string, unknown>>,
    names: readonly string[],
): Readonly<Record<string, unknown>> {
    return Object.fromEntries(Object.entries(value).filter(([name]) => !names.includes(name)));
}

function valueText(value: unknown, empty: string): string {
    if (typeof value === "string")
        return value;
    if (value === undefined)
        return empty;
    return JSON.stringify(value, null, 2);
}

function contentLabel(
    value: Readonly<Record<string, unknown>>,
    index: number,
    labels: ToolDetailLabels,
): string {
    const type = typeof value["type"] === "string" ? value["type"] : "content";
    if (type === "content" || type === "text")
        return labels.part(index);
    return `${friendlyWords(type, labels.value)} ${index + 1}`;
}

function friendlySource(value: ToolDetailSource, language: ChatLanguage): string {
    return toolDetailText(language).sources[value]
        ?? Er.contract(`Unsupported tool source ${value}.`);
}

function friendlyToolName(value: string, language: ChatLanguage): string {
    const labels = toolDetailText(language).labels;
    return toolDetailText(language).toolNames[value] ?? friendlyWords(value, labels.value);
}

function friendlyFieldName(toolName: string, value: string, language: ChatLanguage): string {
    const names = toolDetailText(language).fieldNames;
    const labels = toolDetailText(language).labels;
    return names[`${toolName}.${value}`] ?? names[value] ?? friendlyWords(value, labels.value);
}

function friendlyWords(value: string, fallback: string): string {
    const words = value
        .replace(/([a-z])([A-Z])/gu, "$1 $2")
        .replace(/[_-]+/gu, " ")
        .trim();
    return words.length === 0 ? fallback : words[0]!.toUpperCase() + words.slice(1);
}
