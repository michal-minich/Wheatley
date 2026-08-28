module wheatley.server.history.store.sync_paths;

import std.conv : to;
import std.exception : assertThrown, enforce;
import std.string : split;

struct SyncSessionPath
{
    string value;
    string year;
    string month;
    string day;
    string folder;
}

struct SyncTurnPath
{
    string value;
    string folder;
}

SyncSessionPath parseSyncSessionPath(string value)
{
    auto parts = value.split("/");
    enforce(parts.length == 4, "Session path must be YYYY/MM/DD/HH_MM_SS[_N]");
    enforceDecimal(parts[0], 4, "Session year");
    enforceDecimal(parts[1], 2, "Session month");
    enforceDecimal(parts[2], 2, "Session day");
    enforce(decimal(parts[1]) >= 1 && decimal(parts[1]) <= 12, "Session month is invalid");
    enforce(decimal(parts[2]) >= 1 && decimal(parts[2]) <= 31, "Session day is invalid");
    enforceTimestamp(parts[3], false, "Session");
    return SyncSessionPath(value, parts[0], parts[1], parts[2], parts[3]);
}

SyncTurnPath parseSyncTurnPath(string value)
{
    enforceTimestamp(value, true, "Turn");
    return SyncTurnPath(value, value);
}

private void enforceTimestamp(string value, bool withMicros, string label)
{
    auto primaryLength = withMicros ? 15 : 8;
    enforce(value.length >= primaryLength, label ~ " path is too short");
    enforce(value[2] == '_' && value[5] == '_', label ~ " path time is invalid");
    enforceDecimal(value[0 .. 2], 2, label ~ " hour");
    enforceDecimal(value[3 .. 5], 2, label ~ " minute");
    enforceDecimal(value[6 .. 8], 2, label ~ " second");
    enforce(decimal(value[0 .. 2]) <= 23, label ~ " hour is invalid");
    enforce(decimal(value[3 .. 5]) <= 59, label ~ " minute is invalid");
    enforce(decimal(value[6 .. 8]) <= 59, label ~ " second is invalid");

    if (withMicros) {
        enforce(value[8] == '_', label ~ " path microseconds are invalid");
        enforceDecimal(value[9 .. 15], 6, label ~ " microseconds");
    }

    if (value.length == primaryLength) return;
    enforce(value[primaryLength] == '_', label ~ " path suffix is invalid");
    auto suffix = value[primaryLength + 1 .. $];
    enforceDecimal(suffix, suffix.length, label ~ " path suffix");
    enforce(decimal(suffix) >= 2, label ~ " path suffix must start at 2");
}

private void enforceDecimal(string value, size_t expectedLength, string label)
{
    enforce(value.length == expectedLength && expectedLength > 0, label ~ " is invalid");
    foreach (ch; value) enforce(ch >= '0' && ch <= '9', label ~ " is invalid");
}

private int decimal(string value)
{
    return value.to!int;
}

unittest
{
    auto session = parseSyncSessionPath("2026/08/05/12_34_56_2");
    assert(session.folder == "12_34_56_2");
    assert(parseSyncTurnPath("12_34_56_123456_2").folder == "12_34_56_123456_2");
    assertThrown!Exception(parseSyncSessionPath("2026/08/05/12_34_56/extra"));
    assertThrown!Exception(parseSyncSessionPath("2026/08/05/12_34_56_1"));
    assertThrown!Exception(parseSyncTurnPath("12_34_56_12345"));
    assertThrown!Exception(parseSyncTurnPath("12_34_56_123456/other"));
}
