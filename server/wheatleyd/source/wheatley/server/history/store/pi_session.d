module wheatley.server.history.store.pi_session;

import std.array : appender;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.exception : assertThrown, enforce;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : endsWith, indexOf, splitLines, strip;

import wheatley.server.history.store.json :
    jsonBool,
    jsonLong,
    jsonText,
    objectField;
import wheatley.server.history.store.types : StoredTurn;

struct PiPresentationItem
{
    string id;
    string kind;
    string text;
    string timestamp;
    string completedAt;
    long callIndex = -1;
    string toolName;
    string toolCallId;
    JSONValue arguments;
    JSONValue content;
    JSONValue details;
    JSONValue extensionData;
    bool hasResult;
    bool isError;
    long durationMs = -1;
}

struct PiTurnTranscript
{
    JSONValue[] events;
    string workingDirectory;
    string startedAt;
    string prompt;
    string promptTimestamp;
    JSONValue promptEvent;

    PiPresentationItem[] items()
    {
        PiPresentationItem[] output;
        size_t[string] toolIndexes;
        long assistantIndex;
        long callIndex;
        auto previousTimestamp = startedAt;

        foreach (event; events) {
            auto timestamp = jsonText(event, "timestamp");
            auto intervalStartedAt = previousTimestamp;
            if (timestamp.length) previousTimestamp = timestamp;
            auto message = objectField(event, "message");
            auto role = jsonText(message, "role");
            if (role == "assistant") {
                foreach (contentIndex, part; arrayField(message, "content")) {
                    auto type = jsonText(part, "type");
                    auto id = itemId(assistantIndex, contentIndex);
                    if (type == "thinking") {
                        auto text = jsonText(part, "thinking").strip;
                        if (text.length) {
                            auto item = PiPresentationItem(
                                id,
                                "reasoning",
                                text,
                                timestamp,
                                "",
                            );
                            item.durationMs = timestampDurationMs(intervalStartedAt, timestamp);
                            output ~= item;
                        }
                    } else if (type == "text") {
                        auto text = jsonText(part, "text").strip;
                        if (text.length) output ~= PiPresentationItem(
                            id,
                            "assistant",
                            text,
                            jsonText(event, "timestamp"),
                            "",
                        );
                    } else if (type == "toolCall") {
                        auto callId = jsonText(part, "id");
                        enforce(callId.length, "Pi tool call is missing id");
                        output ~= PiPresentationItem(
                            id,
                            "tool",
                            "",
                            jsonText(event, "timestamp"),
                            "",
                            callIndex,
                            jsonText(part, "name"),
                            callId,
                            objectField(part, "arguments"),
                        );
                        toolIndexes[callId] = output.length - 1;
                        callIndex++;
                    } else {
                        enforce(false, "Unsupported Pi assistant content type: " ~ type);
                    }
                }
                assistantIndex++;
                continue;
            }
            if (role != "toolResult") continue;

            auto callId = jsonText(message, "toolCallId");
            auto index = callId in toolIndexes;
            enforce(index !is null, "Pi tool result has no preceding tool call: " ~ callId);
            auto item = &output[*index];
            item.hasResult = true;
            item.isError = jsonBool(message, "isError");
            item.completedAt = jsonText(event, "timestamp");
            item.content = arrayValue(message, "content");
            item.details = field(message, "details");
            item.extensionData = matchingExtensionData(events, item.details);
        }
        return output;
    }

    PiPresentationItem item(string id)
    {
        foreach (item; items) {
            if (item.id == id) return item;
        }
        return PiPresentationItem();
    }

    PiPresentationItem tool(long callIndex)
    {
        foreach (item; items) {
            if (item.kind == "tool" && item.callIndex == callIndex) return item;
        }
        return PiPresentationItem();
    }
}

struct PiSessionTranscript
{
    JSONValue[] events;
    string workingDirectory;

    PiTurnTranscript turn(StoredTurn turn)
    {
        auto start = turnUserEventIndex(events, turn);
        if (start >= events.length) {
            enforce(
                turn.status == "pending" || turn.status == "running" || turn.status == "failed"
                    || turn.status == "stopped",
                "Pi user message not found for turn " ~ turn.id,
            );
            return PiTurnTranscript([], workingDirectory, turn.startedAt, "", "", JSONValue(null));
        }
        auto end = nextUserEventIndex(events, start + 1);
        auto promptTimestamp = jsonText(events[start], "timestamp");
        return PiTurnTranscript(
            events[start + 1 .. end],
            workingDirectory,
            promptTimestamp,
            messageText(objectField(events[start], "message")),
            promptTimestamp,
            events[start],
        );
    }
}

