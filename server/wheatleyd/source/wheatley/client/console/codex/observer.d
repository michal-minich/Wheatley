module wheatley.client.console.codex.observer;

import core.thread : Thread;
import core.time : dur;

import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.client.console.background_worker : ConsoleBackgroundWorker;
import wheatley.client.console.ui.output : writeError, writeNotice, writeTurn;
import wheatley.common.json.read : Json;
import wheatley.server.codex.store : liveEventFromJson;
import wheatley.server.codex.types : CodexLiveEvent;

ConsoleBackgroundWorker startConsoleCodexObserver(
    string apiBase,
    string profileId,
    string sessionId,
)
{
    return new ConsoleBackgroundWorker("wheatley-codex-observer", (stop) {
        auto client = new ConsoleApiClient(apiBase);
        long cursor;
        try {
            auto snapshot = Json.parse(client.sessionPresentation(profileId, sessionId));
            foreach (entryValue; snapshot.array("entries").value.array) {
                auto entry = Json.object(entryValue);
                cursor = entry.positiveInt("sequence");
                if (entry.text("source") == "pi" && entry.text("kind") == "compaction") {
                    renderCompaction(entry.object("payload"));
                    continue;
                }
                if (entry.text("source") != "codex") continue;
                auto payload = entry.object("payload").value;
                payload["sequence"] = JSONValue(cursor);
                render(liveEventFromJson(payload));
            }
            cursor = snapshot.nonNegativeInt("watermark");
        } catch (Throwable error) {
            writeError("codex history: " ~ error.msg);
        }

        while (!stop.stopping()) {
            try {
                client.streamCodexEvents(profileId, sessionId, cursor, (dataJson) {
                    auto event = liveEventFromJson(parseJSON(dataJson));
                    cursor = event.sequence;
                    render(event);
                }, () => !stop.stopping());
            } catch (Throwable error) {
                if (stop.stopping()) return;
                writeError("codex observer: " ~ error.msg);
                Thread.sleep(dur!"msecs"(1_000));
            }
        }
    });
}

private void renderCompaction(Json event)
{
    auto status = event.text("status");
    auto durationMs = event.nonNegativeInt("duration_ms");
    auto seconds = (durationMs + 500) / 1_000;
    auto duration = seconds < 60
        ? seconds.to!string ~ " s"
        : (seconds / 60).to!string ~ " min " ~ (seconds % 60).to!string ~ " s";
    auto label = status == "completed" ? "Context compacted"
        : status == "failed" ? "Context compaction failed"
        : "Context compaction " ~ status;
    writeNotice(label ~ " · " ~ duration, status == "failed" ? "red" : "cyan");
}

private void render(CodexLiveEvent event)
{
    final switch (event.kind) {
        case "reasoning_summary":
            if (event.operation == "delta" && event.text.strip.length)
                writeTurn("codex", event.text.strip, "light_blue");
            break;
        case "tool":
            if (event.operation == "start")
                writeNotice("codex> " ~ event.name ~ ": " ~ event.text, "cyan");
            else if (event.operation == "finish")
                writeNotice("codex> " ~ event.name ~ " " ~ event.status, "cyan");
            break;
        case "final":
            writeTurn("codex", event.text, "light_blue");
            break;
        case "error":
            writeError("codex: " ~ event.text);
            break;
        case "steer":
            break;
    }
}
