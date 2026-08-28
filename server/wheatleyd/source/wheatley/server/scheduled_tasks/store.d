module wheatley.server.scheduled_tasks.store;

import std.algorithm : all, canFind, sort;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.exception : enforce;
import std.file : DirEntry, exists;
import std.json : JSONValue, parseJSON;
import std.path : baseName, buildPath;
import std.string : replace, startsWith, strip;
import std.uuid : randomUUID;

import wheatley.common.api.reasoning : ReasoningMode, parseReasoningMode, reasoningModeText;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.scheduled_tasks.lifecycle :
    completeTask,
    finishTask,
    reconcileAbandonedTask,
    requestTaskRunNow,
    setTaskEnabled;
import wheatley.server.scheduled_tasks.repository : ScheduledTaskRepository;
import wheatley.server.scheduled_tasks.schedule :
    addSeconds,
    calendarSlotAfter,
    calendarSlotCountThrough,
    dueAt,
    resolveTime,
    scheduleInitialAt,
    timestampAtOrBefore,
    validateSchedule,
    validateStoredSchedule;

enum scheduledTaskCreationPrefix = "This is a scheduled task run:\n\n";
alias ScheduledTaskDefinitionValidator = void delegate(JSONValue task);

/** Durable profile-local scheduled-task definitions.  Scheduling policy lives
    above this store; this owner only validates and atomically publishes task
    records. */
final class ScheduledTaskStore
{
    private ScheduledTaskRepository repository;

    this(string profilesRoot)
    {
        enforce(profilesRoot.length, "Profiles root is required");
        this.repository = new ScheduledTaskRepository(profilesRoot);
    }

    string listJson(string profileId)
    {
        string[] tasks;
        auto now = nowIso();
        foreach (entry; taskEntries(profileId)) {
            auto task = readTask(profileId, baseName(entry.name));
            tasks ~= taskSummaryJson(
                baseName(entry.name),
                task,
                now,
                exists(buildPath(entry.name, "active-run.json")),
            );
        }
        sort(tasks);
        return jsonObject([jsonRawField("tasks", "[" ~ tasks.join(",") ~ "]")]);
    }

    string getJson(string profileId, string id)
    {
        return publishedTask(profileId, id, readTask(profileId, id));
    }

    string create(
        string profileId,
        string sessionId,
        string turnId,
        string model,
        string reasoningMode,
        JSONValue payload,
        ScheduledTaskDefinitionValidator validate = null,
    )
    {
        auto input = Json.object(payload, "body");
        enforceExactFields(input.value, [
            "display_text", "task_text", "target", "schedule", "reasoning_mode",
        ]);
        auto displayText = requiredTrimmed(input, "display_text", 120);
        auto taskText = scheduledTaskCreationPrefix
            ~ requiredTrimmed(input, "task_text", 8_000 - scheduledTaskCreationPrefix.length);
        auto target = input.choice!("active_user_session", "originating_session", "new_session")(
            "target",
        );
        auto schedule = validateSchedule(input.object("schedule").value, nowIso());
        auto mode = input.opt.textOrEmpty("reasoning_mode");
        if (!mode.length) mode = reasoningMode;
        requireReasoningMode(mode, "body.reasoning_mode");

        auto id = "schedule_" ~ randomUUID().toString().replace("-", "");
        auto targetJson = target == "originating_session"
            ? jsonObject([
                jsonStringField("kind", target),
                jsonStringField("session_id", sessionId),
            ])
            : target == "new_session"
                ? jsonObject([
                    jsonStringField("kind", target),
                    jsonStringField("model", model),
                ])
                : jsonObject([jsonStringField("kind", target)]);
        auto task = jsonObject([
            jsonStringField("state", "enabled"),
            jsonStringField("display_text", displayText),
            jsonStringField("task_text", taskText),
            jsonRawField("target", targetJson),
            jsonRawField("schedule", schedule.toString()),
            jsonStringField("reasoning_mode", mode),
            jsonRawField("created", jsonObject([
                jsonStringField("at", nowIso()),
                jsonStringField("session_id", sessionId),
                jsonStringField("turn_id", turnId),
                jsonStringField("model", model),
                jsonStringField("reasoning_mode", reasoningMode),
            ])),
        ]);
        if (validate !is null) validate(parseJSON(task));
        repository.save(profileId, id, parseJSON(task));
        return publishedTask(profileId, id, parseJSON(task));
    }

