module wheatley.server.scheduled_tasks.schedule;

import std.conv : to;
import std.datetime : Date, DayOfWeek, days;
import std.datetime.systime : SysTime;
import std.exception : enforce;
import std.json : JSONValue, parseJSON;
import std.string : startsWith;

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

JSONValue validateSchedule(JSONValue value, string acceptedAt)
{
    auto schedule = Json.object(value, "body.schedule");
    auto kind = schedule.choice!(
        "once", "fixed_interval", "after_completion", "calendar_daily",
        "calendar_weekly", "calendar_monthly", "calendar_yearly", "agent_managed_next",
    )("kind");
    final switch (kind) {
        case "once":
            enforceExactFields(schedule.value, ["kind", "when"]);
            return parseJSON(jsonObject([
                jsonStringField("kind", kind),
                jsonStringField("at", resolveTime(schedule.object("when"), acceptedAt)),
            ]));
        case "fixed_interval":
            enforceExactFields(schedule.value, ["kind", "first", "every_seconds", "end"]);
            return recurrenceSchedule(schedule, "first", "anchor_at", "every_seconds", acceptedAt);
        case "after_completion":
            enforceExactFields(schedule.value, ["kind", "first", "delay_seconds", "end"]);
            auto delay = schedule.positiveInt("delay_seconds", 31_536_000);
            auto first = schedule.opt.object("first");
            return parseJSON(jsonObject([
                jsonStringField("kind", kind),
                jsonStringField("first_at", first.isNull
                    ? addSeconds(acceptedAt, delay)
                    : resolveTime(first.get, acceptedAt)),
                jsonLongField("delay_seconds", delay),
                recurrenceEndJson(schedule),
            ]));
        case "agent_managed_next":
            enforceExactFields(schedule.value, ["kind", "first"]);
            return parseJSON(jsonObject([
                jsonStringField("kind", kind),
                jsonStringField("next_at", resolveTime(schedule.object("first"), acceptedAt)),
            ]));
        case "calendar_daily":
        case "calendar_weekly":
        case "calendar_monthly":
        case "calendar_yearly":
            return validateCalendar(schedule, kind);
    }
    assert(0);
}

string scheduleInitialAt(Json schedule)
{
    auto kind = schedule.text("kind");
    if (kind == "once") return schedule.text("at");
    if (kind == "fixed_interval") return schedule.text("anchor_at");
    if (kind == "after_completion") return schedule.text("first_at");
    if (kind == "agent_managed_next") return schedule.text("next_at");
    return schedule.text("start_date") ~ "T" ~ schedule.text("time");
}

private JSONValue recurrenceSchedule(
    Json schedule,
    string firstName,
    string storedFirstName,
    string durationName,
    string acceptedAt,
)
{
    auto duration = schedule.positiveInt(durationName, 31_536_000);
    // `end` is optional, but unknown-field rejection still happens above.
    auto output = jsonObject([
        jsonStringField("kind", schedule.text("kind")),
        jsonStringField(storedFirstName, resolveTime(schedule.object(firstName), acceptedAt)),
        jsonLongField(durationName, duration),
        recurrenceEndJson(schedule),
    ]);
    return parseJSON(output);
}

private string recurrenceEndJson(Json schedule)
{
    if (!("end" in schedule.value.objectNoRef)) return "";
    auto end = schedule.object("end");
    auto kind = end.choice!("count", "until")("kind");
    if (kind == "count") {
        enforceExactFields(end.value, ["kind", "occurrences"]);
        return jsonRawField("end", jsonObject([
            jsonStringField("kind", kind),
            jsonLongField("occurrences", end.positiveInt("occurrences", 1_000_000)),
        ]));
    }
    enforceExactFields(end.value, ["kind", "at"]);
    auto at = end.text("at");
    validateTimestamp(at, "schedule.end.at");
    return jsonRawField("end", jsonObject([
        jsonStringField("kind", kind),
        jsonStringField("at", at),
    ]));
}

