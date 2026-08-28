module wheatley.server.presentation.store;

import std.array : Appender, appender;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getSize, mkdirRecurse, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.stdio : File;
import std.string : splitLines, strip;

version (Posix) {
    enum LOCK_EX = 0x02;
    enum LOCK_UN = 0x08;
    extern(C) pragma(mangle, "flock") int flockCall(int, int);
}

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.runtime.now_iso : nowIso;

/** One durable presentation entry, used to resume live presentation without
    depending on process-local subscribers. */
struct PresentationEntry
{
    long sequence;
    string source;
    string kind;
    string turnId;
    string itemId;
    string payloadJson;
}

/** One live reader over the append-only journal. Existing history is scanned
    at most once; subsequent polls read only bytes appended after its cursor. */
final class PresentationFollower
{
    private string sessionRoot;
    private ulong offset;
    private long cursor;

    this(string sessionRoot, long afterSequence)
    {
        enforce(afterSequence >= 0, "Presentation sequence cannot be negative");
        this.sessionRoot = sessionRoot;
        this.cursor = afterSequence;
        withSessionStorageLock(sessionRoot, {
            auto path = buildPath(sessionRoot, "presentation.jsonl");
            auto watermark = presentationWatermarkUnlocked(sessionRoot);
            enforce(afterSequence <= watermark, "Presentation cursor exceeds watermark");
            if (!exists(path)) return;
            if (afterSequence == watermark) {
                offset = getSize(path);
                return;
            }
            auto file = File(path, "r");
            char[] line;
            long found;
            while (file.readln(line)) {
                auto entry = presentationEntry(line);
                if (entry.sequence > afterSequence) break;
                offset += line.length;
                found = entry.sequence;
            }
            enforce(found == afterSequence, "Presentation cursor is not in the journal");
        });
    }

    PresentationEntry[] readAvailable()
    {
        PresentationEntry[] entries;
        withSessionStorageLock(sessionRoot, {
            auto path = buildPath(sessionRoot, "presentation.jsonl");
            if (!exists(path)) return;
            enforce(getSize(path) >= offset, "Presentation journal shrank while following");
            auto file = File(path, "r");
            file.seek(offset);
            char[] line;
            while (file.readln(line)) {
                offset += line.length;
                auto entry = presentationEntry(line);
                enforce(entry.sequence == cursor + 1, "Presentation journal sequence gap");
                cursor = entry.sequence;
                entries ~= entry;
            }
        });
        return entries;
    }
}

/** Cross-process session chronology shared by wheatleyd and wheatley-codexd. */
long appendPresentation(
    string sessionRoot,
    string source,
    string kind,
    string turnId,
    string itemId,
    string payloadJson,
)
{
    return appendPresentation(
        sessionRoot,
        source,
        kind,
        turnId,
        itemId,
        (long sequence) => payloadJson,
    );
}

/** Appends one fixed session prefix entry exactly once. The marker is written
    under the same session lock and only after the journal payload is durable,
    so bootstrap retries cannot duplicate the visible prefix. */
long appendPresentationOnce(
    string sessionRoot,
    string markerName,
    string source,
    string kind,
    string turnId,
    string itemId,
    string payloadJson,
)
{
    long sequence;
    withSessionStorageLock(sessionRoot, {
        auto marker = buildPath(sessionRoot, markerName);
        if (exists(marker)) return;
        auto sequencePath = buildPath(sessionRoot, "presentation.sequence");
        if (exists(sequencePath)) {
            auto text = readText(sequencePath).strip;
            if (text.length) sequence = text.to!long;
        }
        sequence++;
        auto sequenceFile = File(sequencePath, "w");
        sequenceFile.writeln(sequence);
        sequenceFile.flush();
        auto journal = File(buildPath(sessionRoot, "presentation.jsonl"), "a");
        journal.writeln(jsonObject([
            jsonLongField("sequence", sequence),
            jsonStringField("at", nowIso()),
            jsonStringField("source", source),
            jsonStringField("kind", kind),
            jsonStringField("turn_id", turnId),
            jsonStringField("item_id", itemId),
            jsonRawField("payload", payloadJson),
        ]));
        journal.flush();
        auto markerFile = File(marker, "w");
        markerFile.writeln("recorded\n");
        markerFile.flush();
    });
    return sequence;
}

long appendPresentation(
    string sessionRoot,
    string source,
    string kind,
    string turnId,
    string itemId,
    scope string delegate(long sequence) payloadJson,
)
{
    long sequence;
    withSessionStorageLock(sessionRoot, {
        auto sequencePath = buildPath(sessionRoot, "presentation.sequence");
        if (exists(sequencePath)) {
            auto text = readText(sequencePath).strip;
            if (text.length) sequence = text.to!long;
        }
        sequence++;
        auto sequenceFile = File(sequencePath, "w");
        sequenceFile.writeln(sequence);
        sequenceFile.flush();

        auto journal = File(buildPath(sessionRoot, "presentation.jsonl"), "a");
        journal.writeln(jsonObject([
            jsonLongField("sequence", sequence),
            jsonStringField("at", nowIso()),
            jsonStringField("source", source),
            jsonStringField("kind", kind),
            jsonStringField("turn_id", turnId),
            jsonStringField("item_id", itemId),
            jsonRawField("payload", payloadJson(sequence)),
        ]));
        journal.flush();
    });
    return sequence;
}