    string setEnabled(string profileId, string id, bool enabled)
    {
        auto task = readTask(profileId, id);
        setTaskEnabled(task, enabled);
        save(profileId, id, task);
        return publishedTask(profileId, id, task);
    }

    /** Shared normal-tool/direct-dialog mutation.  The caller supplies trusted
        current-turn identity and model; neither can be provided by Pi. */
    string update(
        string profileId,
        string id,
        string sessionId,
        string turnId,
        string model,
        JSONValue payload,
        bool allowModel = false,
        ScheduledTaskDefinitionValidator validate = null,
    )
    {
        auto input = Json.object(payload, "body");
        enforceExactFields(input.value, [
            "display_text", "task_text", "target", "schedule", "reasoning_mode", "model",
        ]);
        enforce(input.value.objectNoRef.length, "At least one task field is required");
        auto task = readTask(profileId, id);
        auto active = repository.claimExists(profileId, id);
        if ("display_text" in input.value.objectNoRef)
            task.object["display_text"] = JSONValue(requiredTrimmed(input, "display_text", 120));
        if ("task_text" in input.value.objectNoRef)
            task.object["task_text"] = JSONValue(requiredTrimmed(input, "task_text", 8_000));
        if ("reasoning_mode" in input.value.objectNoRef) {
            auto value = input.enumeration!ReasoningMode("reasoning_mode").reasoningModeText;
            task.object["reasoning_mode"] = JSONValue(value);
        }
        string targetKind = Json.object(task).object("target").text("kind");
        if ("target" in input.value.objectNoRef) {
            targetKind = input.choice!("active_user_session", "originating_session", "new_session")("target");
            enforce(targetKind != "originating_session" || sessionId.length,
                "A current session is required when targeting its originating session");
            task.object["target"] = parseJSON(targetKind == "originating_session"
                ? jsonObject([jsonStringField("kind", targetKind), jsonStringField("session_id", sessionId)])
                : targetKind == "new_session"
                    ? jsonObject([jsonStringField("kind", targetKind), jsonStringField("model", model)])
                    : jsonObject([jsonStringField("kind", targetKind)]));
        }
        if ("model" in input.value.objectNoRef) {
            enforce(allowModel && targetKind == "new_session", "Task model is only editable for new-session tasks");
            auto selected = input.nonEmpty("model");
            task.object["target"].object["model"] = JSONValue(selected);
        }
        if ("schedule" in input.value.objectNoRef) {
            auto old = Json.object(task).object("schedule");
            auto next = validateSchedule(input.object("schedule").value, nowIso());
            auto requested = input.object("schedule");
            if (old.text("kind") == "after_completion"
                && Json.object(next).text("kind") == "after_completion"
                && !("first" in requested.value.objectNoRef))
                next.object["first_at"] = JSONValue(old.text("first_at"));
            if (active) {
                enforce(old.text("kind") == Json.object(next).text("kind"),
                    "Schedule kind cannot change while a task run is active");
                enforce(scheduleInitialAt(old) == scheduleInitialAt(Json.object(next)),
                    "Schedule first occurrence cannot change while a task run is active");
            }
            task.object["schedule"] = next;
            if (old.text("kind") != Json.object(next).text("kind")) {
                task.object.remove("handled_occurrences");
                task.object.remove("last_handled_scheduled_for");
            }
        }
        if (validate !is null) validate(task);
        save(profileId, id, task);
        return publishedTask(profileId, id, task);
    }

    string deleteTask(string profileId, string id)
    {
        validateId(id);
        repository.deleteTask(profileId, id);
        return jsonObject([jsonBoolField("deleted", true)]);
    }

    string runNow(string profileId, string id)
    {
        auto task = readTask(profileId, id);
        requestTaskRunNow(task, nowIso());
        save(profileId, id, task);
        return publishedTask(profileId, id, task);
    }

