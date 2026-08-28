module wheatley.server.scheduled_tasks.lifecycle;

import std.exception : enforce;
import std.json : JSONValue, parseJSON;
import std.string : startsWith;

import wheatley.common.json.object :
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.scheduled_tasks.schedule :
    addSeconds,
    reachedCountEnd,
    timestampAtOrBefore;

void setTaskEnabled(ref JSONValue task, bool enabled)
{
    auto state = Json.object(task).text("state");
    if (enabled) {
        enforce(state == "disabled", "Task cannot be enabled from " ~ state);
        auto unresolved = "attention_pending" in task.object;
        task.object["state"] = JSONValue(unresolved ? "needs_attention" : "enabled");
        task.object.remove("attention_pending");
    } else {
        enforce(state == "enabled" || state == "needs_attention",
            "Task cannot be disabled from " ~ state);
        if (state == "needs_attention") task.object["attention_pending"] = JSONValue(true);
        task.object["state"] = JSONValue("disabled");
    }
}

void requestTaskRunNow(ref JSONValue task, string requestedAt)
{
    auto state = Json.object(task).text("state");
    enforce(state == "enabled" || state == "needs_attention" || state == "disabled",
        "Task must be enabled, disabled, or need attention to run now");
    enforce(!("manual_trigger_at" in task.object), "Task already has a Run now request");
    auto schedule = Json.object(task).object("schedule");
    if (schedule.text("kind") == "once" && state == "enabled")
        task.object["schedule"].object["at"] = JSONValue(requestedAt);
    else
        task.object["manual_trigger_at"] = JSONValue(requestedAt);
}

void completeTask(ref JSONValue task, string completedAt, string reason)
{
    task.object["state"] = JSONValue("completed");
    task.object["completed_at"] = JSONValue(completedAt);
    if (reason.length) task.object["completion_reason"] = JSONValue(reason);
}

void finishTask(
    ref JSONValue task,
    Json claim,
    string dueAt,
    long missedOccurrences,
    string status,
    string finishedAt,
    string sessionId,
    string turnId,
    string configuredReasoningMode,
    string effectiveReasoningMode,
    string errorMessage,
)
{
    auto wasManual = "manual_trigger_at" in task.object;
    auto priorState = Json.object(task).text("state");
    if (!configuredReasoningMode.length)
        configuredReasoningMode = Json.object(task).text("reasoning_mode");
    task.object.remove("manual_trigger_at");
    task.object["last_run"] = parseJSON(jsonObject([
        jsonStringField("occurrence_id", claim.text("occurrence_id")),
        jsonStringField("trigger", claim.text("trigger")),
        jsonStringField("status", status),
        jsonStringField("scheduled_for", dueAt),
        jsonStringField("claimed_at", claim.text("claimed_at")),
        jsonStringField("agent_started_at", claim.text("claimed_at")),
        jsonStringField("finished_at", finishedAt),
        jsonStringField("session_id", sessionId),
        jsonStringField("turn_id", turnId),
        jsonStringField("configured_reasoning_mode", configuredReasoningMode),
        effectiveReasoningMode.length
            ? jsonStringField("effective_reasoning_mode", effectiveReasoningMode)
            : "",
        errorMessage.length ? jsonStringField("error_message", errorMessage) : "",
    ]));
    auto schedule = Json.object(task).object("schedule");
    auto kind = schedule.text("kind");
    auto advances = !wasManual;
    if (advances && (kind == "fixed_interval" || kind == "after_completion"
        || kind.startsWith("calendar_"))) {
        auto handled = Json.object(task).opt.integer("handled_occurrences");
        auto advanced = 1 + missedOccurrences;
        auto count = handled.isNull ? advanced : handled.get + advanced;
        task.object["handled_occurrences"] = JSONValue(count);
        if (reachedCountEnd(schedule, count))
            task.object["state"] = JSONValue("completed");
    }
    if (!wasManual && kind != "after_completion" && kind != "agent_managed_next")
        task.object["last_handled_scheduled_for"] = JSONValue(dueAt);

    auto failed = status != "completed";
    string failureKind = "run_failed";
    string failureMessage = errorMessage.length
        ? errorMessage : "Scheduled task run failed.";
    if (!failed && kind == "agent_managed_next" && claim.text("trigger") != "manual") {
        auto next = schedule.text("next_at");
        if (timestampAtOrBefore(next, finishedAt)) {
            failed = true;
            failureKind = "missing_next_occurrence";
            failureMessage = "Agent-managed task ended without a next occurrence or completion.";
        }
    }

    if (failed) {
        if (priorState == "disabled") {
            task.object["state"] = JSONValue("disabled");
            task.object["attention_pending"] = JSONValue(true);
        } else if (priorState != "completed") {
            task.object["state"] = JSONValue("needs_attention");
        }
        task.object["last_failure"] = parseJSON(jsonObject([
            jsonStringField("occurrence_id", claim.text("occurrence_id")),
            jsonStringField("at", finishedAt),
            jsonStringField("kind", failureKind),
            jsonStringField("message", failureMessage),
        ]));
    } else if (priorState != "disabled") {
        task.object.remove("last_failure");
        task.object.remove("attention_pending");
        if (kind == "once") {
            task.object["state"] = JSONValue("completed");
            task.object["delete_at"] = JSONValue(addSeconds(
                finishedAt,
                3 * 24 * 60 * 60,
            ));
        } else if (claim.text("trigger") == "retry") {
            task.object["state"] = JSONValue("enabled");
        }
    }
}

void reconcileAbandonedTask(ref JSONValue task, Json claim, string at)
{
    task.object["last_run"] = parseJSON(jsonObject([
        jsonStringField("occurrence_id", claim.text("occurrence_id")),
        jsonStringField("trigger", "scheduled"),
        jsonStringField("status", "ambiguous"),
        jsonStringField("scheduled_for", claim.text("scheduled_for")),
        jsonStringField("claimed_at", claim.text("claimed_at")),
        jsonStringField("finished_at", at),
        jsonStringField(
            "configured_reasoning_mode",
            Json.object(task).text("reasoning_mode"),
        ),
    ]));
    auto kind = Json.object(task).object("schedule").text("kind");
    if (kind == "once" || kind == "after_completion" || kind == "agent_managed_next")
        task.object["state"] = JSONValue("needs_attention");
}
