import type {
    ChatTransport,
    ModelInfo,
    ReasoningMode,
} from "../transport/ChatTransport";
import type { ChatLanguage } from "../chat/Language";
import { H } from "./h";
import { icon } from "./Icons";
import { detailField, iconActionButton } from "./UiPrimitives";
import { uiText, type UiText } from "./UiText";

interface Summary {
  readonly id: string;
  readonly state: string;
  readonly display_text: string;
  readonly target: string;
  readonly schedule_text: string;
  readonly next_run_at?: string;
}

/** Small task manager deliberately backed only by the server task APIs.  It
    contains no client-side schedule calculation or task state mutation. */
export class ScheduledTaskManager {
    readonly element: HTMLDialogElement;
    readonly editor: HTMLDialogElement;
    readonly #api: ChatTransport;
    readonly #list: HTMLElement;
    readonly #title: HTMLHeadingElement;
    readonly #close: HTMLButtonElement;
    readonly #editor: HTMLDialogElement;
    readonly #editorClose: HTMLButtonElement;
    readonly #editorTitle: HTMLInputElement;
    readonly #editorText: HTMLTextAreaElement;
    readonly #editorTarget: HTMLSelectElement;
    readonly #editorReasoning: HTMLSelectElement;
    readonly #editorModel: HTMLInputElement;
    readonly #schedule: ScheduleEditor;
    readonly #editorNextRun: HTMLOutputElement;
    readonly #saveButton: HTMLButtonElement;
    readonly #runButton: HTMLButtonElement;
    readonly #deleteButton: HTMLButtonElement;
    #editingId = "";
    #profileId = "";
    #sessionId = "";
    #modelId = "";
    #models: readonly ModelInfo[] = [];
    #language: ChatLanguage = "en";
    #returnToList = false;