    ScheduledTaskFile[] due(string profileId, string now)
    {
        ScheduledTaskFile[] result;
        foreach (entry; taskEntries(profileId)) {
            auto id = baseName(entry.name);
            auto task = readTask(profileId, id);
            auto state = Json.object(task).text("state");
            auto manualPending = "manual_trigger_at" in task.object;
            if (state != "enabled" && state != "needs_attention"
                && !(state == "disabled" && manualPending)) continue;
            if (repository.claimExists(profileId, id)) continue;
            if (state == "needs_attention" && !manualPending) continue;
            auto at = dueAt(task, now);
            auto handled = Json.object(task).opt.textOrEmpty("last_handled_scheduled_for");
            if (!("manual_trigger_at" in task.object) && handled == at) continue;
            if (at.length && timestampAtOrBefore(at, now)) {
                ScheduledTaskFile file = ScheduledTaskFile(profileId, id, task, at);
                if ("manual_trigger_at" in task.object) file.manual = true;
                auto schedule = Json.object(task).object("schedule");
                if (!file.manual && schedule.text("kind") == "fixed_interval") {
                    auto prior = handled.length ? handled : schedule.text("anchor_at");
                    auto interval = schedule.positiveInt("every_seconds");
                    auto slots = (SysTime.fromISOExtString(at) - SysTime.fromISOExtString(prior)).total!"seconds" / interval;
                    auto missed = handled.length ? slots - 1 : slots;
                    if (missed > 0) {
                        file.missedOccurrences = cast(long) missed;
                        file.missedSince = handled.length ? addSeconds(prior, interval) : prior;
                    }
                }
                if (!file.manual && schedule.text("kind").startsWith("calendar_")) {
                    auto slots = calendarSlotCountThrough(schedule, at);
                    if (handled.length) slots -= calendarSlotCountThrough(schedule, handled);
                    if (slots > 1) {
                        file.missedOccurrences = slots - 1;
                        file.missedSince = calendarSlotAfter(schedule, handled.length
                            ? handled : "");
                    }
                }
                result ~= file;
            }
        }
        sort!((a, b) => a.dueAt < b.dueAt)(result);
        return result;
    }

    string claim(ScheduledTaskFile task, string claimedAt, string submissionId)
    {
        auto occurrenceId = randomUUID().toString();
        auto definition = Json.object(task.task);
        auto claim = parseJSON(jsonObject([
            jsonStringField("occurrence_id", occurrenceId),
            jsonStringField("trigger", triggerFor(task)),
            jsonStringField("claimed_at", claimedAt),
            jsonStringField("scheduled_for", task.dueAt),
            jsonStringField("submission_id", submissionId),
            jsonStringField("display_text", definition.text("display_text")),
            jsonStringField("task_text", definition.text("task_text")),
            jsonRawField("target", definition.object("target").value.toString()),
            jsonRawField("schedule", definition.object("schedule").value.toString()),
            jsonStringField("configured_reasoning_mode", definition.text("reasoning_mode")),
            task.manual ? jsonBoolField("manual", true) : "",
        ]));
        if (!repository.createClaim(task.profileId, task.id, claim)) return "";
        return occurrenceId;
    }

    string scheduleNextForSubmission(string profileId, string submissionId, JSONValue when)
    {
        auto match = claimedTask(profileId, submissionId);
        auto claim = claimedRun(profileId, match.id);
        auto task = readTask(profileId, match.id);
        auto schedule = Json.object(task).object("schedule");
        enforce(schedule.text("kind") == "agent_managed_next", "Current task does not manage its next occurrence");
        enforce(claim.text("trigger") != "manual",
            "A manual extra occurrence cannot change the next scheduled time");
        auto at = resolveTime(Json.object(when, "when"), nowIso());
        enforce(!timestampAtOrBefore(at, nowIso()), "Next occurrence must be in the future");
        task.object["schedule"].object["next_at"] = JSONValue(at);
        save(profileId, match.id, task);
        return jsonObject([jsonStringField("next_run_at", at)]);
    }

