# Scheduled Tasks

Status: implemented, 2026-08-17.

## 1. Scope

A Wheatley scheduled task is a durable instruction that starts a normal Pi/LLM
turn at a later time. There is no static notification action, delivered-reminder
inbox, cron entry per task, or model-free execution path.

This specification includes:

- one-time, fixed-interval, after-completion, daily, weekly, monthly, yearly,
  and agent-managed schedules;
- active-chat, originating-session, and new-session targets;
- conversational creation and management tools;
- the bell task manager and edit dialog;
- overdue and missed-occurrence behavior;
- model and reasoning selection;
- server-owned polling, execution, failure, and retention;
- active text and voice interjection; and
- daemon supervision.

National holidays, external calendars, email, cross-profile management, and
multi-server schedule execution are outside this specification.

## 2. Product invariants

1. Every occurrence that executes is a real LLM turn.
2. Every automatic, manual, or retry occurrence begins with one durable, silent
   `scheduled_task_trigger` tool event in the target session.
3. A task belongs to the profile in which it was created. Profile identity comes
   from trusted turn context and is absent from LLM-controlled arguments.
4. `wheatleyd` owns schedule evaluation, task mutation, target resolution, and
   execution. Clients only present state and report live interaction.
5. The scheduler is pull-based. It does not persist a pending-task queue or a
   waiting occurrence.
6. Temporary inability to run changes no task state. A later poll derives the
   due work again.
7. A task never has two runs executing concurrently.
8. Fixed/calendar schedules do not replay a backlog: only the newest missed
   occurrence runs. After-completion and agent-managed schedules have exactly
   one next occurrence and therefore no backlog.
9. Existing Conversation ordering, execution claims, tool policy, Stop behavior,
   and terminal persistence remain authoritative after dispatch.

## 3. Execution targets

Schemas in Sections 3–7 describe server storage and runtime state unless a
later tool result explicitly reuses them. They are not automatically part of
the LLM context.

### 3.1 Active user session

`active_user_session` runs in the most recently interacted-with open chat in the
task's profile.

An eligible client must report an unexpired presence lease for an existing chat
and must still have that chat open. Focus and window visibility do not determine
eligibility; an open minimized Voice client remains eligible. If several chats
are open, the latest direct user interaction wins. If none is open, the task
stays due and the poll records nothing.

```ts
interface ActiveChatPresence {
    readonly client_id: string;
    readonly device_id: string;
    readonly profile_id: string;
    readonly session_id: string;
    readonly view: "chat";
    readonly phase:
        | "idle"
        | "typing"
        | "listening"
        | "transcribing"
        | "model_turn"
        | "speaking"
        | "stopping";
    readonly visible: boolean;
    readonly last_interaction_at: Timestamp;
    readonly expires_at: Timestamp;
}
```

`visible` contributes only to seen/unseen presentation; it does not affect
target eligibility.

The selected chat is provisional until dispatch. If it closes or changes before
claim, Wheatley resolves the target again. It never starts the turn in a closed
or stale session.

The run uses the model currently selected in the chosen chat. The task stores no
model for this target.

### 3.2 Originating session

`originating_session` always uses the exact session in which the task was
created. No client needs to be open. It uses that session's last-used model and
enters its ordinary FIFO only when the session has no active turn.

If the session was deleted, belongs to another profile, cannot be resumed, or
its model is unavailable, the occurrence fails. Wheatley never substitutes an
active chat or a new session.

### 3.3 New session

`new_session` creates one fresh session for every occurrence. It never reuses
the originating session or a session created by an earlier occurrence.

The task stores one model. The server initializes it from the model executing
the create or retarget operation. Only a direct user edit may change it; no LLM
tool accepts a task-model field. If the stored model is unavailable, Wheatley
still creates the automatic session, records the failed occurrence there, and
keeps the session visible for diagnosis. There is no fallback model.

## 4. Schedule contract

All persisted schedules use the following closed shapes.

```ts
type Timestamp = string; // YYYY-MM-DDTHH:mm:ss
type DateText = string;  // YYYY-MM-DD
type TimeText = string;  // HH:mm

type Weekday = "MO" | "TU" | "WE" | "TH" | "FR" | "SA" | "SU";

type RecurrenceEnd =
    | { readonly kind: "count"; readonly occurrences: number }
    | { readonly kind: "until"; readonly at: Timestamp };

type CalendarEnd =
    | { readonly kind: "count"; readonly occurrences: number }
    | { readonly kind: "through"; readonly date: DateText };

type MonthRule =
    | {
        readonly kind: "month_days";
        readonly days: readonly number[];
    }
    | {
        readonly kind: "ordinal_weekday";
        readonly ordinal: -1 | 1 | 2 | 3 | 4 | 5;
        readonly weekday: Weekday;
    };

interface CalendarCommon {
    readonly start_date: DateText;
    readonly time: TimeText;
    readonly interval: number;
    readonly excluded_dates?: readonly DateText[];
    readonly end?: CalendarEnd;
}

type StoredSchedule =
    | {
        readonly kind: "once";
        readonly at: Timestamp;
    }
    | {
        readonly kind: "fixed_interval";
        readonly anchor_at: Timestamp;
        readonly every_seconds: number;
        readonly end?: RecurrenceEnd;
    }
    | {
        readonly kind: "after_completion";
        readonly first_at: Timestamp;
        readonly delay_seconds: number;
        readonly end?: RecurrenceEnd;
    }
    | (CalendarCommon & {
        readonly kind: "calendar_daily";
    })
    | (CalendarCommon & {
        readonly kind: "calendar_weekly";
        readonly weekdays: readonly Weekday[];
    })
    | (CalendarCommon & {
        readonly kind: "calendar_monthly";
        readonly on: MonthRule;
    })
    | (CalendarCommon & {
        readonly kind: "calendar_yearly";
        readonly months: readonly number[];
        readonly on: MonthRule;
    })
    | {
        readonly kind: "agent_managed_next";
        readonly next_at: Timestamp;
    };
```

Validation rules:

- timestamps, dates, and times must parse exactly in the shown forms;
- every interval and duration must be a positive integer;
- weekday, month, and day arrays must be non-empty and contain unique values;
- month numbers are `1..12`; month days are `1..31`;
- a count end contains at least one occurrence;
- `start_date` is both the lower bound and recurrence anchor;
- weeks start on Monday;
- `through` is inclusive;
- exclusions remove matching calendar dates before count is evaluated;
- a missing month day or ordinal weekday is skipped rather than moved to
  another date; for example, a monthly day 31 does not run in February; and
- “workday” normalizes to `calendar_weekly` with `MO TU WE TH FR`.

For fixed and calendar recurrence, cadence is anchored to the stored schedule,
not to the preceding run's completion. `count` counts logical non-excluded due
slots, including missed slots that Wheatley intentionally skips. A manual extra
run never changes cadence or count. `until.at` is inclusive.