string resolveTime(Json value, string acceptedAt)
{
    auto kind = value.choice!("now", "after", "at")("kind");
    final switch (kind) {
        case "now":
            enforceExactFields(value.value, ["kind"]);
            return acceptedAt;
        case "after":
            enforceExactFields(value.value, ["kind", "seconds"]);
            import std.datetime.systime : SysTime;
            import std.datetime : seconds;
            auto delay = seconds(value.positiveInt("seconds", 31_536_000));
            return (SysTime.fromISOExtString(acceptedAt) + delay).toISOExtString();
        case "at":
            enforceExactFields(value.value, ["kind", "at"]);
            auto at = value.text("at");
            validateTimestamp(at, "schedule time");
            return at;
    }
}

string dueAt(JSONValue task, string now)
{
    if ("manual_trigger_at" in task.object) return task.object["manual_trigger_at"].str;
    auto schedule = Json.object(task).object("schedule");
    auto kind = schedule.text("kind");
    if (kind == "once") return schedule.text("at");
    if (kind == "agent_managed_next") return schedule.text("next_at");
    if (kind == "after_completion") {
        if (recurrenceCountReached(task, schedule)) return "";
        auto last = Json.object(task).opt.object("last_run");
        auto due = last.isNull
            ? schedule.text("first_at")
            : addSeconds(last.get.text("finished_at"), schedule.positiveInt("delay_seconds"));
        return boundedDue(schedule, due);
    }
    if (kind.startsWith("calendar_")) {
        if (recurrenceCountReached(task, schedule)) return "";
        return calendarDue(schedule, now);
    }
    if (kind == "fixed_interval") {
        if (recurrenceCountReached(task, schedule)) return "";
        auto anchor = schedule.text("anchor_at");
        auto interval = schedule.positiveInt("every_seconds");
        auto elapsed = (SysTime.fromISOExtString(now) - SysTime.fromISOExtString(anchor))
            .total!"seconds";
        auto due = elapsed <= 0
            ? anchor
            : addSeconds(anchor, cast(long) (elapsed / interval) * interval);
        if ("end" in schedule.value.objectNoRef && schedule.object("end").text("kind") == "count") {
            auto finalSlot = addSeconds(anchor,
                (schedule.object("end").integer("occurrences") - 1) * interval);
            if (!timestampAtOrBefore(due, finalSlot)) due = finalSlot;
        }
        return boundedDue(schedule, due);
    }
    return "";
}

private bool recurrenceCountReached(JSONValue task, Json schedule)
{
    if (!("end" in schedule.value.objectNoRef) || schedule.object("end").text("kind") != "count")
        return false;
    auto handled = Json.object(task).opt.integer("handled_occurrences");
    return !handled.isNull && handled.get >= schedule.object("end").integer("occurrences");
}

private string boundedDue(Json schedule, string at)
{
    if (!at.length || !("end" in schedule.value.objectNoRef)) return at;
    auto end = schedule.object("end");
    if (end.text("kind") == "until" && !timestampAtOrBefore(at, end.text("at"))) return "";
    return at;
}

bool reachedCountEnd(Json schedule, long handled)
{
    if (!("end" in schedule.value.objectNoRef)) return false;
    auto end = schedule.object("end");
    return end.text("kind") == "count" && handled >= end.integer("occurrences");
}

bool timestampAtOrBefore(string left, string right)
{
    return SysTime.fromISOExtString(left) <= SysTime.fromISOExtString(right);
}

string addSeconds(string timestamp, long count)
{
    import std.datetime : seconds;
    return (SysTime.fromISOExtString(timestamp) + seconds(count)).toISOExtString();
}

