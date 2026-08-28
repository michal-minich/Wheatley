module wheatley.server.history.store.paths;

import std.array : appender;
import std.conv : to;
import std.file : exists;
import std.path : baseName, buildPath, dirName;
import std.string : indexOf;

import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.safe_token :
    enforceSafeToken,
    safeToken;

string toolsJsonPath(string turnRoot)
{
    return buildPath(turnRoot, "tools.json");
}

string modelInputJsonPath(string turnRoot)
{
    return buildPath(turnRoot, "model-input.json");
}

string llmRequestsJsonPath(string turnRoot)
{
    return buildPath(turnRoot, "llm-requests.json");
}

string errorsJsonPath(string root)
{
    return buildPath(root, "errors.json");
}

string piSessionJsonlPath(string sessionRoot)
{
    return buildPath(sessionRoot, "pi_session.jsonl");
}

string contextMarkdownPath(string sessionRoot)
{
    return buildPath(sessionRoot, "context.md");
}

string sessionRootFromTurnRoot(string turnRoot)
{
    return dirName(dirName(turnRoot));
}

string isoDate(string iso)
{
    if (iso.length >= 10 && iso[4] == '-' && iso[7] == '-') return iso[0 .. 10];
    return nowIso()[0 .. 10];
}

string sessionFolderName(string iso)
{
    if (iso.length >= 19) return iso[11 .. 13] ~ "_" ~ iso[14 .. 16] ~ "_" ~ iso[17 .. 19];
    return "00_00_00";
}

string turnFolderName(string iso)
{
    auto base = sessionFolderName(iso);
    auto micros = "000000";
    auto dot = iso.indexOf(".");
    if (dot >= 0) {
        auto found = appender!string;
        foreach (ch; iso[cast(size_t) dot + 1 .. $]) {
            if (ch < '0' || ch > '9') break;
            if (found.data.length < 6) found.put(ch);
        }
        while (found.data.length < 6) found.put("0");
        micros = found.data[0 .. 6];
    }
    return base ~ "_" ~ micros;
}

string sessionStartFromPath(string sessionRoot)
{
    auto folder = baseName(sessionRoot);
    auto dayDir = dirName(sessionRoot);
    auto day = baseName(dayDir);
    auto month = baseName(dirName(dayDir));
    auto year = baseName(dirName(dirName(dayDir)));
    if (folder.length >= 8) {
        return year ~ "-" ~ month ~ "-" ~ day ~ "T" ~
            folder[0 .. 2] ~ ":" ~ folder[3 .. 5] ~ ":" ~ folder[6 .. 8] ~ ".000000Z";
    }
    return nowIso();
}

string turnStartFromFolder(string day, string folder)
{
    if (folder.length >= 15) {
        return day ~ "T" ~ folder[0 .. 2] ~ ":" ~ folder[3 .. 5] ~ ":" ~
            folder[6 .. 8] ~ "." ~ folder[9 .. 15] ~ "Z";
    }
    if (folder.length >= 8) {
        return day ~ "T" ~ folder[0 .. 2] ~ ":" ~ folder[3 .. 5] ~ ":" ~
            folder[6 .. 8] ~ ".000000Z";
    }
    return "";
}

string uniquePath(string base, string fallback = "")
{
    if (!exists(base)) return base;
    auto suffix = fallback.length ? fallback : "runtime";
    foreach (index; 1 .. 10_000) {
        auto candidate = base ~ "-" ~ suffix ~ "-" ~ index.to!string;
        if (!exists(candidate)) return candidate;
    }
    throw new Exception("Could not create unique runtime path: " ~ base);
}

string uniqueTimestampPath(string base)
{
    if (!exists(base)) return base;
    foreach (index; 2 .. 10_000) {
        auto candidate = base ~ "_" ~ index.to!string;
        if (!exists(candidate)) return candidate;
    }
    throw new Exception("Could not create unique timestamp path: " ~ base);
}

string safeComponent(string value)
{
    return safeToken(value, "item");
}

void enforceSafeComponent(string value, string label)
{
    enforceSafeToken(value, label);
}