string presentationSnapshotJson(string sessionRoot)
{
    auto path = buildPath(sessionRoot, "presentation.jsonl");
    string[] entries;
    long watermark;
    JSONValue pendingDelta;
    Appender!string pendingText;
    bool hasPendingDelta;

    void flushPendingDelta()
    {
        if (!hasPendingDelta) return;
        pendingDelta.object["payload"].object["payload"].object["text"] = pendingText.data;
        entries ~= pendingDelta.toString();
        pendingDelta = JSONValue.init;
        pendingText = appender!string;
        hasPendingDelta = false;
    }

    withSessionStorageLock(sessionRoot, {
        if (exists(path)) foreach (line; readText(path).splitLines) {
            auto clean = line.strip;
            if (!clean.length) continue;
            auto value = parseJSON(clean);
            enforce(value.type == JSONType.object, "Presentation entry is not an object");
            auto sequence = "sequence" in value.objectNoRef;
            enforce(sequence !is null, "Presentation entry has no sequence");
            watermark = sequence.type == JSONType.integer
                ? sequence.integer
                : cast(long) sequence.uinteger;
            if (isCompactableTextDelta(value)) {
                if (hasPendingDelta && !sameTextDeltaRun(pendingDelta, value))
                    flushPendingDelta();
                if (!hasPendingDelta) {
                    pendingText = appender!string;
                    hasPendingDelta = true;
                }
                pendingDelta = value;
                pendingText.put(textDelta(value));
            } else {
                flushPendingDelta();
                entries ~= value.toString();
            }
        }
        flushPendingDelta();
    });
    return jsonObject([
        jsonLongField("watermark", watermark),
        jsonRawField("entries", "[" ~ entries.join(",") ~ "]"),
    ]);
}

/** Recovery snapshots collapse adjacent token deltas into one equivalent
    event. The append-only journal and live SSE cursor remain untouched. */
private bool isCompactableTextDelta(JSONValue value)
{
    if (value.type != JSONType.object) return false;
    auto entry = value.objectNoRef;
    if (entry.get("source", JSONValue.init).type != JSONType.string
        || entry["source"].str != "pi") return false;
    auto kind = entry.get("kind", JSONValue.init);
    if (kind.type != JSONType.string
        || (kind.str != "reasoning" && kind.str != "assistant_delta")) return false;
    auto payload = entry.get("payload", JSONValue.init);
    if (payload.type != JSONType.object) return false;
    auto body = payload.objectNoRef.get("payload", JSONValue.init);
    if (body.type != JSONType.object) return false;
    auto text = body.objectNoRef.get("text", JSONValue.init);
    if (text.type != JSONType.string) return false;
    if (kind.str == "assistant_delta") return true;
    auto phase = body.objectNoRef.get("phase", JSONValue.init);
    return phase.type == JSONType.string && phase.str == "delta";
}

private bool sameTextDeltaRun(JSONValue left, JSONValue right)
{
    return left.objectNoRef["source"].str == right.objectNoRef["source"].str
        && left.objectNoRef["kind"].str == right.objectNoRef["kind"].str
        && left.objectNoRef["turn_id"].str == right.objectNoRef["turn_id"].str
        && left.objectNoRef["item_id"].str == right.objectNoRef["item_id"].str;
}

private string textDelta(JSONValue value)
{
    return value.objectNoRef["payload"].objectNoRef["payload"].objectNoRef["text"].str;
}

/** The durable cursor used by clients waiting for a new session presentation. */
long presentationWatermark(string sessionRoot)
{
    long watermark;
    withSessionStorageLock(sessionRoot, {
        watermark = presentationWatermarkUnlocked(sessionRoot);
    });
    return watermark;
}

private long presentationWatermarkUnlocked(string sessionRoot)
{
    auto path = buildPath(sessionRoot, "presentation.sequence");
    if (!exists(path)) return 0;
    auto text = readText(path).strip;
    return text.length ? text.to!long : 0;
}

/** Returns every presentation record strictly after `afterSequence` in its
    durable order. The journal is read under the same lock as appends, so an
    SSE client never observes a watermark before its corresponding payload. */
PresentationEntry[] presentationEntriesAfter(string sessionRoot, long afterSequence)
{
    enforce(afterSequence >= 0, "Presentation sequence cannot be negative");
    auto path = buildPath(sessionRoot, "presentation.jsonl");
    PresentationEntry[] entries;
    withSessionStorageLock(sessionRoot, {
        if (!exists(path)) return;
        foreach (line; readText(path).splitLines) {
            auto clean = line.strip;
            if (!clean.length) continue;
            auto entry = presentationEntry(clean);
            if (entry.sequence > afterSequence) entries ~= entry;
        }
    });
    return entries;
}

