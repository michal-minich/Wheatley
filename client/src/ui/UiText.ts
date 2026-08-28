import type { ChatLanguage } from "../chat/Language";

export interface UiText {
    readonly copyMessage: string;
    readonly branchChatHere: string;
    readonly home: string;
    readonly reload: string;
    readonly newChat: string;
    readonly menu: string;
    readonly language: string;
    readonly english: string;
    readonly slovak: string;
    readonly german: string;
    readonly recentChats: string;
    readonly searchChats: string;
    readonly clearSearch: string;
    readonly allChats: string;
    readonly chatsWithToolUse: string;
    readonly chatsWithWebSearch: string;
    readonly chatsWithGeneratedImages: string;
    readonly chatsWithScheduledTasks: string;
    readonly chatsWithCompactedContext: string;
    readonly chatsWithScreenCaptures: string;
    readonly current: string;
    readonly chatHasScheduledTurn: string;
    readonly chatUsedTools: string;
    readonly chatGeneratedImage: string;
    readonly generatedImageLabel: (id: number) => string;
    readonly chatUsedWebSearch: string;
    readonly chatCompactedContext: string;
    readonly chatUsedScreenCapture: string;
    readonly deleteChat: string;
    readonly deleteConfirmation: string;
    readonly profile: string;
    readonly model: string;
    readonly reasoningMetric: string;
    readonly reasoningBudgetMetric: string;
    readonly reasoningBudgetOff: string;
    readonly reasoningBudgetOn: string;
    readonly reasoningBudgetMinimal: string;
    readonly reasoningBudgetLow: string;
    readonly reasoningBudgetMedium: string;
    readonly reasoningBudgetHigh: string;
    readonly reasoningBudgetXHigh: string;
    readonly reasoningBudgetMax: string;
    readonly chooseImage: string;
    readonly replaceImage: string;
    readonly removeImage: string;
    readonly liveListen: string;
    readonly send: string;
    readonly liveListening: string;
    readonly finalizingLiveSpeech: string;
    readonly submitLiveSpeech: string;
    readonly cancelLiveSpeech: string;
    readonly stop: string;
    readonly stopping: string;
    readonly speakMessage: string;
    readonly playRecording: string;
    readonly automaticallySpeakResponses: string;
    readonly playMusic: string;
    readonly keepMicrophoneOn: string;
    readonly shareScreen: (profileName: string) => string;
    readonly stopSharingScreen: string;
    readonly stopPlayback: string;
    readonly cancelQueuedMessage: string;
    readonly chatSettings: string;
    readonly secondsBeforeSending: string;
    readonly sendAfterSeconds: (seconds: number) => string;
    readonly showOnlyRecentThinking: string;
    readonly compactNow: string;
    readonly compactingContext: string;
    readonly showCompactedContext: string;
    readonly contextCompacted: string;
    readonly contextCompactionFailed: string;
    readonly speakReasoning: string;
    readonly copyReasoning: string;
    readonly openActivity: string;
    readonly closeActivity: string;
    readonly workedFor: (duration: string) => string;
    readonly workingFor: (duration: string) => string;
    readonly working: string;
    readonly firstTokenMetric: string;
    readonly inputTokensMetric: string;
    readonly outputTokensMetric: string;
    readonly usedContextMetric: string;
    readonly availableContextMetric: string;
    readonly cacheReadTokensMetric: string;
    readonly reasoningTokensMetric: string;
    readonly generationRateMetric: string;
    readonly turnDurationMetric: string;
    readonly tokensUnit: string;
    readonly tokensPerSecondUnit: string;
    readonly dateTimeMetric: string;
    readonly connectionUnavailable: string;
    readonly startupFailed: string;
    readonly microphoneUnavailable: string;
    readonly turnFailed: string;
    readonly technicalDetails: string;
    readonly liveAudioFailed: string;
    readonly recentChatsFailed: string;
    readonly deleteFailed: string;
    readonly branchFailed: string;
    readonly instructions: string;
    readonly scheduledTasks: string;
    readonly noScheduledTasksGuidance: (profileName: string) => string;
    readonly scheduledTaskActiveChat: string;
    readonly scheduledTaskThisChat: string;
    readonly scheduledTaskNewChat: string;
    readonly enableScheduledTask: string;
    readonly disableScheduledTask: string;
    readonly runScheduledTask: string;
    readonly deleteScheduledTask: string;
    readonly noScheduledTaskNextRun: string;
    readonly saveScheduledTask: string;
    readonly close: string;
    readonly saveInstructions: string;
    readonly cancelInstructions: string;
    readonly instructionSystem: string;
    readonly instructionUser: string;
    readonly instructionWorkspace: string;
    readonly instructionMemory: string;
    readonly instructionMemoryRules: string;
    readonly autoMemoryNote: string;
    readonly workspacePath: string;
    readonly messageFor: (profileName: string) => string;
}