`after_completion` is a distinct completion-relative recurrence. Its first
occurrence uses `first_at`. After each non-ambiguous terminal occurrence where
the agent started—normal completion, failure, or user stop—the server derives
exactly one next due time:

```text
next_run_at = finished_at + delay_seconds
```

The prior run's duration is irrelevant to lateness. A run that takes one hour
followed by a ten-minute completion delay produces roughly seventy minutes
between starts. It has no cadence slots, missed occurrences, or backlog. It can
be late only when the next run starts after the newly derived `next_run_at`.
`finished_at` is the server's durable Conversation terminal time. Client
rendering, TTS playback, and whether the user has seen the result do not extend
the completion delay.

`after_completion` count limits count logical agent-started occurrences,
including a failed or user-stopped occurrence; an explicit retry of an
ambiguous occurrence does not add another count. An inclusive `until.at`
permits a next occurrence only when its derived due time is at or before the
bound. After the final handled occurrence, the task becomes `completed`.

`agent_managed_next` stores only one exact next time. A variable range such as
“every 10 to 30 minutes” remains in `task_text`; there are no structured minimum
or maximum delay fields.

## 5. Task and run state

### 5.1 Persisted task

The profile path owns profile and task identity:

```text
Profiles/<profile>/scheduled-tasks/<task-id>/task.json
Profiles/<profile>/scheduled-tasks/<task-id>/active-run.json
```

Neither JSON file repeats `profile_id`. `task-id` is an opaque stable ID returned
by the tools.

```ts
type TaskState = "enabled" | "disabled" | "completed" | "needs_attention";
type ReasoningMode = "off" | "low" | "medium" | "high";

type StoredTarget =
    | { readonly kind: "active_user_session" }
    | {
        readonly kind: "originating_session";
        readonly session_id: string;
    }
    | {
        readonly kind: "new_session";
        readonly model: string;
    };

interface TaskCreation {
    readonly at: Timestamp;
    readonly session_id: string;
    readonly turn_id: string;
    readonly model: string;
    readonly reasoning_mode: ReasoningMode;
}

interface TaskFailure {
    readonly occurrence_id: string;
    readonly at: Timestamp;
    readonly kind: string;
    readonly message: string;
    readonly technical_excerpt?: string;
}

interface TaskRun {
    readonly occurrence_id: string;
    readonly trigger: "scheduled" | "manual" | "retry";
    readonly status: "completed" | "failed" | "ambiguous";
    readonly scheduled_for: Timestamp;
    readonly claimed_at: Timestamp;
    readonly agent_started_at?: Timestamp;
    readonly finished_at: Timestamp;
    readonly delayed_by_active_turn?: true;
    readonly missed_occurrences?: number;
    readonly missed_since?: Timestamp;
    readonly session_id?: string;
    readonly turn_id?: string;
    readonly model?: string;
    readonly recommended_reasoning_mode: ReasoningMode;
    readonly effective_reasoning_mode?: ReasoningMode;
}

interface ScheduledTask {
    readonly state: TaskState;
    readonly display_text: string;
    readonly task_text: string;
    readonly target: StoredTarget;
    readonly schedule: StoredSchedule;
    readonly reasoning_mode: ReasoningMode;
    readonly created: TaskCreation;
    readonly last_handled_scheduled_for?: Timestamp;
    readonly handled_occurrences?: number;
    readonly manual_trigger_at?: Timestamp;
    readonly completed_at?: Timestamp;
    readonly delete_at?: Timestamp;
    readonly last_run?: TaskRun;
    readonly last_failure?: TaskFailure;
}

interface ActiveRunClaim {
    readonly occurrence_id: string;
    readonly trigger: "scheduled" | "manual" | "retry";
    readonly scheduled_for: Timestamp;
    readonly claimed_at: Timestamp;
}
```

`task.json` is replaced atomically. `active-run.json` is created atomically only
when execution is about to start and removed after terminal task state is
published. It is an execution claim, not a pending occurrence. A claim left by
a dead daemon becomes an `ambiguous` run and is never replayed automatically.

The server derives `next_run_at` from the schedule, cursor, and latest run; it
is not duplicated in `task.json`. For `after_completion`, the first due time is
`first_at`; after the first handled occurrence it is derived from that
occurrence's `finished_at`. The sole schedules that store their exact next time
directly are `once.at` and `agent_managed_next.next_at`.

`handled_occurrences` is absent before the first handled recurrence and then
stores a positive logical count. Fixed/calendar recurrence adds skipped slots
plus the performed newest slot. After-completion recurrence adds one after each
non-ambiguous terminal occurrence for which `agent_started_at` is present.
Manual extras and retries do not add a second count. This cursor is task state,
not a pending occurrence.

`manual_trigger_at` is the only Run-now marker. It lives on the task rather than
in a queue, permits at most one unclaimed manual request, and is cleared by the
atomic claim flow. For fixed, calendar, and agent-managed schedules it is an
extra occurrence that leaves cadence unchanged. For `after_completion` it
replaces and consumes the one next occurrence; after that run finishes, its
finish time anchors the following delay. A one-time Run now instead changes
`once.at` to the current time because it is the same occurrence, not an extra
one.

The current run uses a frozen prompt, target, model, and reasoning snapshot.
While it runs, future `display_text`, `task_text`, target, model, reasoning,
delay, and end edits are allowed; changing schedule kind or the initial anchor
is rejected. Terminal processing re-reads current task state, preserves a user
disable, and applies an after-completion finish using the then-current delay and
end. The Conversation submission and event journal own the durable frozen
request after dispatch; `active-run.json` does not duplicate it.

### 5.2 State transitions

- New tasks start as `enabled`.
- User Off changes the state to `disabled`. Disabled tasks are retained and
  never run or delete automatically.
- User On changes a schedulable `disabled` task to `enabled`; an overdue task
  keeps its original due time. If the disabled task still has an unresolved
  attention condition, On restores `needs_attention` without scheduling a run.
  On is rejected when the task is already `needs_attention`; Run now is the
  explicit retry action.
- A successful or user-stopped one-time run changes `enabled` to `completed`,
  sets `delete_at` three days later, and is deleted then.
- If the user disabled a task while its run was executing, the run finishes but
  terminal processing preserves `disabled`; it must not convert the task to
  `completed` and later delete it.
- A failed or ambiguous one-time run becomes `needs_attention` and does not
  retry automatically.
- A failed or ambiguous fixed/calendar occurrence advances the handled cursor
  and leaves the task enabled for its next normal occurrence.
- A completed, failed, or user-stopped `after_completion` occurrence with
  `agent_started_at` leaves the task enabled and derives its next due time from
  `finished_at`, unless it was the final bounded occurrence. A permanent
  failure before the agent starts, or an ambiguous occurrence, becomes
  `needs_attention`; neither advances the handled count or recurrence anchor.
- A failed or ambiguous automatic agent-managed occurrence becomes
  `needs_attention` unless it already published a valid future `next_at` before
  failing. A published next time remains authoritative and lets recurrence
  continue with the failure supplied to the next run.