private PresentationEntry presentationEntry(const(char)[] line)
{
    auto value = parseJSON(line.strip);
    enforce(value.type == JSONType.object, "Presentation entry is not an object");
    auto entry = value.objectNoRef;
    auto sequence = "sequence" in entry;
    enforce(sequence !is null, "Presentation entry has no sequence");
    auto number = sequence.type == JSONType.integer
        ? sequence.integer
        : cast(long) sequence.uinteger;
    return PresentationEntry(
        number,
        entry["source"].str,
        entry["kind"].str,
        entry["turn_id"].str,
        entry["item_id"].str,
        entry["payload"].toString(),
    );
}

void withSessionStorageLock(string sessionRoot, scope void delegate() operation)
{
    auto lockPath = buildPath(sessionRoot, ".presentation.lock");
    mkdirRecurse(dirName(lockPath));
    auto lockFile = File(lockPath, "a+");
    version (Posix) enforce(flockCall(lockFile.fileno, LOCK_EX) == 0,
        "Cannot lock the session storage");
    scope(exit) version (Posix) flockCall(lockFile.fileno, LOCK_UN);
    operation();
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

    auto root = buildPath(tempDir(), "wheatley-presentation-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    assert(appendPresentation(root, "pi", "user", "pi-1", "", "{}") == 1);
    assert(appendPresentation(
        root,
        "codex",
        "final",
        "codex-1",
        "final-1",
        (long sequence) => `{"sequence":` ~ sequence.to!string ~ `}`,
    ) == 2);
    auto snapshot = parseJSON(presentationSnapshotJson(root));
    assert(snapshot["watermark"].integer == 2);
    auto entries = snapshot["entries"].array;
    assert(entries.length == 2);
    assert(entries[1]["payload"]["sequence"].integer == 2);
    assert(presentationWatermark(root) == 2);
    auto resumed = presentationEntriesAfter(root, 1);
    assert(resumed.length == 1);
    assert(resumed[0].sequence == 2);
    assert(resumed[0].source == "codex");
    assert(resumed[0].payloadJson == `{"sequence":2}`);
    auto follower = new PresentationFollower(root, 2);
    assert(follower.readAvailable().length == 0);

    assert(appendPresentationOnce(
        root,
        ".bootstrap-marker",
        "pi",
        "bootstrap",
        "",
        "model-context",
        `{"kind":"model_context"}`,
    ) == 3);
    auto followed = follower.readAvailable();
    assert(followed.length == 1);
    assert(followed[0].sequence == 3);
    assert(followed[0].itemId == "model-context");
    assert(follower.readAvailable().length == 0);
    assert(appendPresentationOnce(
        root,
        ".bootstrap-marker",
        "pi",
        "bootstrap",
        "",
        "model-context",
        `{"kind":"model_context"}`,
    ) == 0);
    assert(presentationWatermark(root) == 3);
}

unittest
{
    import std.file : rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-presentation-compact-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    assert(appendPresentation(
        root,
        "pi",
        "reasoning",
        "turn-1",
        "assistant:0:0",
        `{"kind":"reasoning","payload":{"phase":"start","text":""}}`,
    ) == 1);
    assert(appendPresentation(
        root,
        "pi",
        "reasoning",
        "turn-1",
        "assistant:0:0",
        `{"kind":"reasoning","payload":{"phase":"delta","duration_ms":10,"text":"Hel"}}`,
    ) == 2);
    assert(appendPresentation(
        root,
        "pi",
        "reasoning",
        "turn-1",
        "assistant:0:0",
        `{"kind":"reasoning","payload":{"phase":"delta","duration_ms":20,"text":"lo"}}`,
    ) == 3);
    assert(appendPresentation(
        root,
        "pi",
        "reasoning",
        "turn-1",
        "assistant:0:0",
        `{"kind":"reasoning","payload":{"phase":"end","duration_ms":20,"text":""}}`,
    ) == 4);
    assert(appendPresentation(
        root,
        "pi",
        "assistant_delta",
        "turn-1",
        "assistant:0:1",
        `{"kind":"assistant_delta","payload":{"text":"Wor"}}`,
    ) == 5);
    assert(appendPresentation(
        root,
        "pi",
        "assistant_delta",
        "turn-1",
        "assistant:0:1",
        `{"kind":"assistant_delta","payload":{"text":"ld"}}`,
    ) == 6);

    auto snapshot = parseJSON(presentationSnapshotJson(root));
    assert(snapshot["watermark"].integer == 6);
    auto entries = snapshot["entries"].array;
    assert(entries.length == 4);
    assert(entries[1]["sequence"].integer == 3);
    assert(entries[1]["payload"]["payload"]["duration_ms"].integer == 20);
    assert(entries[1]["payload"]["payload"]["text"].str == "Hello");
    assert(entries[3]["sequence"].integer == 6);
    assert(entries[3]["payload"]["payload"]["text"].str == "World");
    assert(presentationEntriesAfter(root, 0).length == 6);
}