struct PiSessionBranch
{
    string jsonl;
    PiSessionTranscript transcript;
    string completedAt;
}

PiSessionBranch branchPiSession(
    string path,
    StoredTurn turn,
    string kind,
    string targetItemId,
    string newSessionId,
    string createdAt,
    string workingDirectory,
)
{
    enforce(kind == "user" || kind == "reasoning" || kind == "assistant"
        || kind == "artifact", "Unsupported chat branch kind");
    enforce(kind == "user" || targetItemId.length, "Chat branch item ID is required");

    JSONValue header;
    JSONValue[] entries;
    JSONValue target;
    bool insideTurn;
    long assistantIndex;
    string artifactCallId;
    string completedAt;

    foreach (line; readText(path).splitLines()) {
        auto clean = line.strip;
        if (!clean.length) continue;
        auto event = parseJSON(clean);
        if (jsonText(event, "type") == "session") {
            header = event;
            continue;
        }
        entries ~= event;

        auto message = objectField(event, "message");
        auto role = jsonText(message, "role");
        if (!insideTurn) {
            if (role != "user" || !messageMatchesTurnPrompt(
                message,
                turn.userText.strip,
                turn.hasUserImage,
                turn.source == "scheduled_task",
            ) || !timestampInsideTurn(jsonText(event, "timestamp"), turn)) continue;
            insideTurn = true;
            if (kind == "user") {
                target = event;
                completedAt = jsonText(event, "timestamp");
                break;
            }
            continue;
        }
        enforce(role != "user", "Chat branch item was not found in its turn");

        if (role == "assistant") {
            auto content = arrayField(message, "content");
            foreach (contentIndex, part; content) {
                auto id = itemId(assistantIndex, contentIndex);
                auto type = jsonText(part, "type");
                if (id != targetItemId) continue;
                if (kind == "artifact") {
                    enforce(type == "toolCall", "Chat branch artifact is not a tool result");
                    artifactCallId = jsonText(part, "id");
                    enforce(artifactCallId.length, "Chat branch artifact tool call has no ID");
                    break;
                }
                enforce(
                    (kind == "reasoning" && type == "thinking")
                        || (kind == "assistant" && type == "text"),
                    "Chat branch item kind does not match Pi history",
                );
                auto sliced = content[0 .. contentIndex + 1].dup;
                auto slicedMessage = message;
                slicedMessage.object["content"] = JSONValue(sliced);
                target = event;
                target.object["message"] = slicedMessage;
                completedAt = jsonText(event, "timestamp");
                break;
            }
            if (target.type == JSONType.object) break;
            assistantIndex++;
            continue;
        }
        if (role == "toolResult" && artifactCallId.length
            && jsonText(message, "toolCallId") == artifactCallId) {
            target = event;
            completedAt = jsonText(event, "timestamp");
            break;
        }
    }

    enforce(header.type == JSONType.object, "Pi session header is missing");
    enforce(target.type == JSONType.object, "Chat branch point is not durably available");
    auto targetId = jsonText(target, "id");
    enforce(targetId.length, "Chat branch Pi entry has no ID");

    JSONValue[string] byId;
    foreach (entry; entries) {
        auto id = jsonText(entry, "id");
        if (id.length) byId[id] = entry;
    }
    byId[targetId] = target;

    JSONValue[] ancestry;
    auto currentId = targetId;
    while (currentId.length) {
        auto current = currentId in byId;
        enforce(current !is null, "Chat branch Pi ancestry is incomplete");
        ancestry ~= *current;
        currentId = jsonText(*current, "parentId");
    }

    auto output = appender!string;
    header.object["id"] = JSONValue(newSessionId);
    header.object["timestamp"] = JSONValue(createdAt);
    header.object["cwd"] = JSONValue(workingDirectory);
    output.put(header.toString());
    output.put("\n");
    JSONValue[] ordered;
    foreach_reverse (entry; ancestry) {
        ordered ~= entry;
        output.put(entry.toString());
        output.put("\n");
    }
    return PiSessionBranch(
        output.data,
        PiSessionTranscript(ordered, jsonText(header, "cwd")),
        completedAt,
    );
}