    string completeForSubmission(string profileId, string submissionId, string reason)
    {
        auto match = claimedTask(profileId, submissionId);
        auto task = readTask(profileId, match.id);
        completeTask(task, nowIso(), reason);
        save(profileId, match.id, task);
        return jsonObject([jsonStringField("state", "completed")]);
    }

    void finish(
        ScheduledTaskFile file,
        string status,
        string finishedAt,
        string sessionId,
        string turnId,
        string configuredReasoningMode = "",
        string effectiveReasoningMode = "",
        string errorMessage = "",
    )
    {
        auto task = readTask(file.profileId, file.id);
        auto claim = claimedRun(file.profileId, file.id);
        finishTask(
            task,
            claim,
            file.dueAt,
            file.missedOccurrences,
            status,
            finishedAt,
            sessionId,
            turnId,
            configuredReasoningMode,
            effectiveReasoningMode,
            errorMessage,
        );
        save(file.profileId, file.id, task);
        repository.deleteClaim(file.profileId, file.id);
    }

    string[] profileIds()
    {
        return repository.profileIds();
    }

    void purgeExpired(string profileId, string at)
    {
        foreach (entry; taskEntries(profileId)) {
            auto id = baseName(entry.name);
            auto task = readTask(profileId, id);
            auto value = Json.object(task);
            if (value.text("state") != "completed" || value.object("schedule").text("kind") != "once") continue;
            auto deleteAt = value.opt.textOrEmpty("delete_at");
            if (deleteAt.length && timestampAtOrBefore(deleteAt, at)) deleteTask(profileId, id);
        }
    }

    void reconcileAbandonedClaims(string profileId, string at)
    {
        foreach (entry; taskEntries(profileId)) {
            auto id = baseName(entry.name);
            if (!repository.claimExists(profileId, id)) continue;
            auto task = readTask(profileId, id);
            auto claim = Json.object(repository.readClaim(profileId, id));
            reconcileAbandonedTask(task, claim, at);
            save(profileId, id, task);
            repository.deleteClaim(profileId, id);
        }
    }

    private DirEntry[] taskEntries(string profileId)
    {
        return repository.entries(profileId);
    }

    private ScheduledTaskFile claimedTask(string profileId, string submissionId)
    {
        foreach (entry; taskEntries(profileId)) {
            auto id = baseName(entry.name);
            if (!repository.claimExists(profileId, id)) continue;
            auto claim = Json.object(repository.readClaim(profileId, id));
            if (claim.text("submission_id") == submissionId)
                return ScheduledTaskFile(profileId, id, JSONValue.init, "");
        }
        throw new Exception("No active scheduled task run");
    }

    private Json claimedRun(string profileId, string id)
    {
        return Json.object(repository.readClaim(profileId, id));
    }

    private JSONValue readTask(string profileId, string id)
    {
        validateId(id);
        auto task = repository.read(profileId, id);
        validateStoredTask(task);
        return task;
    }

    private void save(string profileId, string id, JSONValue task)
    {
        validateStoredTask(task);
        repository.save(profileId, id, task);
    }

    private string publishedTask(string profileId, string id, JSONValue task)
    {
        return taskJson(
            id,
            task,
            repository.claimExists(profileId, id),
        );
    }

}

struct ScheduledTaskFile
{
    string profileId;
    string id;
    JSONValue task;
    string dueAt;
    bool manual;
    long missedOccurrences;
    string missedSince;
}

private string triggerFor(ScheduledTaskFile file)
{
    if (!file.manual) return "scheduled";
    return Json.object(file.task).text("state") == "needs_attention" ? "retry" : "manual";
}

private string taskJson(string id, JSONValue task, bool activeRun)
{
    auto payload = parseJSON(taskSummaryJson(id, task, nowIso(), activeRun));
    payload.object["task"] = task;
    return payload.toString();
}