- A manual extra fixed/calendar/agent-managed run never changes the task's
  schedule or state; it updates only latest-run/failure information. A manual
  `after_completion` run is not extra and advances that recurrence.
- A fixed, calendar, or after-completion task becomes `completed` after its
  final bounded logical occurrence is handled. It is retained until explicitly
  deleted.
- A successful retry of a one-time task becomes `completed`; a successful
  agent-managed retry must establish its next time or complete the task.
- `complete_current_scheduled_task` changes the current task to `completed`.
  Completed repeating or agent-managed tasks remain until explicitly deleted.
- The ordinary assistant Stop action ends only the current run. It never
  disables or completes recurrence; Off, Delete, or
  `complete_current_scheduled_task` is required to stop future runs.
- Deleting a task never deletes sessions, turns, or artifacts it created.

Task storage retains only `last_run` and the most recent `last_failure`.
Conversation sessions and turns are the long-lived run history. Failure text is
server-produced, with a readable message up to 500 characters and an optional
technical excerpt up to 2,000 characters.

## 6. Due and missed occurrences

On every evaluation, the server derives due work from the current task file.
For a fixed or calendar schedule with several due slots, it selects the newest
one.

For example, if 09:00, 10:00, and 11:00 are due and Wheatley starts the 11:00
slot, the invocation receives:

```json
{
  "scheduled_for": "2026-08-17T11:00:00",
  "missed_occurrences": 2,
  "missed_since": "2026-08-17T09:00:00"
}
```

`missed_occurrences` counts only older skipped slots. `missed_since` is the
oldest skipped slot. Lateness is measured from the newest `scheduled_for`, not
from `missed_since`.

An `after_completion` task always has at most one derived occurrence. It never
receives `missed_occurrences` or `missed_since`. Its `scheduled_for` is
`first_at` for the first occurrence and otherwise the previous trustworthy
`finished_at + delay_seconds`.

Immediately before Pi starts, Wheatley records `agent_started_at` and derives:

```text
late_by_minutes = floor((agent_started_at - scheduled_for) / 60 seconds)
```

Only whole minutes are exposed. `delayed_by_active_turn` is included only when
Conversation timing proves that an already-running user or assistant turn
overlapped the due time and materially delayed dispatch. No general delay-reason
list is stored.

## 7. Model and reasoning

Each task stores one recommended `reasoning_mode`. The agent and user may edit
it. It is independent of the composer preference used for ordinary user
messages and never changes that preference.

The server resolves the run model from the target, then maps the recommendation
to the model's advertised `reasoning_modes`:

1. `[off]` always maps to `off`;
2. `[off, high]` maps `off` to `off` and every non-off recommendation to `high`;
3. if the exact recommendation is supported, use it; otherwise select the
   nearest level in `off < low < medium < high`, choosing the lower level on a
   tie.

A reasoning mismatch never fails a run. The task retains the recommendation;
`last_run` records both recommended and effective values. A missing model does
fail, and Wheatley never tries another model.

## 8. Tool contract

### 8.1 Configuration and exposure

The existing tool policy gains one family flag:

```json
{
  "tools": {
    "available": {
      "scheduled_tasks": true
    }
  }
}
```

When enabled, normal turns receive all task-management tools below.
The flag controls LLM access to management; it does not stop already stored
tasks from executing. A scheduled run always receives its two run-scoped
lifecycle tools because they are required to satisfy the stored task contract.

Server-only scoping rule, not included in any LLM prompt or tool definition:
the scheduled-task LLM contract has no profile concept. Its tool names,
descriptions, inputs, results, errors, scheduled context, and agent instructions
never expose an owner ID or say “current profile.” The server binds every call
to an internal profile scope obtained outside model-controlled or model-visible
data. Listing therefore returns only tasks in that scope, and an unknown or
foreign ID returns only `Task not found`.

Every tool input is a closed object: unknown fields and invalid union
combinations are rejected at the HTTP boundary. Optional result fields are
omitted when absent. The Pi extension renders a short textual result for the
model and preserves the exact structured result in tool details, following the
existing Wheatley tool convention.

### 8.2 Shared input types

```ts
type RelativeOrAbsoluteTime =
    | { readonly kind: "now" }
    | { readonly kind: "after"; readonly seconds: number }
    | { readonly kind: "at"; readonly at: Timestamp };

type CreateSchedule =
    | {
        readonly kind: "once";
        readonly when: RelativeOrAbsoluteTime;
    }
    | {
        readonly kind: "fixed_interval";
        readonly first: RelativeOrAbsoluteTime;
        readonly every_seconds: number;
        readonly end?: RecurrenceEnd;
    }
    | {
        readonly kind: "after_completion";
        readonly first?: RelativeOrAbsoluteTime;
        readonly delay_seconds: number;
        readonly end?: RecurrenceEnd;
    }
    | Extract<StoredSchedule,
        { readonly kind: "calendar_daily" }
        | { readonly kind: "calendar_weekly" }
        | { readonly kind: "calendar_monthly" }
        | { readonly kind: "calendar_yearly" }>
    | {
        readonly kind: "agent_managed_next";
        readonly first: RelativeOrAbsoluteTime;
    };

type TargetKind =
    | "active_user_session"
    | "originating_session"
    | "new_session";

interface TaskSummary {
    readonly id: string;
    readonly state: TaskState;
    readonly quick_status:
        | "ok"
        | "queued"
        | "running"
        | "running_but_last_run_failed"
        | "needs_attention"
        | "disabled"
        | "disabled_but_needs_attention"
        | "completed";
    readonly display_text: string;
    readonly target: TargetKind;
    readonly schedule_text: string;
    readonly next_run_at?: Timestamp;
    readonly late_by_minutes?: number;
    readonly last_run_status?: "completed" | "failed" | "ambiguous";
}
```

`now` and relative times are resolved from the server clock when the mutation
is accepted. An `after.seconds` value is a positive integer. `late_by_minutes`
is returned only for an enabled task at least one whole minute overdue.

`quick_status` is the compact operational state for a list: `ok` is an enabled
task with no active or manual run; `queued` is an accepted manual Run now request
waiting to be claimed; `running` has an active run; and
`running_but_last_run_failed` has an active run after a failed or ambiguous prior
run. `needs_attention`, `disabled`, `disabled_but_needs_attention`, and
`completed` communicate the corresponding non-runnable states. The raw `state`
and exact `last_run_status` remain authoritative.

For `after_completion`, `first` is optional in a schedule mutation. On create
or a change from another schedule kind, omission normalizes `first_at` to the
accepted mutation time plus `delay_seconds`. On a same-kind edit, omission
preserves the existing `first_at`. The agent sets `now`, `after`, or `at` only
when the user specifies or clearly implies a different first start. The
creating conversation turn is never a scheduled occurrence and never anchors
this recurrence.