unittest
{
    import std.file : rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-pi-branch-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    auto path = buildPath(root, "pi_session.jsonl");
    auto jsonl =
        `{"type":"session","version":3,"id":"old","timestamp":"2026-08-16T08:00:00Z","cwd":"/tmp"}` ~ "\n"
        ~ `{"type":"message","id":"user","parentId":null,"timestamp":"2026-08-16T08:01:00Z","message":{"role":"user","content":[{"type":"text","text":"Explore"}]}}` ~ "\n"
        ~ `{"type":"message","id":"assistant","parentId":"user","timestamp":"2026-08-16T08:01:02Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Consider"},{"type":"text","text":"First route"},{"type":"toolCall","id":"call-1","name":"image","arguments":{}}]}}` ~ "\n"
        ~ `{"type":"message","id":"tool","parentId":"assistant","timestamp":"2026-08-16T08:01:03Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"image","content":[{"type":"text","text":"image result"}],"details":{"url":"/api/profiles/tester/sessions/old/turns/turn/images/a.png"}}}` ~ "\n"
        ~ `{"type":"message","id":"final","parentId":"tool","timestamp":"2026-08-16T08:01:04Z","message":{"role":"assistant","content":[{"type":"text","text":"Future answer"}]}}` ~ "\n";
    import std.file : mkdirRecurse;
    mkdirRecurse(root);
    write(path, jsonl);

    StoredTurn turn;
    turn.id = "tester/sessions/2026/08/16/10_00_00/turns/10_01_00_000000";
    turn.userText = "Explore";
    turn.startedAt = "2026-08-16T08:01:00Z";
    turn.completedAt = "2026-08-16T08:01:05Z";
    turn.status = "completed";

    auto user = branchPiSession(path, turn, "user", "", "new-user", "2026-08-16T09:00:00Z", "/tmp/branch");
    assert(user.transcript.events.length == 1);
    assert(jsonText(parseJSON(user.jsonl.splitLines()[0]), "id") == "new-user");
    assert(user.transcript.workingDirectory == "/tmp/branch");
    assert(jsonText(objectField(user.transcript.turn(turn).promptEvent, "message"), "role") == "user");

    auto reasoning = branchPiSession(path, turn, "reasoning", "assistant:0:0", "new-reasoning", "2026-08-16T09:00:00Z", "/tmp/branch");
    assert(reasoning.transcript.events.length == 2);
    assert(reasoning.transcript.turn(turn).items().length == 1);
    assert(reasoning.transcript.turn(turn).items()[0].kind == "reasoning");

    auto assistant = branchPiSession(path, turn, "assistant", "assistant:0:1", "new-assistant", "2026-08-16T09:00:00Z", "/tmp/branch");
    auto assistantItems = assistant.transcript.turn(turn).items();
    assert(assistantItems.length == 2);
    assert(assistantItems[$ - 1].kind == "assistant");
    assert(assistantItems[$ - 1].text == "First route");

    auto artifact = branchPiSession(path, turn, "artifact", "assistant:0:2", "new-artifact", "2026-08-16T09:00:00Z", "/tmp/branch");
    auto artifactItems = artifact.transcript.turn(turn).items();
    assert(artifactItems.length == 3);
    assert(artifactItems[$ - 1].kind == "tool");
    assert(artifactItems[$ - 1].hasResult);
    assert(artifact.jsonl.indexOf("Future answer") == -1);
}

unittest
{
    JSONValue[] events;
    auto session = PiSessionTranscript(events, "/tmp");
    StoredTurn turn;
    turn.id = "tester/sessions/2026/08/11/17_00_00/turns/17_01_00_000000";
    turn.startedAt = "2026-08-11T15:01:00Z";

    foreach (status; ["pending", "running", "failed", "stopped"]) {
        turn.status = status;
        auto transcript = session.turn(turn);
        assert(transcript.events.length == 0);
        assert(transcript.startedAt == turn.startedAt);
    }

    turn.status = "completed";
    assertThrown!Exception(session.turn(turn));
}

PiSessionTranscript loadPiSessionTranscript(string path)
{
    enforce(exists(path), "Pi session not found");
    JSONValue[] events;
    foreach (line; readText(path).splitLines()) {
        auto clean = line.strip;
        if (clean.length) events ~= parseJSON(clean);
    }
    enforce(events.length, "Pi session is empty");
    enforce(jsonText(events[0], "type") == "session", "Pi session header is missing");
    enforce(jsonLong(events[0], "version") == 3, "Unsupported Pi session version");
    return PiSessionTranscript(events, jsonText(events[0], "cwd"));
}

private size_t turnUserEventIndex(JSONValue[] events, StoredTurn turn)
{
    auto prompt = turn.userText.strip;
    foreach (index, event; events) {
        auto message = objectField(event, "message");
        if (jsonText(message, "role") != "user") continue;
        if (!messageMatchesTurnPrompt(
            message,
            prompt,
            turn.hasUserImage,
            turn.source == "scheduled_task",
        )) continue;
        if (timestampInsideTurn(jsonText(event, "timestamp"), turn)) return index;
    }
    return events.length;
}