void validateStoredSchedule(JSONValue value)
{
    auto schedule = Json.object(value, "task.schedule");
    auto kind = schedule.choice!(
        "once", "fixed_interval", "after_completion", "agent_managed_next",
        "calendar_daily", "calendar_weekly", "calendar_monthly", "calendar_yearly",
    )("kind");
    final switch (kind) {
        case "once": validateTimestamp(schedule.text("at"), "task.schedule.at"); break;
        case "fixed_interval":
            validateTimestamp(schedule.text("anchor_at"), "task.schedule.anchor_at");
            schedule.positiveInt("every_seconds", 31_536_000);
            validateStoredRecurrenceEnd(schedule);
            break;
        case "after_completion":
            validateTimestamp(schedule.text("first_at"), "task.schedule.first_at");
            schedule.positiveInt("delay_seconds", 31_536_000);
            validateStoredRecurrenceEnd(schedule);
            break;
        case "agent_managed_next":
            validateTimestamp(schedule.text("next_at"), "task.schedule.next_at");
            break;
        case "calendar_daily":
        case "calendar_weekly":
        case "calendar_monthly":
        case "calendar_yearly": validateCalendar(schedule, schedule.text("kind")); break;
    }
}

private JSONValue validateCalendar(Json schedule, string kind)
{
    string[] fields = ["kind", "start_date", "time", "interval", "excluded_dates", "end"];
    if (kind == "calendar_weekly") fields ~= "weekdays";
    if (kind == "calendar_monthly" || kind == "calendar_yearly") fields ~= "on";
    if (kind == "calendar_yearly") fields ~= "months";
    enforceExactFields(schedule.value, fields);
    auto date = schedule.text("start_date");
    validateDate(date, "schedule.start_date");
    validateTime(schedule.text("time"), "schedule.time");
    schedule.positiveInt("interval", 10_000);
    if ("excluded_dates" in schedule.value.objectNoRef)
        foreach (value; schedule.array("excluded_dates").value.array)
            validateDate(value.str, "schedule.excluded_dates");
    if (kind == "calendar_weekly") validateWeekdays(schedule.array("weekdays").value);
    if (kind == "calendar_monthly" || kind == "calendar_yearly")
        validateMonthRule(schedule.object("on"));
    if (kind == "calendar_yearly") validateMonths(schedule.array("months").value);
    if ("end" in schedule.value.objectNoRef) validateCalendarEnd(schedule.object("end"));
    return schedule.value;
}

private void validateStoredRecurrenceEnd(Json schedule)
{
    if (!("end" in schedule.value.objectNoRef)) return;
    auto end = schedule.object("end");
    auto kind = end.choice!("count", "until")("kind");
    if (kind == "count") {
        enforceExactFields(end.value, ["kind", "occurrences"]);
        end.positiveInt("occurrences", 1_000_000);
    } else {
        enforceExactFields(end.value, ["kind", "at"]);
        validateTimestamp(end.text("at"), "task.schedule.end.at");
    }
}

private void validateCalendarEnd(Json end)
{
    auto kind = end.choice!("count", "through")("kind");
    if (kind == "count") {
        enforceExactFields(end.value, ["kind", "occurrences"]);
        end.positiveInt("occurrences", 1_000_000);
    } else {
        enforceExactFields(end.value, ["kind", "date"]);
        validateDate(end.text("date"), "schedule.end.date");
    }
}

private void validateDate(string value, string name)
{
    try Date.fromISOExtString(value);
    catch (Exception) throw new Exception("Invalid date: " ~ name);
}

private void validateTime(string value, string name)
{
    enforce(value.length == 5 && value[2] == ':' && value[0] >= '0' && value[0] <= '2'
        && value[1] >= '0' && value[1] <= '9' && value[3] >= '0' && value[3] <= '5'
        && value[4] >= '0' && value[4] <= '9', "Invalid time: " ~ name);
    enforce(value[0 .. 2].to!int < 24, "Invalid time: " ~ name);
}