private string taskSummaryJson(string id, JSONValue task, string now, bool activeRun)
{
    auto value = Json.object(task);
    auto due = dueAt(task, now);
    auto state = value.text("state");
    long late;
    if (state == "enabled" && due.length && timestampAtOrBefore(due, now))
        late = cast(long) ((SysTime.fromISOExtString(now) - SysTime.fromISOExtString(due)).total!"minutes");
    auto last = value.opt.object("last_run");
    return jsonObject([
        jsonStringField("id", id),
        jsonStringField("state", state),
        jsonStringField("quick_status", quickStatus(value, activeRun)),
        jsonStringField("display_text", value.text("display_text")),
        jsonStringField("target", value.object("target").text("kind")),
        jsonStringField("schedule_text", scheduleText(value.object("schedule"))),
        due.length && (state == "enabled" || state == "needs_attention") ? jsonStringField("next_run_at", due) : "",
        late > 0 ? jsonLongField("late_by_minutes", late) : "",
        jsonBoolField("has_run", !last.isNull),
        last.isNull ? "" : jsonStringField("last_run_status", last.get.text("status")),
    ]);
}

/** Compact lifecycle signal for list consumers. `state` and `last_run_status`
    remain available when a caller needs the underlying precise detail. */
private string quickStatus(Json task, bool activeRun)
{
    auto last = task.opt.object("last_run");
    if (activeRun) {
        if (!last.isNull && last.get.text("status") != "completed")
            return "running_but_last_run_failed";
        return "running";
    }
    auto state = task.text("state");
    if (state == "needs_attention") return "needs_attention";
    if (state == "disabled")
        return "attention_pending" in task.value.objectNoRef
            ? "disabled_but_needs_attention"
            : "disabled";
    if (state == "completed") return "completed";
    if ("manual_trigger_at" in task.value.objectNoRef) return "queued";
    return "ok";
}

unittest
{
    assert(quickStatus(Json.object(parseJSON(`{"state":"enabled"}`)), false) == "ok");
    assert(quickStatus(Json.object(parseJSON(`{"state":"enabled","manual_trigger_at":"2026-08-17T12:00:00Z"}`)), false) == "queued");
    assert(quickStatus(Json.object(parseJSON(`{"state":"enabled"}`)), true) == "running");
    assert(quickStatus(Json.object(parseJSON(`{"state":"enabled","last_run":{"status":"ambiguous"}}`)), true) == "running_but_last_run_failed");
    assert(quickStatus(Json.object(parseJSON(`{"state":"needs_attention"}`)), false) == "needs_attention");
    assert(quickStatus(Json.object(parseJSON(`{"state":"disabled","attention_pending":true}`)), false) == "disabled_but_needs_attention");
    assert(quickStatus(Json.object(parseJSON(`{"state":"completed"}`)), false) == "completed");
}

private string scheduleText(Json schedule)
{
    auto kind = schedule.text("kind");
    if (kind == "once") return "Once";
    if (kind == "fixed_interval") return "Every " ~ schedule.integer("every_seconds").to!string ~ " seconds (clock-anchored)";
    if (kind == "after_completion") return schedule.integer("delay_seconds").to!string ~ " seconds after completion";
    if (kind == "agent_managed_next") return "Agent-managed next occurrence";
    return schedule.text("time") ~ " " ~ kind[9 .. $];
}

private string requiredTrimmed(Json input, string field, size_t maximum)
{
    auto text = input.text(field).strip;
    enforce(text.length, "body." ~ field ~ " is empty");
    enforce(text.length <= maximum, "body." ~ field ~ " is too long");
    return text;
}

private void validateStoredTask(JSONValue task)
{
    auto value = Json.object(task, "task");
    value.choice!("enabled", "disabled", "completed", "needs_attention")("state");
    requiredTrimmed(value, "display_text", 120);
    requiredTrimmed(value, "task_text", 8_000);
    auto target = value.object("target");
    auto kind = target.choice!("active_user_session", "originating_session", "new_session")("kind");
    if (kind == "originating_session") target.nonEmpty("session_id");
    if (kind == "new_session") target.nonEmpty("model");
    validateStoredSchedule(value.object("schedule").value);
    requireReasoningMode(value.text("reasoning_mode"), "task.reasoning_mode");
}