export interface ToolDetailLabels {
    readonly title: string;
    readonly close: string;
    readonly loading: string;
    readonly unavailable: string;
    readonly common: string;
    readonly arguments: string;
    readonly returnedContent: string;
    readonly initialInstructions: string;
    readonly llmRequests: string;
    readonly details: string;
    readonly extensionData: string;
    readonly tool: string;
    readonly status: string;
    readonly source: string;
    readonly started: string;
    readonly completed: string;
    readonly duration: string;
    readonly callIndex: string;
    readonly callId: string;
    readonly workingDirectory: string;
    readonly image: string;
    readonly value: string;
    readonly content: string;
    readonly part: (index: number) => string;
    readonly artifact: (index: number) => string;
    readonly imageIndexed: (index: number) => string;
    readonly empty: string;
    readonly raw: string;
    readonly download: string;
    readonly openImage: string;
}

export interface ToolDetailText {
    readonly labels: ToolDetailLabels;
    readonly statuses: Readonly<Record<string, string>>;
    readonly sources: Readonly<Record<string, string>>;
    readonly toolNames: Readonly<Record<string, string>>;
    readonly fieldNames: Readonly<Record<string, string>>;
}

export interface CodexText {
    readonly label: string;
    readonly started: string;
    readonly completed: string;
    readonly failed: (detail: string) => string;
    readonly failedGeneric: string;
    readonly command: (detail: string) => string;
    readonly fileChange: string;
}

interface TranslationPack {
    readonly ui: UiText;
    readonly toolDetails: ToolDetailText;
    readonly accents: Readonly<Record<string, string>>;
    readonly codex: CodexText;
}

const packs = new Map<ChatLanguage, TranslationPack>();

// Startup translations are served by Wheatley, so the connection error shown
// when that server cannot be reached must not depend on a loaded pack.
const connectionUnavailableFallback: Readonly<Record<ChatLanguage, string>> = {
    en: "Unable to connect to Wheatley. Is the server running?",
    sk: "Nepodarilo sa pripojiť k Wheatleymu. Beží server?",
    de: "Verbindung zu Wheatley fehlgeschlagen. Läuft der Server?",
};

export function installTranslation(language: ChatLanguage, value: unknown): void {
    const root = record(value, "translation");
    const rawUi = record(root["ui"], "translation.ui");
    packs.set(language, {
        ui: {
            ...stringRecord(rawUi, "translation.ui"),
            sendAfterSeconds: seconds => format(requiredString(rawUi, "sendAfterSeconds"), {
                seconds: seconds.toString(),
            }),
            workedFor: duration => format(requiredString(rawUi, "workedFor"), { duration }),
            workingFor: duration => format(requiredString(rawUi, "workingFor"), { duration }),
            shareScreen: profileName => format(requiredString(rawUi, "shareScreen"), {
                profileName,
            }),
            messageFor: profileName => format(requiredString(rawUi, "messageFor"), { profileName }),
            generatedImageLabel: id => format(requiredString(rawUi, "generatedImageLabel"), {
                id: id.toString(),
            }),
            noScheduledTasksGuidance: profileName => format(
                requiredString(rawUi, "noScheduledTasksGuidance"),
                { profileName },
            ),
        } as UiText,
        toolDetails: {
            labels: parseToolDetailLabels(
                record(root["toolDetails"], "translation.toolDetails"),
            ),
            statuses: stringRecord(
                record(root["toolStatuses"], "translation.toolStatuses"),
                "translation.toolStatuses",
            ),
            sources: stringRecord(
                record(root["toolSources"], "translation.toolSources"),
                "translation.toolSources",
            ),
            toolNames: stringRecord(record(root["toolNames"], "translation.toolNames"),
                "translation.toolNames"),
            fieldNames: stringRecord(record(root["fieldNames"], "translation.fieldNames"),
                "translation.fieldNames"),
        },
        accents: stringRecord(record(root["accents"], "translation.accents"),
            "translation.accents"),
        codex: parseCodexText(record(root["codex"], "translation.codex")),
    });
}

export function uiText(language: ChatLanguage): UiText {
    return pack(language).ui;
}

export function toolDetailText(language: ChatLanguage): ToolDetailText {
    return pack(language).toolDetails;
}

export function codexText(language: ChatLanguage): CodexText {
    return pack(language).codex;
}