The LLM-visible schedule description must distinguish the two interval forms:
`fixed_interval` anchors starts to a time cadence, while `after_completion`
waits `delay_seconds` after the previous terminal finish. The description uses
the same examples and selection rule as Section 9.1; the model must not infer
completion-relative behavior from an ordinary “every N minutes.”

### 8.3 Normal-turn tools

#### `create_scheduled_task`

```ts
interface CreateScheduledTaskInput {
    readonly display_text: string;
    readonly task_text: string;
    readonly target: TargetKind;
    readonly schedule: CreateSchedule;
    readonly reasoning_mode?: ReasoningMode;
}

interface CreateScheduledTaskResult {
    readonly id: string;
    readonly display_text: string;
    readonly target: TargetKind;
    readonly schedule_text: string;
    readonly next_run_at: Timestamp;
}
```

The server trims both text fields and rejects empty values. `display_text` is at
most 120 characters; `task_text` is at most 8,000. `task_text` must be a
complete imperative instruction that works in an otherwise empty session.

If `reasoning_mode` is omitted, the server copies the creating turn's mode. The
server records creation provenance and normalizes target and schedule. For
`originating_session` it stores the trusted current session ID. For
`new_session` it stores the creating turn's model. The input has no session,
model, enabled, ID, creation-time, or fallback field.

A successful create mutation is durable immediately. A later failure or user
stop of the creating conversation turn does not undo the task or change its
normalized first due time.

Example:

```json
{
  "display_text": "Tell one short joke every 10–30 minutes",
  "task_text": "Tell the user exactly one short joke. Before answering, use bash with python3 and random.randint(10, 30) to choose the next whole-minute delay, then call schedule_next_occurrence with that delay. If the user asks you to stop, call complete_current_scheduled_task. Keep the joke short.",
  "target": "active_user_session",
  "schedule": {
    "kind": "agent_managed_next",
    "first": {
      "kind": "after",
      "seconds": 1020
    }
  },
  "reasoning_mode": "off"
}
```

```json
{
  "id": "schedule_01K2JOKE7M9B4Q2W0A6Y",
  "display_text": "Tell one short joke every 10–30 minutes",
  "target": "active_user_session",
  "schedule_text": "Agent-managed · next at 14:18",
  "next_run_at": "2026-08-17T14:18:00"
}
```

Completion-relative example:

```json
{
  "display_text": "Tell one joke, then pause 20 seconds",
  "task_text": "Tell the user exactly one short joke. If the task should stop, call complete_current_scheduled_task. Keep the visible answer short.",
  "target": "active_user_session",
  "schedule": {
    "kind": "after_completion",
    "delay_seconds": 20
  },
  "reasoning_mode": "off"
}
```

#### `list_scheduled_tasks`

Input: `{}`.

Result:

```ts
interface ListScheduledTasksResult {
    readonly tasks: readonly TaskSummary[];
}
```

This compact result is sufficient for listing, matching by display text, and
selecting the nearest enabled task by earliest `next_run_at`. It does not return
task prompts or run history.

The model-visible tool result enumerates every returned task in order, with its
ordinal, exact `id`, title, raw state, quick status, target, schedule text,
next-run metadata, and compact run status. The `details` object carries the
same structured list for the UI; it is not the only source of task identities
for the model.

#### `get_scheduled_task`

Input: `{ readonly id: string }`.

Result:

```ts
interface ScheduledTaskDetail {
    readonly id: string;
    readonly state: TaskState;
    readonly display_text: string;
    readonly task_text: string;
    readonly target: StoredTarget;
    readonly schedule: StoredSchedule;
    readonly reasoning_mode: ReasoningMode;
    readonly created: TaskCreation;
    readonly next_run_at?: Timestamp;
    readonly late_by_minutes?: number;
    readonly last_run?: TaskRun;
    readonly last_failure?: TaskFailure;
}
```

#### `update_scheduled_task`

```ts
interface UpdateScheduledTaskInput {
    readonly id: string;
    readonly display_text?: string;
    readonly task_text?: string;
    readonly target?: TargetKind;
    readonly schedule?: CreateSchedule;
    readonly reasoning_mode?: ReasoningMode;
}

type UpdateScheduledTaskResult = TaskSummary;
```

At least one changed field is required. The server applies one atomic field
patch and preserves every omitted field. The tool cannot change a model. If an
agent retargets to `new_session`, the server seeds the model from the turn
performing the update. Retargeting away from `new_session` removes the stored
model.

Changing only `delay_seconds` or the end bound on an existing
`after_completion` task preserves its recurrence cursor and immediately
recalculates due time from the latest trustworthy `finished_at`; the task may
therefore become overdue. Before its first occurrence, editing `first` changes
the initial due time. After recurrence starts, `first_at` is read-only history.
The server rejects an attempted change to it rather than silently ignoring it.
Changing schedule kind creates a new recurrence sequence, clears the old
schedule cursor and handled count, and normalizes the new `first` value or its
documented default.
While a run is active, changing schedule kind or `first` is rejected; other
future-facing edits follow Section 5.1.

#### `set_scheduled_task_enabled`

Input:

```ts
interface SetScheduledTaskEnabledInput {
    readonly id: string;
    readonly enabled: boolean;
}
```

Result: `TaskSummary`.

Disabling affects later polling but never stops a current run. Enabling an
overdue schedulable task preserves its original due time. `enabled: true` is
rejected for a current `needs_attention` task. Enabling a disabled task with an
unresolved attention condition restores `needs_attention` and returns that
summary; the caller must use Run now for an explicit retry. Enabling a completed
task is rejected; the user may create a new task instead.

#### `delete_scheduled_task`

Input: `{ readonly id: string }`.

Result: `{ readonly deleted: true }`.

Deletion is rejected while that task has `active-run.json`.

#### `run_scheduled_task_now`

Input: `{ readonly id: string }`.

Result: `TaskSummary`.

The operation rejects an active run or an already stored manual trigger.

- For an enabled one-time task, it changes `once.at` to now.
- For a `needs_attention` one-time or agent-managed task, it stores
  `manual_trigger_at` as one explicit retry of the failed occurrence.
- For a Needs-attention `after_completion` task, it stores
  `manual_trigger_at` as one explicit retry of the ambiguous occurrence.
- For an enabled `after_completion` task, it stores `manual_trigger_at` as a
  replacement for its next occurrence. That run consumes the occurrence and
  anchors the following delay at its own `finished_at`.
- For an enabled fixed, calendar, or agent-managed task, it stores
  `manual_trigger_at` as an extra occurrence without moving normal cadence.
- A disabled or completed task must be enabled or recreated first.

The scanner claims the request when its target and runtime are executable. A
manual extra fixed/calendar/agent-managed run receives
`manual_extra_occurrence: true`. An after-completion manual occurrence receives
`false` because it advances that recurrence. A manual extra agent-managed run
is not allowed to replace the task's existing `next_at`.

For an enabled after-completion task, Run now preserves an already-due original
`scheduled_for`, so actual lateness remains truthful. When its derived next time
is still in the future, `scheduled_for` is the Run-now request time. This avoids
negative lateness while still recording that the occurrence ran early.