private bool messageMatchesTurnPrompt(
    JSONValue message,
    string prompt,
    bool hasUserImage,
    bool hasScheduledPrivatePrompt = false,
)
{
    auto text = messageText(message).strip;
    if (!prompt.length) return hasUserImage
        && messageHasImage(message)
        && messageEndsWithCurrentUserRequest(text, prompt);
    return text == prompt
        || messageEndsWithCurrentUserRequest(text, prompt)
        || (hasScheduledPrivatePrompt && text.endsWith(prompt));
}

private bool messageEndsWithCurrentUserRequest(string text, string prompt)
{
    if (!text.endsWith(prompt)) return false;
    return text[0 .. $ - prompt.length].strip.endsWith("# Current User Request");
}

unittest
{
    auto request = parseJSON(`{
        "content": [
            {"type": "text", "text": "Context\n\n# Current User Request\nSearch the web."}
        ]
    }`);
    assert(messageMatchesTurnPrompt(request, "Search the web.", false));

    auto imageOnly = parseJSON(`{
        "content": [
            {"type": "text", "text": "Context\n\n# Current User Request"},
            {"type": "image", "data": "AA==", "mimeType": "image/png"}
        ]
    }`);
    assert(messageMatchesTurnPrompt(imageOnly, "", true));
    assert(!messageMatchesTurnPrompt(imageOnly, "", false));

    auto scheduled = parseJSON(`{
        "content": [
            {"type": "text", "text": "private scheduler context\n\nTell a joke."}
        ]
    }`);
    assert(!messageMatchesTurnPrompt(scheduled, "Tell a joke.", false));
    assert(messageMatchesTurnPrompt(scheduled, "Tell a joke.", false, true));
}

private bool messageHasImage(JSONValue message)
{
    foreach (part; arrayField(message, "content")) {
        if (jsonText(part, "type") == "image") return true;
    }
    return false;
}

private size_t nextUserEventIndex(JSONValue[] events, size_t start)
{
    foreach (index; start .. events.length) {
        auto message = objectField(events[index], "message");
        if (jsonText(message, "role") == "user") return index;
    }
    return events.length;
}

private bool timestampInsideTurn(string timestamp, StoredTurn turn)
{
    if (!timestamp.length || !turn.startedAt.length) return false;
    auto value = SysTime.fromISOExtString(timestamp);
    auto started = SysTime.fromISOExtString(turn.startedAt);
    if (value < started) return false;
    return !turn.completedAt.length || value <= SysTime.fromISOExtString(turn.completedAt);
}

private string messageText(JSONValue message)
{
    auto output = appender!string;
    foreach (part; arrayField(message, "content")) {
        if (jsonText(part, "type") == "text") output.put(jsonText(part, "text"));
    }
    return output.data;
}

private string itemId(long assistantIndex, size_t contentIndex)
{
    return "assistant:" ~ assistantIndex.to!string ~ ":" ~ contentIndex.to!string;
}

private long timestampDurationMs(string startedAt, string completedAt)
{
    if (!startedAt.length || !completedAt.length) return -1;
    auto duration = SysTime.fromISOExtString(completedAt) - SysTime.fromISOExtString(startedAt);
    return duration.total!"msecs";
}

private JSONValue matchingExtensionData(JSONValue[] events, JSONValue details)
{
    auto searchId = jsonText(details, "searchId");
    auto responseId = jsonText(details, "responseId");
    auto expectedId = searchId.length ? searchId : responseId;
    if (!expectedId.length) return JSONValue(null);

    foreach (event; events) {
        if (jsonText(event, "type") != "custom") continue;
        if (jsonText(event, "customType") != "web-search-results") continue;
        auto data = objectField(event, "data");
        if (jsonText(data, "id") == expectedId) return data;
    }
    return JSONValue(null);
}

private JSONValue field(JSONValue value, string name)
{
    if (value.type != JSONType.object) return JSONValue(null);
    auto item = name in value.objectNoRef;
    return item is null ? JSONValue(null) : *item;
}

private JSONValue[] arrayField(JSONValue value, string name)
{
    auto item = field(value, name);
    return item.type == JSONType.array ? item.array : [];
}

private JSONValue arrayValue(JSONValue value, string name)
{
    auto item = field(value, name);
    return item.type == JSONType.array ? item : parseJSON("[]");
}