private void validateWeekdays(JSONValue values)
{
    enforce(values.array.length, "weekdays is empty");
    string[string] seen;
    foreach (value; values.array) {
        auto day = value.str;
        enforce(day == "MO" || day == "TU" || day == "WE" || day == "TH" || day == "FR"
            || day == "SA" || day == "SU", "Invalid weekday");
        enforce(day !in seen, "Duplicate weekday"); seen[day] = day;
    }
}

private void validateMonths(JSONValue values)
{
    enforce(values.array.length, "months is empty");
    bool[13] seen;
    foreach (value; values.array) {
        auto month = cast(int) value.integer;
        enforce(month >= 1 && month <= 12 && !seen[month], "Invalid or duplicate month");
        seen[month] = true;
    }
}

private void validateMonthRule(Json rule)
{
    auto kind = rule.choice!("month_days", "ordinal_weekday")("kind");
    if (kind == "month_days") {
        enforceExactFields(rule.value, ["kind", "days"]);
        auto values = rule.array("days").value;
        enforce(values.array.length, "month days is empty"); bool[32] seen;
        foreach (value; values.array) {
            auto day = cast(int) value.integer;
            enforce(day >= 1 && day <= 31 && !seen[day],
                "Invalid or duplicate month day");
            seen[day] = true;
        }
    } else {
        enforceExactFields(rule.value, ["kind", "ordinal", "weekday"]);
        auto ordinal = rule.integer("ordinal");
        enforce(ordinal == -1 || (ordinal >= 1 && ordinal <= 5), "Invalid ordinal");
        validateWeekdays(JSONValue([rule.value.objectNoRef["weekday"]]));
    }
}

private string calendarDue(Json schedule, string now)
{
    auto start = Date.fromISOExtString(schedule.text("start_date"));
    auto today = Date.fromISOExtString(now[0 .. 10]);
    auto time = schedule.text("time");
    auto end = schedule.opt.object("end");
    auto countLimit = !end.isNull && end.get.text("kind") == "count"
        ? end.get.integer("occurrences") : long.max;
    auto through = !end.isNull && end.get.text("kind") == "through"
        ? end.get.text("date") : "";
    long logicalSlots;
    string latest;
    for (Date candidate = start; candidate <= today; candidate += days(1)) {
        if (through.length && candidate.toISOExtString > through) break;
        if (!calendarDateMatches(schedule, start, candidate)) continue;
        logicalSlots++;
        if (logicalSlots > countLimit) break;
        auto at = candidate.toISOExtString ~ "T" ~ time ~ ":00Z";
        if (timestampAtOrBefore(at, now)) latest = at;
    }
    return latest;
}

/** Count logical, non-excluded calendar slots through a timestamp.  This is
    deliberately calendar-based rather than run-based, so skipped downtime
    slots advance count ends just like a performed newest slot. */
long calendarSlotCountThrough(Json schedule, string throughAt)
{
    auto start = Date.fromISOExtString(schedule.text("start_date"));
    auto through = Date.fromISOExtString(throughAt[0 .. 10]);
    auto end = schedule.opt.object("end");
    auto limit = !end.isNull && end.get.text("kind") == "count"
        ? end.get.integer("occurrences") : long.max;
    auto endDate = !end.isNull && end.get.text("kind") == "through"
        ? end.get.text("date") : "";
    long result;
    foreach (Date candidate; dateRangeInclusive(start, through)) {
        if (endDate.length && candidate.toISOExtString > endDate) break;
        if (!calendarDateMatches(schedule, start, candidate)) continue;
        result++;
        if (result >= limit) break;
    }
    return result;
}