### 8.4 Scheduled-run tools

#### `schedule_next_occurrence`

Available only during a non-extra `agent_managed_next` run, including an
explicit retry.

Input: `RelativeOrAbsoluteTime`.

Result:

```ts
interface ScheduleNextOccurrenceResult {
    readonly next_run_at: Timestamp;
}
```

The tool is bound to the current scheduled run and therefore accepts no ID. It
replaces `schedule.next_at` atomically. A positive future time is required. It
is rejected during a manual extra run because that run must not move the
existing schedule.

#### `complete_current_scheduled_task`

Input:

```ts
interface CompleteCurrentScheduledTaskInput {
    readonly reason?: string;
}
```

Result: `{ readonly state: "completed" }`.

The optional reason is trimmed and limited to 500 characters. The tool is bound
to the current task and completes only that task.

### 8.5 Direct user edit

The browser dialog uses a server API that applies the same semantic patch as
`update_scheduled_task`, plus one UI-only optional `model` field. The server
accepts `model` only when the resulting target is `new_session`. `Auto` is a UI
label and is never persisted as a model ID.

The dialog submits only changed fields. LLM tool schemas and results never
provide a model mutation.

## 9. Agent instructions

The scheduled-run template is the profile-local Markdown file
`scheduled-task-turn.md`. Wheatley copies the bundled default into that file
only when it is first needed; the scheduler reads the profile file at dispatch,
not the bundled resource. It is exposed as the localized **Scheduled task**
document in Instructions, so the user can inspect and edit the exact
model-visible scheduler behavior. The template itself never reveals profile
identity to the model.

### 9.1 Normal conversation

Add this compact section to the private Pi context when scheduled-task tools are
available:

```md
Scheduled tasks:

- Use the scheduled-task tools for a requested future, repeating, calendar, or delayed action, and for a bounded wake-up needed to finish the current authorized task.
- Every occurrence is a real LLM turn. Write `task_text` as a complete imperative request that works in an otherwise empty session; include the subject, source/context, output shape, and stop or continuation rule. Never write only “do that again.”
- Use `active_user_session` for a reminder or interjection in the most recently interacted-with open chat. If no chat is open, it stays overdue.
- Use `originating_session` when the work must resume this exact conversation. It runs without an open client and never substitutes another session.
- Use `new_session` when every occurrence should create a separate result, such as a morning summary. The server inherits the creating chat's selected model; only the user may change a task model. If creation reports that the current chat has no selected model, do not add a model argument: ask the user to choose one in the chat, then retry.
- Set the task reasoning recommendation when useful. When the user asks for no thinking or a quick scheduled action, set it to `off`. Never select or change a task model.
- Use `fixed_interval` when starts stay anchored to a clock cadence, such as “every 10 minutes,” regardless of run duration. Use `after_completion` when the user asks for a pause after each run finishes. These are different schedules: never reinterpret ordinary “every 10 minutes” as completion-relative. Fixed, calendar, and after-completion recurrence is server-managed: their task text must never call `schedule_next_occurrence` or create a successor task merely to continue.
- Explicit “after completion,” “after each,” “pause,” or “wait between runs” wording selects `after_completion` even if the request also says “repeat” or “every.” Ask one short clarification only when the requested timing anchor is genuinely contradictory. When creating `after_completion`, confirm that the delay starts when each run finishes.
- For `after_completion`, set `first` to `now`, `after`, or `at` only when the user specifies or clearly implies that first start. Otherwise omit it; the first run defaults to one `delay_seconds` pause after task creation. The creating response is not the first scheduled occurrence. If `first` is `now`, create and confirm the task without also performing its body; the scheduled turn follows immediately.
- An `after_completion` task has one next occurrence and no missed slots. After the agent starts, the configured delay begins at terminal completion, failure, or user stop; an ambiguous run requires attention.
- An after-completion failure advances the delay only when the agent actually started. A permanent target/model failure before agent start requires attention and an explicit Run-now retry.
- Use calendar schedules for wall-clock recurrence. Use `agent_managed_next` only when the next time depends on randomness or the result of the current run.
- For a random delay, use `bash` with `python3` to choose the first exact value. Put the same Python instruction and the requested range in `task_text`; do not invent structured range fields.
- Confirm the target, normalized schedule, and next run after creation. Explain overdue/latest-only delivery only when it materially changes what the user expects.
- Call `list_scheduled_tasks` first for listing, nearest-task, matching, enable/disable, or delete requests. Fetch one full task only when its prompt or schedule must be inspected or edited.
- On never retries a Needs-attention task. Use `run_scheduled_task_now` only when the user requests a retry; otherwise explain that the task needs attention and leave it unchanged.
- Preserve fields the user did not ask to change. Ask only when multiple compact rows genuinely match.
- A self-created repeating continuation must stay within the current task's authority and have a clear completion condition. Complete or disable it as soon as the parent work finishes.
- After a concrete scheduled-run failure, you may improve that task's future `task_text` only when the change stays within its original authority and directly prevents the known failure.
```

### 9.2 Scheduled invocation

Every automatic, manual, and retry occurrence starts with one server-authored
tool-call event named `scheduled_task_trigger`. This applies to all three
targets, including the first turn of a new automatic session. Conversation
persists the event immediately before starting Pi, so a scheduled response can
never appear without its trigger event.

The event is presentation and provenance, not an executable Pi tool and not a
fabricated provider assistant/tool message. Its source is `scheduler`. Its
`succeeded` status means that Conversation accepted the occurrence and started
the scheduled turn; it does not mean that the LLM task succeeded. The
subsequent turn terminal state remains authoritative for the run outcome.

```ts
interface ScheduledTaskTriggerArguments {
    readonly task_id: string;
    readonly occurrence_id: string;
    readonly trigger: "scheduled" | "manual" | "retry";
    readonly display_text: string;
}

type ScheduledTaskInjectedPrompt = readonly [
    {
        readonly kind: "task_request";
        readonly placement: "current_request";
        readonly text: string;
    },
    {
        readonly kind: "scheduler_context";
        readonly placement: "private_context";
        readonly text: string;
    },
    {
        readonly kind: "scheduler_instructions";
        readonly placement: "private_context";
        readonly text: string;
    },
];

interface ScheduledTaskTriggerDetails {
    readonly target: StoredTarget;
    readonly schedule: StoredSchedule;
    readonly recommended_reasoning_mode: ReasoningMode;
    readonly scheduled_for: Timestamp;
    readonly agent_started_at: Timestamp;
    readonly late_by_minutes?: number;
    readonly delayed_by_active_turn?: true;
    readonly missed_occurrences?: number;
    readonly missed_since?: Timestamp;
    readonly manual_extra_occurrence: boolean;
    readonly injected_prompt: ScheduledTaskInjectedPrompt;
}

interface ScheduledTaskTriggerToolCall {
    readonly name: "scheduled_task_trigger";
    readonly source: "scheduler";
    readonly call_id: string;
    readonly status: "succeeded";
    readonly arguments: ScheduledTaskTriggerArguments;
    readonly result: {
        readonly content: string;
        readonly details: ScheduledTaskTriggerDetails;
    };
}
```

