import {
    VERSION as piVersion,
    type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";

interface WheatleyContext {
    readonly apiBase: string;
    readonly profileId: string;
    readonly sessionId: string;
    readonly promptPrewarm: boolean;
    readonly turnContextPath: string | null;
}

interface WheatleyTurnContext {
    readonly turnId: string;
    readonly model: string;
    readonly reasoningMode: ReasoningMode;
    readonly clientId: string;
    readonly systemPrompt: string;
    readonly providerRequest: Readonly<Record<string, unknown>>;
    readonly screenCaptureScope: "active_window" | "active_display" | "both" | "";
    readonly screenCaptureModelMaxLongEdgePx: number;
    readonly screenCaptureModelPixelsPerLogicalPixel: number;
}

type ReasoningMode = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";

interface ClientToolRequest {
    readonly request_id: string;
}

interface ClientToolResult {
    readonly ok: boolean;
    readonly content: unknown[];
    readonly artifacts: unknown[];
    readonly error: ClientToolError | null;
}

interface ClientToolError {
    readonly message: string;
}

interface ClientToolArtifact {
    readonly kind?: unknown;
    readonly mime?: unknown;
    readonly url?: unknown;
    readonly model_url?: unknown;
    readonly filename?: unknown;
    readonly width?: unknown;
    readonly height?: unknown;
    readonly [key: string]: unknown;
}

interface ClientToolDetail {
    readonly request: ClientToolRequest;
    readonly result: ClientToolResult | null;
}

interface MemoryResult {
    readonly remembered: string;
}

interface ScheduledTaskEnvelope {
    readonly id: string;
    readonly state?: string;
    readonly quick_status?: string;
    readonly display_text?: string;
    readonly target?: unknown;
    readonly schedule_text?: string;
    readonly next_run_at?: string;
    readonly late_by_minutes?: number;
    readonly has_run?: boolean;
    readonly last_run_status?: string;
    readonly task: {
        readonly display_text: string;
        readonly state: string;
        readonly task_text?: string;
        readonly target?: unknown;
        readonly schedule?: unknown;
        readonly reasoning_mode?: string;
        readonly created?: unknown;
        readonly last_run?: unknown;
        readonly last_failure?: unknown;
    };
}

interface ScheduledTaskDetail {
    readonly id: string;
    readonly state: string;
    readonly display_text: string;
    readonly task_text: string;
    readonly target: unknown;
    readonly schedule: unknown;
    readonly reasoning_mode?: string;
    readonly created?: unknown;
    readonly next_run_at?: string;
    readonly late_by_minutes?: number;
    readonly last_run?: unknown;
    readonly last_failure?: unknown;
}

interface ScheduledTaskSummary {
    readonly id: string;
    readonly state: string;
    readonly quick_status: string;
    readonly display_text: string;
    readonly target: string;
    readonly schedule_text: string;
    readonly next_run_at?: string;
    readonly late_by_minutes?: number;
    readonly has_run: boolean;
    readonly last_run_status?: string;
}

interface ScheduledTaskList {
    readonly tasks: readonly ScheduledTaskSummary[];
}

function scheduledTaskListText(tasks: readonly ScheduledTaskSummary[]): string {
    if (tasks.length === 0)
        return "Scheduled tasks: none.";
    return `Scheduled tasks (${tasks.length}):\n${tasks.map((task, index) => {
        const fields = [
            `${index + 1}. id=${task.id}`,
            `title=${JSON.stringify(task.display_text)}`,
            `state=${task.state}`,
            `quick_status=${task.quick_status}`,
            `target=${task.target}`,
            `schedule=${JSON.stringify(task.schedule_text)}`,
            ...(task.next_run_at === undefined ? [] : [`next_run_at=${task.next_run_at}`]),
            ...(task.late_by_minutes === undefined ? [] : [`late_by_minutes=${task.late_by_minutes}`]),
            `has_run=${task.has_run}`,
            ...(task.last_run_status === undefined ? [] : [`last_run_status=${task.last_run_status}`]),
        ];
        return fields.join("; ");
    }).join("\n")}`;
}

function scheduledTaskDetailFromEnvelope(result: ScheduledTaskEnvelope): ScheduledTaskDetail {
    const task = result.task;
    return {
        id: result.id,
        state: result.state ?? task.state,
        display_text: result.display_text ?? task.display_text,
        task_text: typeof task.task_text === "string" ? task.task_text : "",
        target: task.target ?? result.target ?? "",
        schedule: task.schedule ?? {},
        ...(task.reasoning_mode === undefined ? {} : { reasoning_mode: task.reasoning_mode }),
        ...(task.created === undefined ? {} : { created: task.created }),
        ...(result.next_run_at === undefined ? {} : { next_run_at: result.next_run_at }),
        ...(result.late_by_minutes === undefined ? {} : { late_by_minutes: result.late_by_minutes }),
        ...(task.last_run === undefined ? {} : { last_run: task.last_run }),
        ...(task.last_failure === undefined ? {} : { last_failure: task.last_failure }),
    };
}

function scheduledTaskDetailText(
    detail: ScheduledTaskDetail,
    scheduleText: string | undefined,
): string {
    const fields = [
        `id=${detail.id}`,
        `title=${JSON.stringify(detail.display_text)}`,
        `state=${detail.state}`,
        `target=${scheduledTaskTargetText(detail.target)}`,
        `schedule=${JSON.stringify(scheduleText ?? detail.schedule)}`,
        ...(detail.reasoning_mode === undefined ? [] : [`reasoning_mode=${detail.reasoning_mode}`]),
        `task_text=${JSON.stringify(detail.task_text)}`,
        ...(detail.next_run_at === undefined ? [] : [`next_run_at=${detail.next_run_at}`]),
        ...(detail.late_by_minutes === undefined ? [] : [`late_by_minutes=${detail.late_by_minutes}`]),
        ...(detail.last_run === undefined ? [] : [`last_run=${JSON.stringify(detail.last_run)}`]),
        ...(detail.last_failure === undefined ? [] : [`last_failure=${JSON.stringify(detail.last_failure)}`]),
        ...(detail.created === undefined ? [] : [`created=${JSON.stringify(detail.created)}`]),
    ];
    return `Scheduled task: ${fields.join("; ")}.`;
}

function scheduledTaskTargetText(target: unknown): string {
    if (typeof target === "string") return target;
    if (isObject(target) && typeof target.kind === "string") {
        const extras = Object.entries(target)
            .filter(([key]) => key !== "kind")
            .map(([key, value]) => `${key}=${JSON.stringify(value)}`);
        return extras.length === 0 ? target.kind : `${target.kind} (${extras.join(", ")})`;
    }
    return JSON.stringify(target);
}

const relativeTimeSchema = Type.Union([
    Type.Object({ kind: Type.Literal("now") }),
    Type.Object({ kind: Type.Literal("after"), seconds: Type.Integer({ minimum: 1 }) }),
    Type.Object({ kind: Type.Literal("at"), at: Type.String() }),
]);

const recurrenceEndSchema = Type.Union([
    Type.Object({ kind: Type.Literal("count"), occurrences: Type.Integer({ minimum: 1 }) }),
    Type.Object({ kind: Type.Literal("until"), at: Type.String() }),
]);
const calendarEndSchema = Type.Union([
    Type.Object({ kind: Type.Literal("count"), occurrences: Type.Integer({ minimum: 1 }) }),
    Type.Object({ kind: Type.Literal("through"), date: Type.String() }),
]);
const calendarCommon = {
    start_date: Type.String(), time: Type.String(), interval: Type.Integer({ minimum: 1 }),
    excluded_dates: Type.Optional(Type.Array(Type.String())), end: Type.Optional(calendarEndSchema),
};
const monthRuleSchema = Type.Union([
    Type.Object({ kind: Type.Literal("month_days"), days: Type.Array(Type.Integer({ minimum: 1, maximum: 31 }), { minItems: 1 }) }),
    Type.Object({ kind: Type.Literal("ordinal_weekday"), ordinal: Type.Union([Type.Literal(-1), Type.Literal(1), Type.Literal(2), Type.Literal(3), Type.Literal(4), Type.Literal(5)]), weekday: Type.Union([Type.Literal("MO"), Type.Literal("TU"), Type.Literal("WE"), Type.Literal("TH"), Type.Literal("FR"), Type.Literal("SA"), Type.Literal("SU")]) }),
]);

const createScheduleSchema = Type.Union([
    Type.Object({ kind: Type.Literal("once"), when: relativeTimeSchema }),
    Type.Object({
        kind: Type.Literal("fixed_interval"),
        first: relativeTimeSchema,
        every_seconds: Type.Integer({ minimum: 1 }),
        end: Type.Optional(recurrenceEndSchema),
    }),
    Type.Object({
        kind: Type.Literal("after_completion"),
        first: Type.Optional(relativeTimeSchema),
        delay_seconds: Type.Integer({ minimum: 1 }),
        end: Type.Optional(recurrenceEndSchema),
    }),
    Type.Object({ kind: Type.Literal("calendar_daily"), ...calendarCommon }),
    Type.Object({ kind: Type.Literal("calendar_weekly"), ...calendarCommon, weekdays: Type.Array(Type.Union([Type.Literal("MO"), Type.Literal("TU"), Type.Literal("WE"), Type.Literal("TH"), Type.Literal("FR"), Type.Literal("SA"), Type.Literal("SU")]), { minItems: 1 }) }),
    Type.Object({ kind: Type.Literal("calendar_monthly"), ...calendarCommon, on: monthRuleSchema }),
    Type.Object({ kind: Type.Literal("calendar_yearly"), ...calendarCommon, months: Type.Array(Type.Integer({ minimum: 1, maximum: 12 }), { minItems: 1 }), on: monthRuleSchema }),
    Type.Object({ kind: Type.Literal("agent_managed_next"), first: relativeTimeSchema }),
]);

interface CodexMessageResult {
    readonly accepted: true;
    readonly message: string;
    readonly dispatch_id: string;
}

interface CodexStatusResult {
    readonly status: "not_started" | "idle" | "running" | "completed" |
        "failed" | "interrupted" | "system_error" | "unknown";
    readonly fresh: boolean;
    readonly updated_at: string;
    readonly content_kind: "message" | "reasoning_summary" | "final_response" | "error";
    readonly content: string;
    readonly truncated: boolean;
}

interface GeneratedImageResult {
    readonly generated_image_id: number;
    readonly item_id: string;
    readonly kind: "generated_image";
    readonly filename: string;
    readonly media_type: "image/png";
    readonly url: string;
    readonly path: string;
    readonly sha256: string;
    readonly byte_count: number;
    readonly width: number;
    readonly height: number;
    readonly seed: number;
    readonly quality: "low" | "medium" | "high";
    readonly aspect: "square" | "portrait" | "landscape";
    readonly prompt: string;
}

interface GeneratedImageList {
    readonly images: readonly GeneratedImageResult[];
}

interface StoredWebImageResult {
    readonly kind: "web_image";
    readonly filename: string;
    readonly media_type: "image/jpeg" | "image/png";
    readonly url: string;
    readonly path: string;
    readonly sha256: string;
    readonly byte_count: number;
    readonly width: number;
    readonly height: number;
    readonly title: string;
    readonly source_url: string;
    readonly original_image_url: string;
}

interface BraveImageResult {
    readonly title?: unknown;
    readonly url?: unknown;
    readonly source?: unknown;
    readonly thumbnail?: { readonly src?: unknown };
    readonly properties?: { readonly url?: unknown };
}

const context = loadContext();

export default function configureWheatleyTools(pi: ExtensionAPI): void {
    configureTurnSystemPrompt(pi);
    configureProviderRequest(pi);
    if (context.promptPrewarm) configurePromptPrewarm(pi);
    if (!context.promptPrewarm && loadTurnContext().clientId === "scheduler")
        configureScheduledRunTools(pi);

    pi.registerTool({
        name: "remember",
        label: "Remember",
        description:
            "Append one explicit preference or durable context item to the active profile's User instructions. Use only when the user asks you to remember it.",
        parameters: Type.Object({
            text: Type.String({
                description: "The short durable memory to append.",
            }),
        }),
        async execute(_toolCallId, params) {
            const text = params.text.trim();
            if (!text.length) throw new Error("Memory text is empty.");
            const result = await httpJson<MemoryResult>(
                profileUrl("memory/remember"),
                {
                    method: "POST",
                    body: JSON.stringify({ memory: text }),
                },
            );
            return {
                content: [
                    { type: "text", text: `Remembered: ${result.remembered}` },
                ],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "create_scheduled_task",
        label: "Create Scheduled Task",
        description:
            "Create one durable future assistant task. The task request must stand alone in an empty conversation. Use fixed_interval for clock-anchored starts and after_completion only when the requested pause begins after every run finishes.",
        parameters: Type.Object({
            display_text: Type.String({ description: "Short task title, at most 120 characters." }),
            task_text: Type.String({ description: "Complete imperative instruction for each later assistant turn." }),
            target: Type.Union([
                Type.Literal("active_user_session"),
                Type.Literal("originating_session"),
                Type.Literal("new_session"),
            ]),
            schedule: createScheduleSchema,
            reasoning_mode: Type.Optional(Type.Union([
                Type.Literal("off"), Type.Literal("minimal"), Type.Literal("low"),
                Type.Literal("medium"), Type.Literal("high"), Type.Literal("xhigh"),
                Type.Literal("max"),
            ])),
        }),
        async execute(_toolCallId, params, signal) {
            const turn = loadTurnContext();
            const result = await httpJson<ScheduledTaskEnvelope>(profileUrl("scheduled-tasks"), {
                method: "POST",
                signal,
                body: JSON.stringify({
                    session_id: context.sessionId,
                    turn_id: turn.turnId,
                    task: params,
                }),
            });
            return {
                content: [{
                    type: "text" as const,
                    text: `Scheduled task created: ${result.task.display_text}.`,
                }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "list_scheduled_tasks",
        label: "List Scheduled Tasks",
        description: "List the current scheduled tasks before matching, changing, or deleting one.",
        parameters: Type.Object({}),
        async execute(_toolCallId, _params, signal) {
            const result = await httpJson<ScheduledTaskList>(profileUrl("scheduled-tasks"), {
                signal,
            });
            return {
                content: [{ type: "text" as const, text: scheduledTaskListText(result.tasks) }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "get_scheduled_task",
        label: "Get Scheduled Task",
        description: "Read one scheduled task after selecting it from the compact task list.",
        parameters: Type.Object({ id: Type.String() }),
        async execute(_toolCallId, params, signal) {
            const result = await httpJson<ScheduledTaskEnvelope>(
                profileUrl(`scheduled-tasks/${encodeURIComponent(params.id)}`),
                { signal },
            );
            const detail = scheduledTaskDetailFromEnvelope(result);
            return {
                content: [{
                    type: "text" as const,
                    text: scheduledTaskDetailText(detail, result.schedule_text),
                }],
                details: detail,
            };
        },
    });

    pi.registerTool({
        name: "set_scheduled_task_enabled",
        label: "Set Scheduled Task Enabled",
        description: "Turn one scheduled task on or off after the user explicitly asks.",
        parameters: Type.Object({ id: Type.String(), enabled: Type.Boolean() }),
        async execute(_toolCallId, params, signal) {
            const result = await httpJson<ScheduledTaskEnvelope>(
                profileUrl(`scheduled-tasks/${encodeURIComponent(params.id)}/enabled`),
                { method: "PUT", signal, body: JSON.stringify({ enabled: params.enabled }) },
            );
            return {
                content: [{ type: "text" as const, text: `Scheduled task is ${result.task.state}.` }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "update_scheduled_task",
        label: "Update Scheduled Task",
        description: "Atomically update only the requested fields of one scheduled task. List first and inspect the selected task when its schedule or prompt matters.",
        parameters: Type.Object({
            id: Type.String(),
            display_text: Type.Optional(Type.String()),
            task_text: Type.Optional(Type.String()),
            target: Type.Optional(Type.Union([
                Type.Literal("active_user_session"), Type.Literal("originating_session"), Type.Literal("new_session"),
            ])),
            schedule: Type.Optional(createScheduleSchema),
            reasoning_mode: Type.Optional(Type.Union([
                Type.Literal("off"), Type.Literal("minimal"), Type.Literal("low"),
                Type.Literal("medium"), Type.Literal("high"), Type.Literal("xhigh"),
                Type.Literal("max"),
            ])),
            model: Type.Optional(Type.String({
                description: "Exact Pi model ID for a new-session task only.",
            })),
        }),
        async execute(_toolCallId, params, signal) {
            const turn = loadTurnContext();
            const { id, ...patch } = params;
            const result = await httpJson<ScheduledTaskEnvelope>(
                profileUrl(`scheduled-tasks/${encodeURIComponent(id)}`), {
                    method: "PUT", signal,
                    body: JSON.stringify({ session_id: context.sessionId, turn_id: turn.turnId, patch }),
                },
            );
            return {
                content: [{ type: "text" as const, text: `Scheduled task updated: ${result.task.display_text}.` }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "run_scheduled_task_now",
        label: "Run Scheduled Task Now",
        description: "Request one explicit Run now occurrence only when the user asks for it.",
        parameters: Type.Object({ id: Type.String() }),
        async execute(_toolCallId, params, signal) {
            const result = await httpJson<ScheduledTaskEnvelope>(
                profileUrl(`scheduled-tasks/${encodeURIComponent(params.id)}/run-now`),
                { method: "POST", signal },
            );
            return {
                content: [{ type: "text" as const, text: `Run now requested for ${result.task.display_text}.` }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "delete_scheduled_task",
        label: "Delete Scheduled Task",
        description: "Delete one scheduled task only when the user explicitly asks to remove it.",
        parameters: Type.Object({ id: Type.String() }),
        async execute(_toolCallId, params, signal) {
            const result = await httpJson<{ readonly deleted: true }>(
                profileUrl(`scheduled-tasks/${encodeURIComponent(params.id)}`),
                { method: "DELETE", signal },
            );
            return {
                content: [{ type: "text" as const, text: "Scheduled task deleted." }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "generate_image",
        label: "Generate Image",
        description:
            "Generate one durable image with Wheatley's local Bonsai model. Quality is based only on the user's own wording: low for explicit speed/draft intent, high only for explicit quality/detail/final intent, and medium for every ordinary or uncertain request. Subject complexity and your expanded image prompt never justify high. Omit speed, draft, preview, rough, temporary, and low-quality wording from the visual prompt when it only selected a cheaper preset; positive quality/detail/polish/final wording may remain. A user's square, portrait, or landscape image wording is an exact canvas override; otherwise choose the natural composition.",
        parameters: Type.Object({
            prompt: Type.String({
                description:
                    "A complete visual description. Do not include speed, draft, preview, rough, temporary, or low-quality wording when it only selected the resolution preset; keep it only when it describes visible image content. Positive quality wording may remain.",
            }),
            aspect: Type.Union([
                Type.Literal("square"),
                Type.Literal("portrait"),
                Type.Literal("landscape"),
            ], {
                description:
                    "Canvas shape. If the user calls the requested image square, portrait, or landscape, pass that exact value; 'portrait image' means a tall portrait canvas. Otherwise choose the naturally suitable composition. Never pass pixel dimensions.",
            }),
            quality: Type.Optional(Type.Union([
                Type.Literal("low"),
                Type.Literal("medium"),
                Type.Literal("high"),
            ], {
                description:
                    "Resolution preset. Use medium for every ordinary or uncertain request. Use low/high only when the user's own words explicitly signal speed/draft or quality/detail/finality.",
            })),
            seed: Type.Optional(Type.Integer({
                minimum: 0,
                description: "Optional reproducibility seed.",
            })),
        }),
        async execute(_toolCallId, params, signal) {
            const turnContext = loadTurnContext();
            const prompt = params.prompt.trim();
            if (!prompt.length) throw new Error("Image prompt is empty.");
            const result = await httpJson<GeneratedImageResult>(
                profileUrl("image-generation"),
                {
                    method: "POST",
                    signal,
                    body: JSON.stringify({
                        session_id: context.sessionId,
                        turn_id: turnContext.turnId,
                        prompt,
                        aspect: params.aspect,
                        ...(params.quality === undefined ? {} : { quality: params.quality }),
                        ...(params.seed === undefined ? {} : { seed: params.seed }),
                    }),
                },
            );
            return {
                content: [{
                    type: "text",
                    text: `Generated image ${result.generated_image_id}.`,
                }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "list_generated_images",
        label: "List Generated Images",
        description:
            "List the generated images in this chat when the user refers to one by order, number, or description. Uploads and screenshots are not included.",
        parameters: Type.Object({}),
        async execute(_toolCallId, _params, signal) {
            const result = await httpJson<GeneratedImageList>(
                profileUrl(`generated-images?session_id=${encodeURIComponent(context.sessionId)}`),
                { signal },
            );
            return {
                content: [{
                    type: "text" as const,
                    text: JSON.stringify(result.images.map(image => ({
                        generated_image_id: image.generated_image_id,
                        prompt: image.prompt,
                        width: image.width,
                        height: image.height,
                    }))),
                }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "load_generated_image",
        label: "Load Generated Image",
        description:
            "Load exactly one earlier generated image into model context by its generated image ID.",
        parameters: Type.Object({
            generated_image_id: Type.Integer({ minimum: 1 }),
        }),
        async execute(_toolCallId, params, signal) {
            const list = await httpJson<GeneratedImageList>(
                profileUrl(`generated-images?session_id=${encodeURIComponent(context.sessionId)}`),
                { signal },
            );
            const image = list.images.find(candidate =>
                candidate.generated_image_id === params.generated_image_id);
            if (image === undefined)
                throw new Error(`Generated image ${params.generated_image_id} was not found.`);
            const bytes = await httpBytes(absoluteApiUrl(image.url), signal);
            return {
                content: [
                    {
                        type: "text" as const,
                        text: `Generated image ${image.generated_image_id}.`,
                    },
                    {
                        type: "image" as const,
                        data: Buffer.from(bytes).toString("base64"),
                        mimeType: "image/png" as const,
                    },
                ],
                details: {
                    generated_image_id: image.generated_image_id,
                    prompt: image.prompt,
                },
            };
        },
    });

    pi.registerTool({
        name: "image_search",
        label: "Search Images",
        description:
            "Search the web for visual reference images and inspect only the minimum useful set. Omit count for one image. Use two only when the request genuinely needs comparison. Never request more than three.",
        parameters: Type.Object({
            query: Type.String({ description: "A focused visual search query." }),
            count: Type.Optional(Type.Integer({
                minimum: 1,
                maximum: 3,
                description: "Images to inspect. Default 1; maximum 3.",
            })),
        }),
        async execute(_toolCallId, params, signal) {
            const turnContext = loadTurnContext();
            const query = params.query.trim();
            if (!query.length) throw new Error("Image search query is empty.");
            const count = params.count ?? 1;
            if (!Number.isInteger(count) || count < 1 || count > 3)
                throw new Error("Image search count must be an integer from 1 through 3.");
            const selected = await searchImages(query, count, signal);
            const stored = await Promise.all(selected.map(item => httpJson<StoredWebImageResult>(
                profileUrl("web-images"),
                {
                    method: "POST",
                    signal,
                    body: JSON.stringify({
                        session_id: context.sessionId,
                        turn_id: turnContext.turnId,
                        title: item.title,
                        source_url: item.sourceUrl,
                        original_image_url: item.originalImageUrl,
                        media_type: item.mediaType,
                        data_base64: item.base64,
                    }),
                },
            )));
            return {
                content: selected.flatMap((item, index) => [
                    {
                        type: "text" as const,
                        text: `Image ${index + 1}: ${item.title}\nSource: ${item.sourceUrl}`,
                    },
                    {
                        type: "image" as const,
                        data: item.base64,
                        mimeType: item.mediaType,
                    },
                ]),
                details: {
                    query,
                    count: selected.length,
                    safe_search: "strict",
                    images: stored.map(item => ({
                        title: item.title,
                        source_url: item.source_url,
                        image_url: item.url,
                        media_type: item.media_type,
                        filename: item.filename,
                        path: item.path,
                        sha256: item.sha256,
                        byte_count: item.byte_count,
                        width: item.width,
                        height: item.height,
                    })),
                },
            };
        },
    });

    pi.registerTool({
        name: "capture_photo",
        label: "Capture Photo",
        description:
            "Capture one photo from the active Wheatley client using its configured default camera. The client and camera are selected by Wheatley.",
        parameters: Type.Object({}),
        async execute(toolCallId, _params, signal) {
            const detail = await capturePhoto(toolCallId, signal);
            const result = detail.result;
            if (result === null)
                throw new Error("Photo capture completed without a result.");
            if (!result.ok)
                throw new Error(
                    result.error?.message ?? "Photo capture failed.",
                );
            return {
                content: result.content,
                details: {
                    request: detail.request,
                    artifacts: result.artifacts,
                },
            };
        },
    });

    const captureScope = loadTurnContext().screenCaptureScope;
    pi.registerTool({
        name: "capture_screen",
        label: "Capture Screen",
        description:
            "Capture the current app or display from the exact Wheatley client handling this turn.",
        parameters: Type.Object({
            scope: Type.Optional(captureScope.length && captureScope !== "both"
                ? Type.Literal(captureScope)
                : Type.String({
                    enum: ["active_window", "active_display"],
                })),
        }),
        async execute(toolCallId, params, signal) {
            const turnContext = loadTurnContext();
            if (!turnContext.screenCaptureScope)
                throw new Error("Screen capture is not active on this client.");
            const scope = params.scope ?? (turnContext.screenCaptureScope === "both"
                ? "active_window"
                : turnContext.screenCaptureScope);
            if (turnContext.screenCaptureScope !== "both"
                && scope !== turnContext.screenCaptureScope)
                throw new Error(`Only ${turnContext.screenCaptureScope} is currently shared.`);
            const detail = await requestClientTool(
                toolCallId,
                "capture_screen",
                {
                    scope,
                    model_max_long_edge_px: turnContext.screenCaptureModelMaxLongEdgePx,
                    model_pixels_per_logical_pixel:
                        turnContext.screenCaptureModelPixelsPerLogicalPixel,
                },
                signal,
            );
            const result = detail.result;
            if (result === null)
                throw new Error("Screen capture completed without a result.");
            if (!result.ok)
                throw new Error(result.error?.message ?? "Screen capture failed.");
            const artifact = result.artifacts.find(value =>
                isObject(value) && value.kind === "screen_capture") as ClientToolArtifact | undefined;
            if (artifact === undefined)
                throw new Error("Screen capture returned no PNG artifact.");
            const modelUrl = typeof artifact.model_url === "string"
                ? artifact.model_url
                : artifact.url;
            if (typeof modelUrl !== "string" || !modelUrl.length)
                throw new Error("Screen capture returned no model image URL.");
            const image = await httpBytes(absoluteApiUrl(modelUrl), signal);
            return {
                content: [
                    { type: "text", text: "Captured the requested screen." },
                    { type: "image", data: Buffer.from(image).toString("base64"), mimeType: "image/png" },
                ],
                details: artifact,
            };
        },
    });

    pi.registerTool({
        name: "codex_message",
        label: "Message Codex",
        description:
            "Send a fire-and-forget message to Codex for substantial workspace work. Wheatley automatically starts the paired Codex conversation, steers its active task, or starts a new task in the same conversation.",
        parameters: Type.Object({
            message: Type.String({
                description:
                    "The task, question, clarification, correction, or continuation to send to Codex.",
            }),
        }),
        async execute(_toolCallId, params) {
            const turnContext = loadTurnContext();
            const message = params.message.trim();
            if (!message.length) throw new Error("Codex message is empty.");
            const result = await httpJson<CodexMessageResult>(
                profileUrl("codex/message"),
                {
                    method: "POST",
                    body: JSON.stringify({
                        session_id: context.sessionId,
                        turn_id: turnContext.turnId,
                        message,
                    }),
                },
            );
            return {
                content: [{ type: "text", text: result.message }],
                details: result,
            };
        },
    });

    pi.registerTool({
        name: "codex_status",
        label: "Codex Status",
        description:
            "Read concise status from the Codex conversation paired with this Wheatley session. While running it returns recent reasoning summaries; after completion it returns only the final response.",
        parameters: Type.Object({}),
        async execute() {
            const result = await httpJson<CodexStatusResult>(
                profileUrl(`codex/status?session_id=${encodeURIComponent(context.sessionId)}`),
                {
                    method: "GET",
                },
            );
            return {
                content: [{ type: "text", text: result.content }],
                details: result,
            };
        },
    });
}

function configureScheduledRunTools(pi: ExtensionAPI): void {
    pi.registerTool({
        name: "schedule_next_occurrence",
        label: "Schedule Next Occurrence",
        description: "Set the next time for this current agent-managed scheduled task.",
        // Pi's OpenAI-compatible provider requires every function schema to
        // have an object root; the relative-time union therefore lives under
        // the one explicit `when` field.
        parameters: Type.Object({ when: relativeTimeSchema }),
        async execute(_toolCallId, params, signal) {
            const turn = loadTurnContext();
            const result = await httpJson<{ readonly next_run_at: string }>(
                profileUrl("scheduled-tasks/current/next"), {
                    method: "POST", signal,
                    body: JSON.stringify({
                        session_id: context.sessionId,
                        turn_id: turn.turnId,
                        when: params.when,
                    }),
                },
            );
            return { content: [{ type: "text" as const, text: `Next occurrence: ${result.next_run_at}.` }], details: result };
        },
    });
    pi.registerTool({
        name: "complete_current_scheduled_task",
        label: "Complete Current Scheduled Task",
        description: "Mark this current scheduled task complete when its work is finished.",
        parameters: Type.Object({ reason: Type.Optional(Type.String({ maxLength: 500 })) }),
        async execute(_toolCallId, params, signal) {
            const turn = loadTurnContext();
            const result = await httpJson<{ readonly state: "completed" }>(
                profileUrl("scheduled-tasks/current/complete"), {
                    method: "POST", signal,
                    body: JSON.stringify({ session_id: context.sessionId, turn_id: turn.turnId, ...params }),
                },
            );
            return { content: [{ type: "text" as const, text: "Scheduled task completed." }], details: result };
        },
    });
}

interface SelectedWebImage {
    readonly title: string;
    readonly sourceUrl: string;
    readonly imageUrl: string;
    readonly originalImageUrl: string;
    readonly mediaType: "image/jpeg" | "image/png";
    readonly base64: string;
    readonly width: number;
    readonly height: number;
}

async function searchImages(
    query: string,
    count: number,
    signal: AbortSignal,
): Promise<readonly SelectedWebImage[]> {
    const apiKey = braveApiKey();
    const params = new URLSearchParams({
        q: query,
        count: String(Math.max(count, 8)),
        safesearch: "strict",
        spellcheck: "true",
    });
    const response = await fetch(
        `https://api.search.brave.com/res/v1/images/search?${params.toString()}`,
        {
            headers: {
                "X-Subscription-Token": apiKey,
                "Accept": "application/json",
            },
            signal: combinedSignal(signal, 30_000),
        },
    );
    if (!response.ok)
        throw new Error(`Brave Image Search failed with HTTP ${response.status}.`);
    const payload: unknown = await response.json();
    if (!isObject(payload) || !Array.isArray(payload.results))
        throw new Error("Brave Image Search returned an invalid response.");
    const selected: SelectedWebImage[] = [];
    for (const candidate of payload.results as BraveImageResult[]) {
        if (selected.length >= count) break;
        const imageUrl = candidate.thumbnail?.src;
        const sourceUrl = candidate.url;
        if (typeof imageUrl !== "string" || typeof sourceUrl !== "string") continue;
        try {
            const image = await fetchPublicImage(imageUrl, signal);
            selected.push({
                title: displayImageTitle(candidate.title),
                sourceUrl,
                imageUrl,
                originalImageUrl: typeof candidate.properties?.url === "string"
                    && /^https?:\/\//iu.test(candidate.properties.url)
                    ? candidate.properties.url
                    : imageUrl,
                mediaType: image.mediaType,
                base64: image.base64,
                width: image.width,
                height: image.height,
            });
        } catch {
            continue;
        }
    }
    if (selected.length !== count)
        throw new Error(`Image search found ${selected.length} safe readable images; ${count} required.`);
    return selected;
}

function displayImageTitle(value: unknown): string {
    if (typeof value !== "string" || !value.trim()) return "Web image";
    const withoutDimensions = value.replace(
        /\s*\(\s*\d{2,5}\s*[x×]\s*\d{2,5}\s*\)\s*/giu,
        " ",
    );
    const withoutDownloadSuffix = withoutDimensions.replace(
        /\s*[,|–—-]\s*(?:png|jpe?g)?\s*download\s*$/iu,
        "",
    ).trim();
    return withoutDownloadSuffix || "Web image";
}

function braveApiKey(): string {
    const environmentKey = process.env.BRAVE_API_KEY?.trim();
    if (environmentKey) return environmentKey;
    const configDir = process.env.PI_CODING_AGENT_DIR
        ?? (process.env.XDG_CONFIG_HOME
            ? join(process.env.XDG_CONFIG_HOME, "pi")
            : join(homedir(), ".pi"));
    const configPath = join(configDir, "web-search.json");
    let parsed: unknown;
    try {
        parsed = JSON.parse(readFileSync(configPath, "utf8"));
    } catch {
        throw new Error("Brave Image Search credentials are unavailable.");
    }
    if (!isObject(parsed) || typeof parsed.braveApiKey !== "string"
        || !parsed.braveApiKey.trim())
        throw new Error("Brave Image Search credentials are unavailable.");
    return parsed.braveApiKey.trim();
}

async function fetchPublicImage(
    initialUrl: string,
    signal: AbortSignal,
): Promise<Pick<SelectedWebImage, "mediaType" | "base64" | "width" | "height">> {
    let current = new URL(initialUrl);
    for (let redirect = 0; redirect <= 3; redirect++) {
        await requirePublicHttpUrl(current);
        const response = await fetch(current, {
            redirect: "manual",
            // Pi's OpenAI-compatible model path reliably accepts PNG/JPEG tool
            // images. Some LM Studio backends reject WebP data URLs with a
            // misleading base64 error, so ask the search proxy for a portable
            // representation and skip any server that ignores negotiation.
            headers: { "Accept": "image/png,image/jpeg" },
            signal: combinedSignal(signal, 20_000),
        });
        if (response.status >= 300 && response.status < 400) {
            const location = response.headers.get("location");
            if (location === null) throw new Error("Image redirect has no location.");
            current = new URL(location, current);
            continue;
        }
        if (!response.ok) throw new Error(`Image download failed with HTTP ${response.status}.`);
        const mediaType = normalizedImageType(response.headers.get("content-type"));
        const declaredLength = Number(response.headers.get("content-length") ?? "0");
        if (Number.isFinite(declaredLength) && declaredLength > 8_000_000)
            throw new Error("Image exceeds the 8 MB limit.");
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (bytes.length === 0 || bytes.length > 8_000_000)
            throw new Error("Image size is outside the allowed range.");
        requireImageSignature(bytes, mediaType);
        const dimensions = requireSafePixelCount(bytes, mediaType);
        return {
            mediaType,
            base64: Buffer.from(bytes).toString("base64"),
            ...dimensions,
        };
    }
    throw new Error("Image redirected too many times.");
}

function requireImageSignature(
    bytes: Uint8Array,
    mediaType: SelectedWebImage["mediaType"],
): void {
    const matches = mediaType === "image/png"
        ? bytes.length >= 8
            && [137, 80, 78, 71, 13, 10, 26, 10].every(
                (value, index) => bytes[index] === value,
            )
        : bytes.length >= 3
            && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    if (!matches) throw new Error("Image bytes do not match the declared media type.");
}

function requireSafePixelCount(
    bytes: Uint8Array,
    mediaType: SelectedWebImage["mediaType"],
): { width: number; height: number } {
    const dimensions = mediaType === "image/png"
        ? pngDimensions(bytes)
        : jpegDimensions(bytes);
    if (dimensions.width <= 0 || dimensions.height <= 0
        || dimensions.width * dimensions.height > 25_000_000)
        throw new Error("Image pixel dimensions are outside the safe range.");
    return dimensions;
}

function pngDimensions(bytes: Uint8Array): { width: number; height: number } {
    if (bytes.length < 24
        || Buffer.from(bytes.subarray(12, 16)).toString("ascii") !== "IHDR")
        throw new Error("PNG is missing its IHDR dimensions.");
    return {
        width: readUint32(bytes, 16),
        height: readUint32(bytes, 20),
    };
}

function jpegDimensions(bytes: Uint8Array): { width: number; height: number } {
    let offset = 2;
    while (offset + 3 < bytes.length) {
        if (bytes[offset] !== 0xff) {
            offset += 1;
            continue;
        }
        while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
        if (offset >= bytes.length) break;
        const marker = bytes[offset] ?? 0;
        offset += 1;
        if (marker === 0xd8 || marker === 0xd9 || marker === 0x01
            || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (offset + 1 >= bytes.length) break;
        const length = ((bytes[offset] ?? 0) << 8) | (bytes[offset + 1] ?? 0);
        if (length < 2 || offset + length > bytes.length) break;
        const isStartOfFrame = (marker >= 0xc0 && marker <= 0xc3)
            || (marker >= 0xc5 && marker <= 0xc7)
            || (marker >= 0xc9 && marker <= 0xcb)
            || (marker >= 0xcd && marker <= 0xcf);
        if (isStartOfFrame) {
            if (length < 7) break;
            return {
                height: ((bytes[offset + 3] ?? 0) << 8) | (bytes[offset + 4] ?? 0),
                width: ((bytes[offset + 5] ?? 0) << 8) | (bytes[offset + 6] ?? 0),
            };
        }
        offset += length;
    }
    throw new Error("JPEG dimensions could not be read safely.");
}

function readUint32(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] ?? 0) * 0x1000000)
        + ((bytes[offset + 1] ?? 0) << 16)
        + ((bytes[offset + 2] ?? 0) << 8)
        + (bytes[offset + 3] ?? 0);
}

async function requirePublicHttpUrl(url: URL): Promise<void> {
    if (url.protocol !== "https:" && url.protocol !== "http:")
        throw new Error("Image URL must use HTTP(S).");
    if (url.username || url.password) throw new Error("Image URL credentials are forbidden.");
    const addresses = isIP(url.hostname)
        ? [{ address: url.hostname }]
        : await lookup(url.hostname, { all: true, verbatim: true });
    if (addresses.length === 0 || addresses.some(item => !isPublicAddress(item.address)))
        throw new Error("Image URL resolves to a private address.");
}

function isPublicAddress(address: string): boolean {
    const lower = address.toLocaleLowerCase();
    if (lower === "::1" || lower === "::" || lower.startsWith("fe80:")
        || lower.startsWith("fc") || lower.startsWith("fd")) return false;
    const mapped = lower.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/u)?.[1];
    const ipv4 = mapped ?? (isIP(lower) === 4 ? lower : undefined);
    if (ipv4 === undefined) return true;
    const [a = 0, b = 0] = ipv4.split(".").map(Number);
    return !(a === 0 || a === 10 || a === 127 || a >= 224
        || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
        || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127));
}

function normalizedImageType(
    contentType: string | null,
): SelectedWebImage["mediaType"] {
    const value = contentType?.split(";", 1)[0]?.trim().toLocaleLowerCase();
    if (value === "image/jpeg" || value === "image/png")
        return value;
    throw new Error(`Unsupported image media type: ${value ?? "missing"}.`);
}

function combinedSignal(signal: AbortSignal, timeoutMs: number): AbortSignal {
    return AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]);
}

async function capturePhoto(
    toolCallId: string,
    signal: AbortSignal,
): Promise<ClientToolDetail> {
    const turnContext = loadTurnContext();
    const timeoutMs = 30_000;
    const created = await httpJson<ClientToolDetail>(
        profileUrl("client-tools/requests"),
        {
            method: "POST",
            body: JSON.stringify({
                request_id: "",
                session_id: context.sessionId,
                turn_id: turnContext.turnId,
                tool_call_id: toolCallId,
                client_id: "",
                target: "active_voice_client",
                capability: "capture_photo",
                arguments: {},
                timeout_ms: timeoutMs,
            }),
        },
    );
    const requestId = created.request.request_id;
    if (!requestId.length)
        throw new Error("Wheatley did not return a photo request id.");

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (signal.aborted) throw new Error("Photo capture was cancelled.");
        const detail = await httpJson<ClientToolDetail>(
            profileUrl(
                `client-tools/requests/${encodeURIComponent(requestId)}`,
            ),
        );
        if (detail.result !== null) return detail;
        await delay(Math.min(500, Math.max(50, deadline - Date.now())), signal);
    }
    throw new Error(
        "Timed out waiting for the Wheatley client to capture a photo.",
    );
}

async function requestClientTool(
    toolCallId: string,
    capability: string,
    argumentsValue: Record<string, unknown>,
    signal: AbortSignal,
): Promise<ClientToolDetail> {
    const turnContext = loadTurnContext();
    const timeoutMs = 30_000;
    const created = await httpJson<ClientToolDetail>(
        profileUrl("client-tools/requests"),
        {
            method: "POST",
            body: JSON.stringify({
                request_id: "",
                session_id: context.sessionId,
                turn_id: turnContext.turnId,
                tool_call_id: toolCallId,
                client_id: turnContext.clientId,
                target: turnContext.clientId,
                capability,
                arguments: argumentsValue,
                timeout_ms: timeoutMs,
            }),
        },
    );
    const requestId = created.request.request_id;
    if (!requestId.length) throw new Error("Wheatley did not return a client tool request id.");
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (signal.aborted) throw new Error(`${capability} was cancelled.`);
        const detail = await httpJson<ClientToolDetail>(
            profileUrl(`client-tools/requests/${encodeURIComponent(requestId)}`),
        );
        if (detail.result !== null) return detail;
        await delay(Math.min(500, Math.max(50, deadline - Date.now())), signal);
    }
    throw new Error(`Timed out waiting for the Wheatley client to run ${capability}.`);
}

function absoluteApiUrl(url: string): string {
    return url.startsWith("http://") || url.startsWith("https://")
        ? url
        : `${new URL(context.apiBase).origin}${url}`;
}

async function httpBytes(url: string, signal: AbortSignal): Promise<ArrayBuffer> {
    const response = await fetch(url, { signal });
    if (!response.ok)
        throw new Error(`${response.status} ${response.statusText}: ${await response.text()}`);
    return await response.arrayBuffer();
}

function profileUrl(path: string): string {
    return `${context.apiBase}/profiles/${encodeURIComponent(context.profileId)}/${path}`;
}

function loadContext(): WheatleyContext {
    return {
        apiBase: requiredEnvironment("WHEATLEY_API_BASE").replace(/\/$/, ""),
        profileId: requiredEnvironment("WHEATLEY_PROFILE_ID"),
        sessionId: requiredEnvironment("WHEATLEY_SESSION_ID"),
        promptPrewarm: optionalFlagEnvironment("WHEATLEY_PROMPT_PREWARM"),
        turnContextPath:
            optionalEnvironment("WHEATLEY_TURN_CONTEXT_PATH") ?? null,
    };
}

function configureProviderRequest(pi: ExtensionAPI): void {
    pi.on("before_provider_request", async (event) => {
        if (!isObject(event.payload))
            throw new Error("Provider payload must be an object.");
        if (context.promptPrewarm) return { ...event.payload, max_tokens: 4 };
        const turn = loadTurnContext();
        const request = { ...event.payload, ...turn.providerRequest };
        await httpJson<{ readonly request_index: number }>(
            profileUrl(
                `turns/${encodeURIComponent(turn.turnId)}/llm-requests`
                    + `?session_id=${encodeURIComponent(context.sessionId)}`,
            ),
            {
                method: "POST",
                body: JSON.stringify({
                    captured_at: new Date().toISOString(),
                    pi_version: piVersion,
                    request,
                }),
            },
        );
        return request;
    });
}

function configureTurnSystemPrompt(pi: ExtensionAPI): void {
    if (context.promptPrewarm) return;
    pi.on("before_agent_start", (event) => {
        const wheatleyPrompt = loadTurnContext().systemPrompt.trim();
        if (!wheatleyPrompt.length) return;
        return {
            systemPrompt: [event.systemPrompt.trim(), wheatleyPrompt]
                .filter(Boolean)
                .join("\n\n"),
        };
    });
}

function configurePromptPrewarm(pi: ExtensionAPI): void {
    pi.on("tool_call", () => ({
        block: true,
        reason: "Tools are disabled during prompt prewarm.",
    }));
}

function loadTurnContext(): WheatleyTurnContext {
    if (context.turnContextPath !== null) {
        const parsed: unknown = JSON.parse(
            readFileSync(context.turnContextPath, "utf8"),
        );
        if (!isObject(parsed))
            throw new Error("Wheatley turn context must be an object.");
        const turnId = parsed.turn_id;
        const reasoningMode = parsed.reasoning_mode;
        const clientId = parsed.client_id;
        const systemPrompt = parsed.system_prompt;
        const providerRequest = parsed.provider_request;
        const screenCaptureScope = parsed.screen_capture_scope;
        const screenCaptureModelMaxLongEdgePx = parsed.screen_capture_model_max_long_edge_px;
        const screenCaptureModelPixelsPerLogicalPixel =
            parsed.screen_capture_model_pixels_per_logical_pixel;
        if (typeof turnId !== "string" || !turnId.trim())
            throw new Error("Wheatley turn context turn_id is required.");
        if (typeof clientId !== "string" || !clientId.trim())
            throw new Error("Wheatley turn context client_id is required.");
        if (typeof systemPrompt !== "string")
            throw new Error("Wheatley turn context system_prompt must be text.");
        if (!isObject(providerRequest))
            throw new Error("Wheatley turn context provider_request must be an object.");
        if (screenCaptureScope !== "" && screenCaptureScope !== "active_window"
            && screenCaptureScope !== "active_display" && screenCaptureScope !== "both")
            throw new Error("Wheatley screen capture scope is invalid.");
        if (typeof screenCaptureModelMaxLongEdgePx !== "number"
            || !Number.isInteger(screenCaptureModelMaxLongEdgePx)
            || screenCaptureModelMaxLongEdgePx <= 0)
            throw new Error("Wheatley screen capture long edge is invalid.");
        if (typeof screenCaptureModelPixelsPerLogicalPixel !== "number"
            || screenCaptureModelPixelsPerLogicalPixel <= 0)
            throw new Error("Wheatley screen capture logical pixel target is invalid.");
        return {
            turnId: turnId.trim(),
            reasoningMode: validateReasoningMode(reasoningMode),
            clientId: clientId.trim(),
            systemPrompt,
            providerRequest,
            screenCaptureScope,
            screenCaptureModelMaxLongEdgePx,
            screenCaptureModelPixelsPerLogicalPixel,
        };
    }
    return {
        turnId: requiredEnvironment("WHEATLEY_TURN_ID"),
        reasoningMode: validateReasoningMode(
            requiredEnvironment("WHEATLEY_REASONING_MODE"),
        ),
        clientId: optionalEnvironment("WHEATLEY_CLIENT_ID") ?? "unavailable",
        systemPrompt: "",
        providerRequest: {},
        screenCaptureScope: "",
        screenCaptureModelMaxLongEdgePx: 2560,
        screenCaptureModelPixelsPerLogicalPixel: 1,
    };
}

function validateReasoningMode(value: unknown): ReasoningMode {
    if (value === "off" || value === "minimal" || value === "low"
        || value === "medium" || value === "high" || value === "xhigh"
        || value === "max") return value;
    throw new Error("Wheatley reasoning mode is not in Pi's supported vocabulary.");
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalFlagEnvironment(name: string): boolean {
    const value = process.env[name]?.trim();
    if (!value) return false;
    if (value !== "1") throw new Error(`${name} must be 1 when present.`);
    return true;
}

function optionalEnvironment(name: string): string | undefined {
    const value = process.env[name]?.trim();
    return value || undefined;
}

function requiredEnvironment(name: string): string {
    const value = process.env[name]?.trim();
    if (!value) throw new Error(`${name} is required.`);
    return value;
}

async function httpJson<T>(url: string, init: RequestInit = {}): Promise<T> {
    const response = await fetch(url, {
        ...init,
        headers: {
            "Content-Type": "application/json",
            ...init.headers,
        },
    });
    const text = await response.text();
    if (!response.ok)
        throw new Error(`${response.status} ${response.statusText}: ${apiErrorMessage(text)}`);
    return JSON.parse(text) as T;
}

function apiErrorMessage(text: string): string {
    try {
        const value = JSON.parse(text) as { error?: { message?: unknown } };
        if (typeof value.error?.message === "string") return value.error.message;
    } catch {
        // Non-JSON errors retain their response text below.
    }
    return text;
}

function delay(milliseconds: number, signal: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
        if (signal.aborted) {
            reject(new Error("Cancelled."));
            return;
        }
        const abort = (): void => {
            clearTimeout(timer);
            reject(new Error("Cancelled."));
        };
        const timer = setTimeout(() => {
            signal.removeEventListener("abort", abort);
            resolve();
        }, milliseconds);
        signal.addEventListener("abort", abort, { once: true });
    });
}