string calendarSlotAfter(Json schedule, string afterAt)
{
    auto start = Date.fromISOExtString(schedule.text("start_date"));
    auto after = afterAt.length ? Date.fromISOExtString(afterAt[0 .. 10]) : start - days(1);
    auto end = schedule.opt.object("end");
    auto limit = !end.isNull && end.get.text("kind") == "count"
        ? end.get.integer("occurrences") : long.max;
    auto endDate = !end.isNull && end.get.text("kind") == "through"
        ? end.get.text("date") : "";
    long index;
    for (Date candidate = start;
        index < limit && candidate <= after + days(36_600);
        candidate += days(1)) {
        if (endDate.length && candidate.toISOExtString > endDate) break;
        if (!calendarDateMatches(schedule, start, candidate)) continue;
        index++;
        if (candidate > after)
            return candidate.toISOExtString ~ "T" ~ schedule.text("time") ~ ":00Z";
    }
    return "";
}

private Date[] dateRangeInclusive(Date first, Date last)
{
    Date[] values;
    for (auto date = first; date <= last; date += days(1)) values ~= date;
    return values;
}

private bool calendarDateMatches(Json schedule, Date start, Date date)
{
    auto diff = date.dayOfGregorianCal - start.dayOfGregorianCal;
    if (diff < 0) return false;
    auto kind = schedule.text("kind");
    auto interval = schedule.positiveInt("interval", 10_000);
    if (kind == "calendar_daily" && diff % interval != 0) return false;
    if (kind == "calendar_weekly") {
        if ((diff / 7) % interval != 0
            || !weekdayListed(schedule.array("weekdays").value, date.dayOfWeek))
            return false;
    }
    auto months = (date.year - start.year) * 12 + (cast(int) date.month - cast(int) start.month);
    if ((kind == "calendar_monthly" || kind == "calendar_yearly")
        && !monthRuleMatches(schedule.object("on"), date)) return false;
    if (kind == "calendar_monthly" && months % interval != 0) return false;
    if (kind == "calendar_yearly") {
        if ((date.year - start.year) % interval != 0
            || !monthListed(schedule.array("months").value, cast(int) date.month))
            return false;
    }
    if ("excluded_dates" in schedule.value.objectNoRef)
        foreach (value; schedule.array("excluded_dates").value.array)
            if (value.str == date.toISOExtString) return false;
    return true;
}

private bool weekdayListed(JSONValue values, DayOfWeek weekday)
{
    string wanted;
    final switch (weekday) {
        case DayOfWeek.mon: wanted = "MO"; break;
        case DayOfWeek.tue: wanted = "TU"; break;
        case DayOfWeek.wed: wanted = "WE"; break;
        case DayOfWeek.thu: wanted = "TH"; break;
        case DayOfWeek.fri: wanted = "FR"; break;
        case DayOfWeek.sat: wanted = "SA"; break;
        case DayOfWeek.sun: wanted = "SU"; break;
    }
    foreach (value; values.array) if (value.str == wanted) return true;
    return false;
}

private bool monthListed(JSONValue values, int month)
{
    foreach (value; values.array) if (value.integer == month) return true;
    return false;
}

private bool monthRuleMatches(Json rule, Date date)
{
    if (rule.text("kind") == "month_days") {
        foreach (value; rule.array("days").value.array)
            if (value.integer == date.day) return true;
        return false;
    }
    auto ordinal = rule.integer("ordinal");
    if (!weekdayListed(
        JSONValue([rule.value.objectNoRef["weekday"]]),
        date.dayOfWeek,
    )) return false;
    if (ordinal == -1) return (date + days(7)).month != date.month;
    return ((date.day - 1) / 7 + 1) == ordinal;
}

private void validateTimestamp(string value, string name)
{
    import std.datetime.systime : SysTime;
    try SysTime.fromISOExtString(value);
    catch (Exception) throw new Exception("Invalid timestamp: " ~ name);
}


private void enforceExactFields(JSONValue value, string[] allowed)
{
    foreach (field; value.objectNoRef.keys) {
        bool found;
        foreach (name; allowed) if (field == name) found = true;
        enforce(found, "Unknown JSON field: " ~ field);
    }
}