`call_id` is `scheduled-task:<occurrence_id>`. Result `content` is the compact
localized inline label, for example `Scheduled task: Tell one short joke every
10–30 minutes`. The structured details are an immutable snapshot from this
occurrence. Conversation assigns this first public tool call the turn-local
`call_index`; later Pi calls use subsequent public indices rather than reusing
producer-specific numbering.

`injected_prompt` is the exhaustive ordered set of text added to the model input
because this occurrence fired:

1. the exact `task_text` used as the current request;
2. the exact serialized scheduler context, including timing, missed-run, and
   previous-failure data that were present; and
3. the exact scheduler-management instructions appended for this run.

Conversation freezes and persists these UTF-8 strings after all interpolation
and immediately before submission. They are never regenerated from the current
task or current instruction templates. Ordinary prior conversation and
baseline instructions that would have existed without the scheduled trigger
are not copied into this occurrence record.

The scheduled turn is then submitted through normal Conversation with source
`scheduled_task`. `task_text` becomes the current Pi request, but it is not
stored or displayed as a user-authored bubble and is excluded from automatic
memory evidence. The trigger tool event is displayable conversation history but
is also excluded from automatic memory evidence.

Wheatley supplies a server-authored context block immediately before Pi starts:

```json
{
  "scheduled_task": {
    "id": "schedule_01K2JOKE7M9B4Q2W0A6Y",
    "display_text": "Tell one short joke every 10–30 minutes",
    "target": "active_user_session",
    "schedule_kind": "agent_managed_next",
    "scheduled_for": "2026-08-17T13:47:00",
    "agent_started_at": "2026-08-17T13:52:00",
    "late_by_minutes": 5,
    "delayed_by_active_turn": true,
    "missed_occurrences": 2,
    "missed_since": "2026-08-17T13:19:00",
    "manual_extra_occurrence": false,
    "previous_run": {
      "status": "completed",
      "finished_at": "2026-08-17T13:19:08",
      "session_id": "2026/08/17/13_05_10",
      "turn_id": "13_19_00_456789",
      "model": "lmstudio/qwen3.8-27b"
    }
  }
}
```

Optional fields are omitted, not set to `null`. The block includes
`previous_failure` only when `previous_run` is failed or ambiguous and its
occurrence ID matches `last_failure`. A later successful run therefore stops
injecting an older failure while the dialog may still display it:

```json
{
  "previous_failure": {
    "kind": "tool_error",
    "message": "Download status command exited with code 2.",
    "technical_excerpt": "unknown option: --progress-json"
  }
}
```

Append these runtime instructions:

```md
This is an automatic scheduled-task turn, not a new user message. Perform the current task request now. Use surrounding conversation only when relevant.

Mention material lateness when timing matters. `late_by_minutes` is the delay from the occurrence being performed. Mention a previous active turn only when `delayed_by_active_turn` is present and useful. Do not invent another delay reason.

If `missed_occurrences` is present, perform only this newest occurrence. Do not replay or claim to have performed the older slots. Mention the wider gap only when useful.

Use the concise previous failure to choose a non-failing approach. You may update this task's future instruction only within its existing authority; never copy a large log into it.

For an automatic `agent_managed_next` run, call `schedule_next_occurrence` before the visible answer unless the task should now complete. For a random delay, use `bash` with `python3` and the range in the task request. Fixed, calendar, and after-completion tasks are server-managed: never call `schedule_next_occurrence` for them and never create a replacement task merely to continue their recurrence. During a manual extra occurrence, do not call `schedule_next_occurrence`.

Call `complete_current_scheduled_task` when the task's completion condition is satisfied. Keep the visible answer about the task, not scheduler metadata.
```

If an automatic agent-managed run reaches a normal LLM terminal state without
either scheduling the next occurrence or completing the task, terminal
validation marks the run failed with `missing_next_occurrence` and changes the
task to `needs_attention`.

## 10. Scheduler runtime

One process-lifetime `Scheduler` in the authoritative `wheatleyd` owns task
loading, schedule calculation, target resolution, run claims, Conversation
submission, terminal task mutation, retention, and task-change events.

The poll interval is five seconds and is an implementation constant, not user
configuration.

On each poll:

1. Load task files and reconcile abandoned active claims. Normal schedule due
   work comes only from enabled tasks; a Needs-attention task is executable only
   when it has an explicit retry trigger.
2. Ignore any task with a live `active-run.json`.
3. Derive normal and manual due times from current task state. For fixed and
   calendar recurrence, retain only the newest missed scheduled slot. For
   after-completion recurrence, derive its sole next occurrence from the first
   time or latest trustworthy finish.
4. Order currently due candidates by due time. Equal due times keep natural
   scan/admission order; there is no extra creation-ID tie policy.
5. Resolve the target, model, reasoning, session lane, Pi capacity, and any
   required Voice suspension.
6. For a temporary obstacle—no eligible active chat, busy Conversation lane,
   occupied model capacity, or unsuccessful Voice suspension—write nothing and
   continue the poll.
7. For a permanent target/model error, claim the occurrence and publish a
   failed terminal result so the schedule cannot spin on the same slot.
8. Immediately before dispatch, re-read and revalidate task state and target,
   then atomically create `active-run.json`.
9. Submit one normal observer-independent Conversation turn, follow it to
   terminal persistence, publish `last_run`/`last_failure` and schedule state,
   remove the claim, and emit UI invalidation.
10. Scan again and drain all currently executable due tasks one by one before
    accepting the next ordinary user turn.

The same task is ignored while its run executes. Different due tasks are
first-come/oldest-due; there is no type priority or persistent scheduler lane.

Ordinary user turns already accepted before a task became due finish normally.
A due scheduled task runs before the next ordinary user turn is accepted.

An OS kill after claim may leave tool side effects uncertain. Restart
reconciliation records `ambiguous`; it never retries that occurrence through
another model. Fixed/calendar tasks continue with their next cadence slot;
one-time and after-completion tasks require attention, and agent-managed tasks
continue only when a future `next_at` was already published before the crash.

## 11. Presentation

### 11.1 Scheduled Tasks menu

Scheduled Tasks lives in the existing Home and chat overflow menus (Home above
Instructions; chat below Compact now). It opens one compact profile-local list.
It is a task manager, not a notification inbox, and has no `+` or manual
creation form.

Each row is a menu-style list item:

```text
[✓]  Daily meeting
     Mo Tu We Th Fr 09:30 · Active chat
```

- For enabled/disabled tasks, the first control uses the existing checked/empty
  menu decorator and toggles On/Off without opening the editor. Needs-attention
  rows are visibly checked but non-toggle; retry is available as Run now in the
  editor and never occurs from an On click.