export function accentText(language: ChatLanguage, id: string): string {
    return pack(language).accents[id] ?? id;
}

export function connectionUnavailableText(language: ChatLanguage): string {
    return packs.get(language)?.ui.connectionUnavailable
        ?? connectionUnavailableFallback[language];
}

function pack(language: ChatLanguage): TranslationPack {
    const result = packs.get(language);
    if (result === undefined)
        throw new Error(`Translations for ${language} were not loaded.`);
    return result;
}

function parseCodexText(value: Readonly<Record<string, unknown>>): CodexText {
    const failed = requiredString(value, "failed", "translation.codex");
    const command = requiredString(value, "command", "translation.codex");
    return {
        label: requiredString(value, "label", "translation.codex"),
        started: requiredString(value, "started", "translation.codex"),
        completed: requiredString(value, "completed", "translation.codex"),
        failed: detail => format(failed, { detail }),
        failedGeneric: requiredString(value, "failedGeneric", "translation.codex"),
        command: detail => format(command, { detail }),
        fileChange: requiredString(value, "fileChange", "translation.codex"),
    };
}

function parseToolDetailLabels(
    value: Readonly<Record<string, unknown>>,
): ToolDetailLabels {
    const part = requiredString(value, "part", "translation.toolDetails");
    const artifact = requiredString(value, "artifact", "translation.toolDetails");
    const imageIndexed = requiredString(value, "imageIndexed", "translation.toolDetails");
    return {
        title: requiredString(value, "title", "translation.toolDetails"),
        close: requiredString(value, "close", "translation.toolDetails"),
        loading: requiredString(value, "loading", "translation.toolDetails"),
        unavailable: requiredString(value, "unavailable", "translation.toolDetails"),
        common: requiredString(value, "common", "translation.toolDetails"),
        arguments: requiredString(value, "arguments", "translation.toolDetails"),
        returnedContent: requiredString(value, "returnedContent", "translation.toolDetails"),
        initialInstructions: requiredString(
            value,
            "initialInstructions",
            "translation.toolDetails",
        ),
        llmRequests: requiredString(value, "llmRequests", "translation.toolDetails"),
        details: requiredString(value, "details", "translation.toolDetails"),
        extensionData: requiredString(value, "extensionData", "translation.toolDetails"),
        tool: requiredString(value, "tool", "translation.toolDetails"),
        status: requiredString(value, "status", "translation.toolDetails"),
        source: requiredString(value, "source", "translation.toolDetails"),
        started: requiredString(value, "started", "translation.toolDetails"),
        completed: requiredString(value, "completed", "translation.toolDetails"),
        duration: requiredString(value, "duration", "translation.toolDetails"),
        callIndex: requiredString(value, "callIndex", "translation.toolDetails"),
        callId: requiredString(value, "callId", "translation.toolDetails"),
        workingDirectory: requiredString(value, "workingDirectory", "translation.toolDetails"),
        image: requiredString(value, "image", "translation.toolDetails"),
        value: requiredString(value, "value", "translation.toolDetails"),
        content: requiredString(value, "content", "translation.toolDetails"),
        part: index => format(part, { index: (index + 1).toString() }),
        artifact: index => format(artifact, { index: (index + 1).toString() }),
        imageIndexed: index => format(imageIndexed, { index: (index + 1).toString() }),
        empty: requiredString(value, "empty", "translation.toolDetails"),
        raw: requiredString(value, "raw", "translation.toolDetails"),
        download: requiredString(value, "download", "translation.toolDetails"),
        openImage: requiredString(value, "openImage", "translation.toolDetails"),
    };
}

function format(template: string, values: Readonly<Record<string, string>>): string {
    return template.replace(/\{([A-Za-z]+)\}/gu, (_, key: string) => values[key] ?? `{${key}}`);
}

function record(value: unknown, name: string): Readonly<Record<string, unknown>> {
    if (typeof value !== "object" || value === null || Array.isArray(value))
        throw new Error(`${name} must be an object.`);
    return value as Readonly<Record<string, unknown>>;
}

function stringRecord(
    value: Readonly<Record<string, unknown>>,
    name: string,
): Readonly<Record<string, string>> {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => {
        if (typeof item !== "string")
            throw new Error(`${name}.${key} must be a string.`);
        return [key, item];
    }));
}

function requiredString(
    value: Readonly<Record<string, unknown>>,
    key: string,
    scope = "translation.ui",
): string {
    const result = value[key];
    if (typeof result !== "string")
        throw new Error(`${scope}.${key} must be a string.`);
    return result;
}