    constructor(api: ChatTransport) {
        this.#api = api;
        this.#list = H.div().class("scheduled-task-list").el();
        this.#editor = document.createElement("dialog");
        this.editor = this.#editor;
        this.#editor.className = "scheduled-task-dialog scheduled-task-editor";
        this.#editorTitle = document.createElement("input");
        this.#editorText = document.createElement("textarea");
        this.#editorTarget = document.createElement("select");
        this.#editorReasoning = document.createElement("select");
        this.#editorModel = document.createElement("input");
        this.#schedule = new ScheduleEditor();
        this.#editorNextRun = document.createElement("output");
        this.#editorNextRun.className = "tool-detail-value scheduled-task-next-run";
        for (const control of [
            this.#editorTitle,
            this.#editorText,
            this.#editorTarget,
            this.#editorReasoning,
            this.#editorModel,
        ]) control.classList.add("tool-detail-input");
        this.#editorTitle.maxLength = 120;
        this.#editorText.maxLength = 8000;
        this.#editorText.rows = 7;
        this.#saveButton = this.#editorAction(
            "/icons/check.svg", () => void this.#saveEdit(),
        );
        this.#runButton = this.#editorAction(
            "/icons/play.svg", () => void this.#runEdited(),
        );
        this.#deleteButton = this.#editorAction(
            "/icons/trash.svg", () => void this.#deleteEdited(),
        );
        this.#editorClose = iconActionButton(
            "/icons/close.svg", () => void this.#returnFromEditor(),
        );
        const editorHeader = H.header()
            .class("tool-detail-header", "tool-detail-header-centered")
            .append(
                this.#saveButton,
                H.h2().class("tool-detail-title").text("Edit scheduled task").el(),
                H.div()
                    .class("scheduled-task-editor-actions")
                    .append(this.#runButton, this.#deleteButton, this.#editorClose)
                    .el(),
            )
            .el();
        const scheduleSection = document.createElement("section");
        scheduleSection.className = "scheduled-task-schedule";
        const scheduleTitle = document.createElement("h3");
        scheduleTitle.textContent = "Schedule";
        scheduleSection.append(scheduleTitle, this.#schedule.element);
        const editorForm = H.div()
            .class("scheduled-task-editor-form", "tool-detail-section")
            .append(
                detailField("Title", this.#editorTitle),
                detailField("Instruction", this.#editorText),
                detailField("Target", this.#editorTarget),
                detailField("Reasoning", this.#editorReasoning),
                detailField("Model (new chat only)", this.#editorModel),
                scheduleSection,
                detailField("Next run", this.#editorNextRun),
            )
            .el();
        this.#editor.append(
            editorHeader,
            H.div().class("tool-detail-content").append(editorForm).el(),
        );
        this.#editor.addEventListener("cancel", event => event.preventDefault());
        this.#title = H.h2().class("tool-detail-title").el();
        this.#close = iconActionButton("/icons/close.svg", () => this.element.close());
        this.element = document.createElement("dialog");
        this.element.className = "scheduled-task-dialog";
        this.element.append(
            H.header()
                .class("tool-detail-header", "tool-detail-header-centered")
                .append(this.#title, this.#close)
                .el(),
            H.div()
                .class("tool-detail-content")
                .append(H.div()
                    .class("scheduled-task-manager")
                    .append(this.#list)
                    .el())
                .el(),
        );
        this.element.addEventListener("cancel", event => event.preventDefault());
    }

    setContext(
        profileId: string,
        sessionId: string,
        modelId: string,
        models: readonly ModelInfo[],
        language: ChatLanguage,
    ): void {
        this.#profileId = profileId;
        this.#sessionId = sessionId;
        this.#modelId = modelId;
        this.#models = models;
        this.#language = language;
    }

    async open(): Promise<void> {
        const text = uiText(this.#language);
        this.#title.textContent = text.scheduledTasks;
        this.#close.ariaLabel = text.close;
        this.#list.replaceChildren();
        if (!this.element.open)
            this.element.showModal();
        await this.refresh();
    }

    async openEditor(taskId: string): Promise<void> {
        const tasks = this.#apiList(await this.#api.listScheduledTasks(this.#profileId));
        const task = tasks.find(candidate => candidate.id === taskId);
        if (task === undefined)
            throw new Error("Created scheduled task was not found.");
        await this.#edit(task);
    }

    async refresh(): Promise<void> {
        try {
            const response = this.#apiList(
                await this.#api.listScheduledTasks(this.#profileId),
            );
            this.#list.replaceChildren(
                ...(response.length
                    ? response.map((task) => this.#row(task))
                    : [this.#emptyState()]),
            );
        } catch (error) {
            this.#list.replaceChildren(
                H.div()
                    .text(error instanceof Error ? error.message : String(error))
                    .el(),
            );
        }
    }

    #emptyState(): HTMLElement {
        const text = uiText(this.#language);
        const guidance = document.createElement("p");
        guidance.textContent = text.noScheduledTasksGuidance(profileName(this.#profileId));
        return H.div()
            .class("scheduled-task-empty")
            .append(guidance)
            .el();
    }

    #row(task: Summary): HTMLElement {
        const enabled = task.state === "enabled" || task.state === "needs_attention";
        const canToggle = task.state === "enabled" || task.state === "disabled";
        const text = uiText(this.#language);
        const toggle = H.button()
            .class("popup-menu-icon", "popup-menu-check-icon", "scheduled-task-toggle")
            .attr("type", "button")
            .attr("aria-pressed", String(enabled))
            .attr("aria-label", enabled ? text.disableScheduledTask : text.enableScheduledTask)
            .append(icon(enabled ? "/icons/checkbox-checked.svg" : "/icons/checkbox-empty.svg"))
            .on("click", () => void this.#setEnabled(task, !enabled))
            .el();
        toggle.disabled = !canToggle;
        return H.div()
            .class("scheduled-task-row")
            .append(
                toggle,
                H.button()
                    .class("popup-menu-item", "scheduled-task-item")
                    .attr("type", "button")
                    .attr("role", "menuitem")
                    .append(
                        H.div()
                            .append(
                                H.div().class("scheduled-task-title").text(task.display_text).el(),
                                H.div()
                                    .class("scheduled-task-meta")
                                    .text(
                                        `${task.schedule_text} · ${targetLabel(task.target, text)}`,
                                    )
                                    .el(),
                            )
                            .el(),
                    )
                    .on("click", () => void this.#edit(task))
                    .el(),
            )
            .el();
    }

    async #setEnabled(task: Summary, enabled: boolean): Promise<void> {
        await this.#api.setScheduledTaskEnabled(this.#profileId, task.id, enabled);
        await this.refresh();
    }
    async #runEdited(): Promise<void> {
        if (!this.#editingId) return;
        await this.#api.runScheduledTaskNow(this.#profileId, this.#editingId);
        await this.#returnFromEditor();
    }
    async #deleteEdited(): Promise<void> {
        if (!this.#editingId || !globalThis.confirm(`Delete “${this.#editorTitle.value}”?`)) return;
        await this.#api.deleteScheduledTask(this.#profileId, this.#editingId);
        await this.#returnFromEditor();
    }
    async #edit(task: Summary): Promise<void> {
        const response = (await this.#api.getScheduledTask(
            this.#profileId,
            task.id,
        )) as { task?: TaskDetail };
        const current = response.task;
        if (current?.display_text === undefined || current.task_text === undefined
            || current.target?.kind === undefined || current.reasoning_mode === undefined)
            throw new Error("Invalid task detail response.");
        this.#editingId = task.id;
        const text = uiText(this.#language);
        this.#editorTarget.replaceChildren(...[
            ["active_user_session", text.scheduledTaskActiveChat],
            ["originating_session", text.scheduledTaskThisChat],
            ["new_session", text.scheduledTaskNewChat],
        ].map(([value, label]) => new Option(label, value)));
        this.#editorTitle.value = current.display_text;
        this.#editorText.value = current.task_text;
        this.#editorTarget.value = current.target.kind;
        this.#editorModel.value = current.target.model ?? "";
        this.#setReasoningOptions(
            current.target.kind === "new_session" ? this.#editorModel.value : this.#modelId,
            current.reasoning_mode,
        );
        this.#schedule.set(current.schedule);
        this.#editorNextRun.value = task.next_run_at === undefined
            ? text.noScheduledTaskNextRun
            : localDateTime(task.next_run_at);
        this.#saveButton.ariaLabel = text.saveScheduledTask;
        this.#saveButton.title = text.saveScheduledTask;
        this.#editorClose.ariaLabel = text.close;
        this.#runButton.ariaLabel = text.runScheduledTask;
        this.#runButton.title = text.runScheduledTask;
        this.#deleteButton.ariaLabel = text.deleteScheduledTask;
        this.#deleteButton.title = text.deleteScheduledTask;
        this.#runButton.disabled = task.state !== "enabled"
            && task.state !== "needs_attention"
            && task.state !== "disabled";
        this.#editorModel.disabled = current.target.kind !== "new_session";
        this.#editorTarget.onchange = () => {
            this.#editorModel.disabled = this.#editorTarget.value !== "new_session";
            this.#setReasoningOptions(
                this.#editorTarget.value === "new_session"
                    ? this.#editorModel.value
                    : this.#modelId,
                this.#editorReasoning.value,
            );
        };
        this.#editorModel.oninput = () => this.#setReasoningOptions(
            this.#editorModel.value,
            this.#editorReasoning.value,
        );
        this.#returnToList = this.element.open;
        if (this.#returnToList)
            this.element.close();
        this.#editor.showModal();
    }

    async #saveEdit(): Promise<void> {
        if (!this.#editingId) return;
        const schedule = this.#schedule.value();
        const patch: Record<string, unknown> = {
            display_text: this.#editorTitle.value,
            task_text: this.#editorText.value,
            target: this.#editorTarget.value,
            reasoning_mode: this.#editorReasoning.value,
            schedule,
        };
        const modelId = this.#editorTarget.value === "new_session"
            && this.#editorModel.value.trim()
            ? this.#editorModel.value.trim()
            : this.#modelId;
        if (this.#editorTarget.value === "new_session")
            patch["model"] = modelId;
        await this.#api.updateScheduledTask(
            this.#profileId,
            this.#editingId,
            this.#sessionId,
            modelId,
            patch,
        );
        await this.#returnFromEditor();
    }

    async #returnFromEditor(): Promise<void> {
        const returnToList = this.#returnToList;
        this.#returnToList = false;
        this.#editingId = "";
        this.#editor.close();
        if (returnToList)
            await this.open();
    }

    #editorAction(source: string, onClick: () => void): HTMLButtonElement {
        return iconActionButton(source, onClick);
    }

    #setReasoningOptions(modelId: string, selected: string): void {
        const modes = this.#models.find(model => model.id === modelId)?.reasoningModes;
        const available = modes?.length ? modes : [selected as ReasoningMode];
        const binary = available.length === 2 && available.includes("off");
        this.#editorReasoning.replaceChildren(...available.map(mode => new Option(
            binary ? (mode === "off" ? "Off" : "On") : reasoningOptionLabel(mode),
            mode,
        )));
        this.#editorReasoning.value = available.includes(selected as ReasoningMode)
            ? selected
            : available[0]!;
    }

    #apiList(value: unknown): Summary[] {
        if (
            typeof value !== "object" ||
      value === null ||
      !Array.isArray((value as { tasks?: unknown }).tasks)
        )
            throw new Error("Invalid scheduled task list response.");
        return (value as { tasks: unknown[] }).tasks.map((value) => {
            const task = value as Partial<Summary>;
            if (
                typeof task.id !== "string" ||
        typeof task.state !== "string" ||
        typeof task.display_text !== "string" ||
        typeof task.target !== "string" ||
        typeof task.schedule_text !== "string"
            )
                throw new Error("Invalid scheduled task summary.");
            return task as Summary;
        });
    }
}