- The clickable item contains `display_text` and muted localized compact
  schedule plus target metadata. It does not display task state or a time.
- Clicking the item opens the edit dialog; there is no ellipsis or separate
  Edit action.

Rows sort enabled tasks by derived `next_run_at`, then Needs attention, then
disabled/completed tasks. An enabled task at least one whole minute overdue
shows accessible text such as `5 min late` plus a warm attention treatment;
color is not the only signal. The bell itself needs no ordinary due/completed
badge. It may show an attention marker for failures or ambiguity.

### 11.2 Edit dialog

The editor uses the same Tool Details-style 80% dialog shell as the task list,
with its title and shared SVG X close control. It replaces the list dialog
rather than stacking on it. The X is the only discard/close route; backdrop and
Escape do not close it. Run now uses the play icon and Delete reuses the trash
icon. A checkmark before the title saves changes; there are no footer Save or
Cancel buttons. `Next run` appears only here, labelled as such and formatted by the
browser in local date/time to seconds; it is a read-only runtime value. The
schedule editor never exposes raw JSON: it selects a schedule type and presents
only its user-editable fields. Absolute run times use native browser
`datetime-local` pickers (including seconds) and are converted to the API's
timestamp form at the client boundary. Calendar schedules use native date/time
pickers plus their applicable interval, weekdays, month rule, excluded-date,
and end controls.

The dialog contains:

1. state, next run, Run now, On/Off, and Delete;
2. short display text and complete `task_text`;
3. target;
4. schedule controls and up to the next three derivable occurrences;
5. task model and reasoning recommendation;
6. creation time and links to the creating session/turn;
7. latest run, including scheduled/start/finish times, OK/failed/ambiguous,
   lateness, resolved session, model, and effective reasoning; and
8. latest failure with its concise technical detail.

For Needs attention, actions are Run now, Disable, and Delete; there is no On
action. A disabled task that still has an unresolved attention condition
returns to Needs attention when switched On and still requires Run now.

Creation provenance and run records are read-only. Task text, target, schedule,
state, and reasoning are user-editable. The model is user-editable only for
`new_session`.

Reuse the composer model/reasoning control visually but bind it to task state,
not to the ordinary user-message preference. The task reasoning button cycles
`Off`, `Low`, `Medium`, and `High` recommendations for every target. For active
and originating targets, the model select contains disabled `Auto`. For a new
session target, it contains the normal model catalog and is enabled.

Related widgets form compound controls: shared borders, rounded outer corners,
and square touching corners. This applies to date/time, value/unit, target/model,
weekday, and related multiline controls. Weekdays are independent Monday-first
toggle buttons labeled `Mo Tu We Th Fr Sa Su`, with `aria-pressed` and visible
keyboard focus. They reuse the visual language, not the navigation semantics,
of the Instruction-screen tabs.

The schedule type control presents `Fixed interval` and `After completion` as
distinct choices with concise help: `Starts every N` and `Wait N after each run
finishes`. Before the first run, its start control offers `After one delay`
(default), `Now`, `After`, and `At`; the server stores the resulting concrete
`first_at`. The schedule also edits completion delay and optional end.
After the first occurrence, the initial time is read-only while delay and end
remain editable. Its preview shows only one derivable next occurrence and labels
it, for example, `20 sec after completion`; it never suggests wall-clock cadence
or missed instances.

When a browser turn creates a task, its task-created event immediately opens
this dialog. The task already exists. `OK` sends changed fields and closes it;
closing with Escape or outside the dialog discards unsaved edits but leaves the
created task intact. Console creation uses the textual tool result.

### 11.3 Trigger tool-call presentation

Every scheduled turn displays its `scheduled_task_trigger` tool event inline
immediately before the assistant's scheduled output. The compact line uses the
task's `display_text` and a bell, for example:

```text
🔔 Scheduled task: Tell one short joke every 10–30 minutes
```

The browser renders the line through the existing tool-call presentation. It is
clickable and opens the Tool details dialog. The dialog shows the exact
canonical Pi-session user-message event for that scheduled occurrence, or the
exact `model-input.json` text while the canonical event is not yet available.
Inspection metadata states that the occurrence produced one Pi prompt RPC and
one Pi user message. The immutable occurrence snapshot remains available, but
its redundant `injected_prompt` audit copy is not projected beside the actual
message. Text is complete, whitespace-preserving, scrollable, and copyable; it
is never summarized or truncated. The transcript contains only the compact
trigger tool line and never creates a user prompt bubble or a second
`Model context` item. A `Model context` item can precede it only when this is
also the first Pi turn of the session, where it represents session startup.

The text and Voice consoles print the same compact line as an ordinary tool
event before streaming the assistant response. The trigger label and snapshot
are scheduler provenance and are never sent to Pi or TTS as a second turn. The
single inspected user-message event is the actual Pi input. The assistant's
resulting answer follows the ordinary speech rules.

Add `scheduler` to the durable tool-detail source enum and localize
`scheduled_task_trigger` as `Scheduled task`. The generic tool status remains
`Succeeded`; the dialog labels it as trigger delivery, not completion of the
scheduled work.

### 11.4 Automatic-session and scheduled-turn markers

Every scheduled turn stores immutable source provenance:

```json
{
  "source": "scheduled_task",
  "scheduled_task_trigger_call_index": 0
}
```

The referenced tool call owns the full immutable occurrence snapshot; turn
metadata does not duplicate it.

A newly created automatic session stores its scheduled origin and an unseen
automatic-session flag. Existing sessions keep the IDs of unseen scheduled
turns. Recent-session summaries derive an unseen automatic-session boolean and
unseen scheduled-turn count from that state.

```ts
interface ScheduledSessionOrigin {
    readonly kind: "scheduled_task";
    readonly task_id: string;
    readonly occurrence_id: string;
}

interface ScheduledSessionState {
    readonly origin?: ScheduledSessionOrigin;
    readonly automatic_session_unseen?: true;
    readonly unseen_scheduled_turn_ids?: readonly string[];
}
```

New sessions use `origin` plus `automatic_session_unseen`. Existing sessions use
`unseen_scheduled_turn_ids`; the first turn of a new automatic session is not
duplicated in both unseen mechanisms.

Home prepends a small new/start marker to an unseen automatic session and a bell
to an existing session with unseen scheduled turns. Visible presentation or
successfully played speech counts as seen. A silent background tab does not;
an open minimized Voice client counts as seen when speech actually plays.

## 12. Active text and voice interjection

An active typed chat preserves every character of its unsent composer draft.
Send is unavailable while the scheduled turn runs and returns afterward.

Continuous Voice must suspend the existing uncommitted candidate rather than
endpoint, cancel, or split it:

1. the scheduler requests suspension for the selected client/session;
2. the client stops capture on an audio-frame boundary;
3. Voice freezes candidate timers and retains accepted audio, STT draft,
   pending image, and provisional turn identity;
4. only after `listening_suspended` acknowledgement may the scheduler claim and
   dispatch the scheduled turn;