private void requireReasoningMode(string value, string name)
{
    try parseReasoningMode(value);
    catch (Exception) throw new Exception("Invalid reasoning mode: " ~ name);
}

private void validateId(string id)
{
    enforce(id.length > 9 && id.startsWith("schedule_")
        && id[9 .. $].all!(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')),
        "Task not found");
}

private void enforceExactFields(JSONValue value, string[] allowed)
{
    foreach (field; value.objectNoRef.keys) {
        bool found;
        foreach (name; allowed) if (field == name) found = true;
        enforce(found, "Unknown JSON field: " ~ field);
    }
}

private string join(string[] values, string separator)
{
    import std.array : join;
    return values.join(separator);
}

unittest
{
    import std.file : rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-scheduled-tasks-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto tasks = new ScheduledTaskStore(root);
    auto created = parseJSON(tasks.create(
        "tester",
        "2026/08/17/12_00_00",
        "turn-1",
        "lmstudio/test",
        "off",
        parseJSON(`{
            "display_text":"Leave now",
            "task_text":"Tell the user to leave now.",
            "target":"new_session",
            "schedule":{"kind":"once","when":{"kind":"after","seconds":60}}
        }`),
    ));
    auto id = created["id"].str;
    assert(Json.object(created).object("task").text("task_text")
        == scheduledTaskCreationPrefix ~ "Tell the user to leave now.");
    assert(tasks.listJson("tester").canFind(id));
    auto createdDetail = tasks.getJson("tester", id);
    assert(createdDetail.canFind("Leave now"));
    assert(createdDetail.canFind("Tell the user to leave now."));
    assert(createdDetail.canFind(`"schedule_text"`));
    assert(createdDetail.canFind(`"task"`));
    auto literalEdit = parseJSON(tasks.update(
        "tester", id, "2026/08/17/12_00_00", "turn-2", "lmstudio/test",
        parseJSON(`{"task_text":"Use this exact edited instruction."}`),
    ));
    assert(Json.object(literalEdit).object("task").text("task_text")
        == "Use this exact edited instruction.");
    auto modelEdit = parseJSON(tasks.update(
        "tester", id, "2026/08/17/12_00_00", "turn-3", "lmstudio/test",
        parseJSON(`{"model":"lmstudio/replacement"}`), true,
    ));
    assert(Json.object(modelEdit).object("task").object("target").text("model")
        == "lmstudio/replacement");
    assert(tasks.runNow("tester", id).canFind("\"at\""));
    assert(tasks.setEnabled("tester", id, false).canFind("disabled"));
    assert(tasks.deleteTask("tester", id).canFind("deleted"));

    auto calendar = parseJSON(tasks.create(
        "tester", "2026/08/17/12_00_00", "turn-1", "lmstudio/test", "off",
        parseJSON(`{
          "display_text":"Weekday check", "task_text":"Perform the weekday check.",
          "target":"new_session",
          "schedule":{"kind":"calendar_weekly","start_date":"2026-08-17","time":"09:30","interval":1,"weekdays":["MO","TU","WE","TH","FR"]}
        }`),
    ));
    assert(tasks.due("tester", "2026-08-16T12:00:00Z").length == 0);
    assert(tasks.due("tester", "2026-08-17T12:00:00Z").length == 1);

    auto managed = parseJSON(tasks.create(
        "tester", "2026/08/17/12_00_00", "turn-1", "lmstudio/test", "off",
        parseJSON(`{
          "display_text":"Managed", "task_text":"Choose the next time.", "target":"new_session",
          "schedule":{"kind":"agent_managed_next","first":{"kind":"now"}}
        }`),
    ));
    auto managedId = managed["id"].str;
    ScheduledTaskFile candidate;
    foreach (item; tasks.due("tester", nowIso())) if (item.id == managedId) candidate = item;
    assert(candidate.id == managedId);
    assert(tasks.claim(candidate, nowIso(), "submission-lifecycle").length);
    assert(tasks.scheduleNextForSubmission("tester", "submission-lifecycle", parseJSON(`{"kind":"after","seconds":60}`)).canFind("next_run_at"));
    assert(tasks.completeForSubmission("tester", "submission-lifecycle", "finished").canFind("completed"));

    auto fixed = parseJSON(tasks.create(
        "tester", "2026/08/17/12_00_00", "turn-1", "lmstudio/test", "off",
        parseJSON(`{
          "display_text":"Bounded fixed", "task_text":"Perform the bounded check.",
          "target":"new_session",
          "schedule":{"kind":"fixed_interval","first":{"kind":"at","at":"2026-08-17T12:00:00Z"},"every_seconds":60,"end":{"kind":"count","occurrences":2}}
        }`),
    ));
    auto fixedId = fixed["id"].str;
    ScheduledTaskFile fixedDue;
    foreach (item; tasks.due("tester", "2026-08-17T12:10:00Z")) if (item.id == fixedId) fixedDue = item;
    assert(fixedDue.dueAt == "2026-08-17T12:01:00Z");
    assert(fixedDue.missedOccurrences == 1);
    assert(tasks.claim(fixedDue, "2026-08-17T12:10:00Z", "fixed-count").length);
    tasks.finish(fixedDue, "completed", "2026-08-17T12:10:01Z", "session", "turn");
    assert(tasks.getJson("tester", fixedId).canFind(`"state":"completed"`));
    assert(tasks.listJson("tester").canFind(`"has_run":true`));

    auto disabledTemplate = parseJSON(tasks.create(
        "tester", "2026/08/17/12_00_00", "turn-1", "lmstudio/test", "xhigh",
        parseJSON(`{
          "display_text":"Manual template", "task_text":"Run the template.",
          "target":"new_session",
          "schedule":{"kind":"fixed_interval","first":{"kind":"at","at":"2026-08-19T12:00:00Z"},"every_seconds":3600}
        }`),
    ));
    auto disabledId = disabledTemplate["id"].str;
    tasks.setEnabled("tester", disabledId, false);
    tasks.runNow("tester", disabledId);
    ScheduledTaskFile disabledDue;
    foreach (item; tasks.due("tester", nowIso())) if (item.id == disabledId) disabledDue = item;
    assert(disabledDue.id == disabledId && disabledDue.manual);
    assert(tasks.claim(disabledDue, nowIso(), "disabled-manual").length);
    tasks.finish(
        disabledDue, "completed", nowIso(), "session", "turn",
        "xhigh", "xhigh",
    );
    auto disabledAfter = Json.object(parseJSON(tasks.getJson("tester", disabledId))).object("task");
    assert(disabledAfter.text("state") == "disabled");
    assert(disabledAfter.object("schedule").text("anchor_at") == "2026-08-19T12:00:00Z");
    assert(disabledAfter.object("last_run").text("configured_reasoning_mode") == "xhigh");

    auto completion = parseJSON(tasks.create(
        "tester", "2026/08/17/12_00_00", "turn-1", "lmstudio/test", "off",
        parseJSON(`{
          "display_text":"Bounded completion", "task_text":"Perform the completion check.",
          "target":"new_session",
          "schedule":{"kind":"after_completion","delay_seconds":60,"end":{"kind":"count","occurrences":2}}
        }`),
    ));
    assert(tasks.getJson("tester", completion["id"].str).canFind(`"occurrences":2`));

    auto calendarCount = parseJSON(tasks.create(
        "tester", "2026/08/17/12_00_00", "turn-1", "lmstudio/test", "off",
        parseJSON(`{
          "display_text":"Bounded calendar", "task_text":"Perform the calendar check.",
          "target":"new_session",
          "schedule":{"kind":"calendar_daily","start_date":"2026-08-17","time":"09:30","interval":1,"end":{"kind":"count","occurrences":2}}
        }`),
    ));
    auto calendarCountId = calendarCount["id"].str;
    ScheduledTaskFile calendarDue;
    foreach (item; tasks.due("tester", "2026-08-20T12:00:00Z")) if (item.id == calendarCountId) calendarDue = item;
    assert(calendarDue.dueAt == "2026-08-18T09:30:00Z");
    assert(calendarDue.missedOccurrences == 1);
}