function profileName(id: string): string {
    return id.length === 0 ? id : id[0]!.toUpperCase() + id.slice(1);
}

function targetLabel(target: string, text: UiText): string {
    switch (target) {
        case "active_user_session": return text.scheduledTaskActiveChat;
        case "originating_session": return text.scheduledTaskThisChat;
        case "new_session": return text.scheduledTaskNewChat;
        default: return target;
    }
}

function localDateTime(value: string): string {
    const date = new Date(value);
    if (Number.isNaN(date.valueOf())) return value;
    return date.toLocaleString(undefined, {
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
    });
}

interface TaskDetail {
    readonly display_text?: string;
    readonly task_text?: string;
    readonly target?: { readonly kind?: string; readonly model?: string };
    readonly reasoning_mode?: string;
    readonly schedule?: unknown;
}

/** Edits the public schedule union directly. Dates and times remain semantic
    server values; only absolute timestamps are converted to/from the browser's
    local `datetime-local` control. */
class ScheduleEditor {
    readonly element: HTMLElement;
    readonly #kind = select([
        ["once", "Once"],
        ["fixed_interval", "Repeat at a fixed interval"],
        ["after_completion", "Repeat after completion"],
        ["calendar_daily", "Every day"],
        ["calendar_weekly", "Every week"],
        ["calendar_monthly", "Every month"],
        ["calendar_yearly", "Every year"],
        ["agent_managed_next", "Agent chooses the next run"],
    ]);
    readonly #details = H.div().class("schedule-editor-details").el();
    readonly #at = input("datetime-local");
    readonly #amount = input("number");
    readonly #unit = select([
        ["1", "seconds"], ["60", "minutes"], ["3600", "hours"], ["86400", "days"],
    ]);
    readonly #startDate = input("date");
    readonly #time = input("time");
    readonly #calendarInterval = input("number");
    readonly #weekdays = new Map<string, HTMLInputElement>();
    readonly #weekdayLabels = new Map<string, HTMLElement>();
    readonly #monthDays = input("text");
    readonly #monthRule = select([
        ["month_days", "Days of month"], ["ordinal_weekday", "Weekday in month"],
    ]);
    readonly #ordinal = select([
        ["1", "First"], ["2", "Second"], ["3", "Third"], ["4", "Fourth"],
        ["5", "Fifth"], ["-1", "Last"],
    ]);
    readonly #ordinalWeekday = select([
        ["MO", "Monday"], ["TU", "Tuesday"], ["WE", "Wednesday"],
        ["TH", "Thursday"], ["FR", "Friday"], ["SA", "Saturday"],
        ["SU", "Sunday"],
    ]);
    readonly #months = input("text");
    readonly #excludedDates = input("text");
    readonly #endKind = select([
        ["none", "No end"], ["count", "After occurrences"], ["until", "Until date and time"],
    ]);
    readonly #endCount = input("number");
    readonly #endAt = input("datetime-local");
    readonly #endDate = input("date");

    constructor() {
        this.#at.step = "1";
        this.#endAt.step = "1";
        this.#amount.min = "1";
        this.#amount.value = "1";
        this.#calendarInterval.min = "1";
        this.#calendarInterval.value = "1";
        this.#endCount.min = "1";
        this.#monthDays.placeholder = "1, 15, 31";
        this.#months.placeholder = "1, 6, 12";
        this.#excludedDates.placeholder = "2026-12-24, 2026-12-25";
        const weekdayOptions: readonly (readonly [string, string])[] = [
            ["MO", "Mon"], ["TU", "Tue"], ["WE", "Wed"], ["TH", "Thu"],
            ["FR", "Fri"], ["SA", "Sat"], ["SU", "Sun"],
        ];
        for (const [value, label] of weekdayOptions) {
            const checkbox = input("checkbox");
            checkbox.value = value;
            this.#weekdays.set(value, checkbox);
            const weekday = document.createElement("label");
            weekday.className = "schedule-editor-weekday";
            weekday.append(checkbox, document.createTextNode(label));
            this.#weekdayLabels.set(value, weekday);
        }
        this.#kind.addEventListener("change", () => this.#render());
        this.#endKind.addEventListener("change", () => this.#render());
        this.#monthRule.addEventListener("change", () => this.#render());
        this.element = H.div().class("schedule-editor").append(
            detailField("Repeat", this.#kind), this.#details,
        ).el();
        this.#render();
    }

    set(value: unknown): void {
        const schedule = record(value);
        const kind = stringValue(schedule, "kind");
        if (!scheduleKinds.has(kind)) throw new Error("Unsupported task schedule.");
        this.#kind.value = kind;
        this.#at.value = localInputDateTime(firstString(
            schedule, ["at", "anchor_at", "first_at", "next_at"],
        ));
        this.#startDate.value = stringValue(schedule, "start_date");
        this.#time.value = stringValue(schedule, "time");
        this.#calendarInterval.value = positiveValue(schedule["interval"], "1");
        const seconds = numberValue(schedule["every_seconds"] ?? schedule["delay_seconds"]);
        this.#setDuration(seconds);
        const monthRule = record(schedule["on"]);
        this.#monthRule.value = stringValue(monthRule, "kind") || "month_days";
        this.#monthDays.value = listValue(monthRule["days"]);
        this.#ordinal.value = numberValue(monthRule["ordinal"])?.toString() ?? "1";
        this.#ordinalWeekday.value = stringValue(monthRule, "weekday") || "MO";
        this.#months.value = listValue(schedule["months"]);
        this.#excludedDates.value = listValue(schedule["excluded_dates"]);
        for (const checkbox of this.#weekdays.values()) checkbox.checked = false;
        for (const day of stringList(schedule["weekdays"])) {
            const checkbox = this.#weekdays.get(day);
            if (checkbox !== undefined) checkbox.checked = true;
        }
        this.#setEnd(record(schedule["end"]), kind.startsWith("calendar_"));
        this.#render();
    }

    value(): Record<string, unknown> {
        const kind = this.#kind.value;
        if (kind === "once") return { kind, when: absoluteTime(this.#at.value) };
        if (kind === "agent_managed_next")
            return { kind, first: absoluteTime(this.#at.value) };
        if (kind === "fixed_interval" || kind === "after_completion") {
            const first = absoluteTime(this.#at.value);
            return kind === "fixed_interval"
                ? {
                    kind,
                    first,
                    every_seconds: this.#duration("Interval"),
                    ...this.#end(false),
                }
                : {
                    kind,
                    first,
                    delay_seconds: this.#duration("Delay"),
                    ...this.#end(false),
                };
        }
        const calendar = {
            kind,
            start_date: required(this.#startDate.value, "Start date"),
            time: required(this.#time.value, "Time"),
            interval: positive(this.#calendarInterval.value, "Interval"),
            ...optionalList("excluded_dates", this.#excludedDates.value),
            ...this.#end(true),
        } as Record<string, unknown>;
        if (kind === "calendar_weekly") {
            const weekdays = [...this.#weekdays.values()]
                .filter(input => input.checked).map(input => input.value);
            if (weekdays.length === 0)
                throw new Error("Choose at least one weekday.");
            calendar["weekdays"] = weekdays;
        }
        if (kind === "calendar_monthly" || kind === "calendar_yearly") {
            calendar["on"] = this.#monthRule.value === "ordinal_weekday"
                ? {
                    kind: "ordinal_weekday",
                    ordinal: Number(this.#ordinal.value),
                    weekday: this.#ordinalWeekday.value,
                }
                : {
                    kind: "month_days",
                    days: numberList(this.#monthDays.value, "Month days"),
                };
        }
        if (kind === "calendar_yearly")
            calendar["months"] = numberList(this.#months.value, "Months");
        return calendar;
    }

    #render(): void {
        const kind = this.#kind.value;
        const calendar = kind.startsWith("calendar_");
        const fields: HTMLElement[] = [];
        if (kind === "once") fields.push(detailField("Run at", this.#at));
        if (kind === "agent_managed_next") fields.push(detailField("First run", this.#at));
        if (kind === "fixed_interval" || kind === "after_completion") {
            fields.push(detailField("First run", this.#at));
            fields.push(detailField(
                kind === "fixed_interval" ? "Repeat every" : "Wait after each run",
                inline(this.#amount, this.#unit),
            ));
        }
        if (calendar) {
            fields.push(detailField("Starts on", this.#startDate));
            fields.push(detailField("At time", this.#time));
            fields.push(detailField("Repeat every", this.#calendarInterval));
            if (kind === "calendar_weekly")
                fields.push(detailField("Days", weekdays(this.#weekdayLabels)));
            if (kind === "calendar_monthly" || kind === "calendar_yearly") {
                fields.push(detailField("Runs on", this.#monthRule));
                fields.push(detailField(
                    this.#monthRule.value === "ordinal_weekday" ? "Weekday" : "Days of month",
                    this.#monthRule.value === "ordinal_weekday"
                        ? inline(this.#ordinal, this.#ordinalWeekday)
                        : this.#monthDays,
                ));
            }
            if (kind === "calendar_yearly") fields.push(detailField("Months", this.#months));
            fields.push(detailField("Skip dates", this.#excludedDates));
        }
        if (kind === "fixed_interval" || kind === "after_completion" || calendar) {
            this.#endKind.options[2]!.text = calendar
                ? "Through date"
                : "Until date and time";
            fields.push(detailField("Ends", this.#endKind));
            if (this.#endKind.value === "count")
                fields.push(detailField("Occurrences", this.#endCount));
            if (this.#endKind.value === "until")
                fields.push(detailField(
                    calendar ? "Last date" : "Last run",
                    calendar ? this.#endDate : this.#endAt,
                ));
        }
        this.#details.replaceChildren(...fields);
    }

    #duration(label: string): number {
        return positive(this.#amount.value, label) * Number(this.#unit.value);
    }

    #setDuration(seconds: number | undefined): void {
        const units = [86_400, 3_600, 60, 1];
        const selected = units.find(unit => seconds !== undefined && seconds % unit === 0)
            ?? 1;
        this.#amount.value = ((seconds ?? 60) / selected).toString();
        this.#unit.value = selected.toString();
    }

    #setEnd(end: Record<string, unknown>, calendar: boolean): void {
        const kind = stringValue(end, "kind");
        this.#endKind.value = kind === "count" ? "count" : kind.length ? "until" : "none";
        this.#endCount.value = positiveValue(end["occurrences"], "");
        this.#endAt.value = localInputDateTime(stringValue(end, "at"));
        this.#endDate.value = stringValue(end, calendar ? "date" : "at");
    }

    #end(calendar: boolean): Record<string, unknown> {
        if (this.#endKind.value === "none") return {};
        if (this.#endKind.value === "count")
            return {
                end: {
                    kind: "count",
                    occurrences: positive(this.#endCount.value, "Occurrences"),
                },
            };
        return { end: calendar
            ? { kind: "through", date: required(this.#endDate.value, "Last date") }
            : { kind: "until", at: absoluteTime(this.#endAt.value).at } };
    }
}

const scheduleKinds = new Set([
    "once", "fixed_interval", "after_completion", "calendar_daily", "calendar_weekly",
    "calendar_monthly", "calendar_yearly", "agent_managed_next",
]);

function input(type: string): HTMLInputElement {
    const value = document.createElement("input");
    value.type = type;
    if (type !== "checkbox") value.classList.add("tool-detail-input");
    return value;
}

function select(options: readonly (readonly [string, string])[]): HTMLSelectElement {
    const value = document.createElement("select");
    value.className = "tool-detail-input";
    value.replaceChildren(...options.map(([optionValue, label]) =>
        new Option(label, optionValue)));
    return value;
}

function inline(...controls: HTMLElement[]): HTMLElement {
    return H.div().class("schedule-editor-inline").append(...controls).el();
}

function reasoningOptionLabel(mode: ReasoningMode): string {
    switch (mode) {
        case "off": return "Off";
        case "minimal": return "Min";
        case "low": return "L";
        case "medium": return "M";
        case "high": return "H";
        case "xhigh": return "XH";
        case "max": return "Max";
    }
}

function weekdays(values: ReadonlyMap<string, HTMLElement>): HTMLElement {
    return H.div().class("schedule-editor-weekdays").append(...values.values()).el();
}

function record(value: unknown): Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value)
        ? value as Record<string, unknown> : {};
}

function stringValue(value: Record<string, unknown>, key: string): string {
    return typeof value[key] === "string" ? value[key] : "";
}

function firstString(value: Record<string, unknown>, keys: readonly string[]): string {
    return keys.map(key => stringValue(value, key)).find(item => item.length) ?? "";
}

function numberValue(value: unknown): number | undefined {
    return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function positiveValue(value: unknown, fallback: string): string {
    const number = numberValue(value);
    return number !== undefined && number > 0 ? number.toString() : fallback;
}

function listValue(value: unknown): string {
    return Array.isArray(value) ? value.join(", ") : "";
}

function stringList(value: unknown): string[] {
    return Array.isArray(value)
        ? value.filter((item): item is string => typeof item === "string")
        : [];
}

function numberList(value: string, label: string): number[] {
    const values = value.split(",").map(item => item.trim()).filter(Boolean)
        .map(item => positive(item, label));
    if (values.length === 0) throw new Error(`${label} must not be empty.`);
    return [...new Set(values)];
}

function optionalList(key: string, value: string): Record<string, string[]> {
    const values = value.split(",").map(item => item.trim()).filter(Boolean);
    return values.length ? { [key]: values } : {};
}

function required(value: string, label: string): string {
    if (!value) throw new Error(`${label} is required.`);
    return value;
}

function positive(value: string, label: string): number {
    const result = Number(value);
    if (!Number.isInteger(result) || result <= 0)
        throw new Error(`${label} must be a positive whole number.`);
    return result;
}

function absoluteTime(value: string): { readonly kind: "at"; readonly at: string } {
    const date = new Date(value);
    if (Number.isNaN(date.valueOf()))
        throw new Error("Choose a valid date and time.");
    return { kind: "at", at: date.toISOString() };
}

function localInputDateTime(value: string): string {
    const date = new Date(value);
    if (Number.isNaN(date.valueOf())) return "";
    const part = (number: number): string => number.toString().padStart(2, "0");
    return `${date.getFullYear()}-${part(date.getMonth() + 1)}-${part(date.getDate())}`
        + `T${part(date.getHours())}:${part(date.getMinutes())}:${part(date.getSeconds())}`;
}