5. the silent trigger tool event is displayed, then the scheduled response is
   spoken through ordinary live-Voice playback;
6. after speech finishes or is stopped, capture resumes into the same candidate
   and its visible draft; and
7. later final STT combines audio captured before and after the interjection as
   one user turn.

If suspension is not acknowledged safely, the poll creates no run and leaves
the candidate untouched. The console follows the same invariant with its FFmpeg
capture and waits for any current assistant speech to finish or be stopped.

The separate one-shot recorded-audio microphone action is removed. The
continuous-listening waveform control remains and enters/leaves listening with
its visible STT draft. Console “stop speaking” detection remains a separate
feature.

## 13. Service ownership

The OS service manager starts and keeps one authoritative `wheatleyd` alive.
On macOS this is a per-user LaunchAgent installed with a stable runtime and
explicit environment, working directory, owner-only state, and logs. There is
one service for the daemon, never one OS job per task.

The scheduler is always active in the authoritative Profile Runtime; there is
no `scheduler.enabled`, fallback-model, waiting-policy, queue, poll-interval, or
retention configuration. The three-day one-time retention and five-second poll
are product constants.

A paired replica may display synchronized task state but must not execute it.
The existing deployment composition determines which Profile Runtime is
authoritative; shared files are not a distributed lock.

After sleep, restart, or downtime, the ordinary due rules apply: one-time work
runs late, fixed/calendar work runs only its newest missed slot,
after-completion work retains its one derived due occurrence, and active-target
work stays overdue until an eligible chat exists.

## 14. Conformance scenarios

1. “Remind me in 45 minutes to leave” creates one active-session task. With no
   open chat it remains overdue; when a chat becomes eligible, one LLM turn runs
   with truthful whole-minute lateness and then completes.
2. “Every workday at 9:30 remind me to join the daily meeting” normalizes to
   weekly `MO TU WE TH FR` and never replays several missed mornings.
3. “Create an ABC summary every morning at 9” creates one fresh marked session
   per occurrence with the user-selected task model and no fallback.
4. “Every 10 to 30 minutes tell me a joke” uses `bash` with `python3` and
   `random.randint` for the first delay and every automatic next delay. The
   range exists only in `task_text`.
5. “Tell me a joke, then pause 20 seconds after each joke before telling the
   next” creates `after_completion`, not `fixed_interval`. With no explicit
   first start, the first scheduled joke is due after 20 seconds. “Tell me one
   now, then pause 20 seconds” explicitly uses `first: now`; the creating turn
   confirms rather than duplicating the joke. A one-minute scheduled joke makes
   the next start roughly 80 seconds later without creating lateness.
6. Plain “tell me a joke every 20 seconds” remains `fixed_interval`; the agent
   selects completion-relative recurrence only from language such as “after it
   finishes,” “after each,” “wait,” or “pause between runs.”
7. An agent-created progress checker resumes its originating session and calls
   `complete_current_scheduled_task` when the parent work is done.
8. No active target, busy lane, occupied model capacity, or failed Voice
   suspension creates a pending occurrence or run record.
9. A selected active chat that closes before claim is never used; the same poll
   re-resolves another eligible chat or records nothing.
10. Several executable due tasks run oldest-due one by one before the next user
   turn. Equal-time tasks use natural arrival order.
11. A fixed/calendar task with three missed slots runs the newest once and
    receives a missed count of two plus the earliest missed time. An
    after-completion task can never produce those fields.
12. Run now on fixed/calendar/agent-managed recurrence creates one extra manual
    trigger and leaves normal cadence unchanged. Run now on after-completion
    consumes its sole next occurrence and anchors the following pause at that
    run's finish. It retains an overdue original due time but uses the request
    time when run early. A second request or an active run is rejected.
13. Editing an after-completion delay recalculates due time from the latest
    trustworthy finish and may make the task immediately overdue. During a run,
    future-facing edits are accepted but schedule-kind and first-anchor changes
    are rejected; the current prompt and execution target remain frozen.
14. Disabling during a run lets that run finish and preserves the disabled task.
    Re-enabling later does not reset its schedule. If unresolved attention
    remains, On restores Needs attention rather than retrying.
15. A failed one-time or agent-managed task requires attention. A failed fixed
    or calendar recurrence advances to its next normal slot. A failed
    after-completion recurrence derives its next time from the failed run's
    finish only when `agent_started_at` exists; a permanent pre-agent failure
    requires attention. Each continuing task supplies the concise failure to
    its next LLM.
16. A leftover active claim becomes ambiguous after restart and is never
    replayed automatically. An after-completion task requires attention because
    the claim supplies no trustworthy finish time.
17. Active/originating model UI shows `Auto`; only new-session model UI is
    editable. Task reasoning is editable for every target and maps to the
    resolved model without changing the composer preference.
18. A task successfully created by `create_scheduled_task` opens that exact
    task's edit dialog immediately for user confirmation. The scheduled-task
    identifier travels only as server-to-client presentation metadata; it is
    not returned to the model as a second tool instruction. The menu has no
    manual creation action.
19. Typed drafts and one continuous Voice candidate survive a scheduled
    interjection without loss, premature endpoint, or transcript rewriting.
20. Completed one-time tasks delete after three days; disabled, failed,
    ambiguous, and completed repeating tasks do not.
21. Every scheduled, manual, and retry occurrence in every target begins with
    one silent `scheduled_task_trigger` tool event. It is inline in both clients,
    inspectable in the browser, and never mistaken for successful task output.
22. Trigger details preserve and display every scheduler-added prompt string
    exactly as submitted. No LLM-facing task tool, result, context, instruction,
    or error exposes the internal profile scope.
23. Pressing ordinary assistant Stop terminates and counts the current
    after-completion occurrence but leaves recurrence active. Off, Delete, or
    `complete_current_scheduled_task` is required to stop future occurrences.

## 15. Current implementation boundary

Wheatley already has the required Conversation FIFO and execution claim,
observer-independent terminal persistence, model capability catalog, trusted Pi
turn context, profile-scoped tool routing, popup-menu primitives, and combined
composer model/reasoning control.

The general Pi template currently says `profile` and exposes a profile name,
and at least the existing `remember` description also uses that term. Removing
profile terminology from Wheatley's complete model-visible contract is a
separate cross-cutting cleanup. Scheduled tasks must neither depend on nor add
to that exposure: their schemas, tools, errors, context, and instructions are
profile-blind from the first implementation slice.

It does not yet have the task store, scheduler, task APIs/tools, active-client
presence owner, task UI, scheduler-authored trigger tool events/source,
scheduled provenance, unseen markers, Voice suspend/resume seam, or a
LaunchAgent for authoritative `wheatleyd`.

The first implementation slice should establish the task schema, tools, pull
scheduler, originating/new-session execution, terminal state, trigger tool
event/details, and bell UI. Active-session presence and typed interjection
follow. Voice suspension remains the final, physically verified slice; the
one-shot microphone path is already removed.
