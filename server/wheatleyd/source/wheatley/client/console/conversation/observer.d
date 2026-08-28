module wheatley.client.console.conversation.observer;

import core.thread : Thread;
import core.time : dur;

import std.json : parseJSON;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.client.console.background_worker : ConsoleBackgroundWorker;
import wheatley.client.console.conversation.local_submissions : isLocalSubmission;
import wheatley.client.console.ui.output :
    writeError,
    writeMutedTurn,
    writeNotice,
    writeTimedTurn,
    writeTurn;
import wheatley.client.console.ui.turn_metrics :
    compactConsoleDuration,
    consoleTurnMetricsText;
import wheatley.common.api.conversation_events : conversationEventFromJson;
import wheatley.common.conversation.events : ConversationEvent, ConversationEventKind;
import wheatley.common.json.read : Json;

ConsoleBackgroundWorker startConsoleConversationObserver(
    string apiBase,
    string profileId,
    string sessionId,
    string deviceId,
)
{
    return new ConsoleBackgroundWorker("wheatley-conversation-observer", (stop) {
        auto client = new ConsoleApiClient(apiBase);
        auto observer = new ConsoleConversationObserver(deviceId, profileId);
        long cursor;
        bool initialized;
        while (!stop.stopping()) {
            try {
                auto snapshot = Json.parse(client.sessionPresentation(profileId, sessionId));
                if (initialized) observer.replay(snapshot, cursor);
                cursor = snapshot.nonNegativeInt("watermark");
                initialized = true;
                observer.replayQueue(Json.parse(client.sessionQueue(profileId, sessionId)));
                client.streamSessionTurnEvents(profileId, sessionId, cursor, (dataJson) {
                    observer.apply(conversationEventFromJson(parseJSON(dataJson)));
                }, (changeJson) {
                    try {
                        observer.replayQueueMutation(Json.parse(changeJson));
                        observer.replayQueue(Json.parse(client.sessionQueue(profileId, sessionId)));
                    } catch (Throwable error) {
                        if (!stop.stopping()) writeError("conversation queue: " ~ error.msg);
                    }
                }, () => !stop.stopping());
            } catch (Throwable error) {
                if (stop.stopping()) return;
                writeError("conversation observer: " ~ error.msg);
                Thread.sleep(dur!"msecs"(1_000));
            }
        }
    });
}

private struct ExternalTurn
{
    string submissionId;
    string userText;
    bool started;
    bool cancelled;
}

private final class ConsoleConversationObserver
{
    private string deviceId;
    private string assistantName;
    private ExternalTurn[string] externalTurns;
    private ulong[string] sequences;
    private string[string] queueStates;
    private bool[string] announcedQueueItems;
    private ulong queueRevision;

    this(string deviceId, string assistantName)
    {
        this.deviceId = deviceId;
        this.assistantName = assistantName;
    }

    void replay(Json snapshot, long afterSequence)
    {
        foreach (entryValue; snapshot.array("entries").value.array) {
            auto entry = Json.object(entryValue);
            if (entry.positiveInt("sequence") <= afterSequence) continue;
            if (entry.text("source") == "queue") {
                replayQueueMutation(entry.object("payload"));
                continue;
            }
            if (entry.text("source") != "pi") continue;
            try {
                apply(conversationEventFromJson(entry.object("payload").value));
            } catch (Exception) {
                // Historical ordering markers deliberately have no live event payload.
            }
        }
    }

    void replayQueue(Json snapshot)
    {
        auto revision = snapshot.nonNegativeInt("revision");
        if (revision <= queueRevision) return;
        queueRevision = revision;
        foreach (itemValue; snapshot.array("items").value.array)
            applyQueueItem(Json.object(itemValue));
    }

    void replayQueueMutation(Json mutation)
    {
        auto item = mutation.opt.object("item");
        if (item.isNull) return;
        auto revision = mutation.nonNegativeInt("revision");
        if (revision < queueRevision) return;
        queueRevision = revision;
        applyQueueItem(item.get);
    }

    private void applyQueueItem(Json item)
    {
        auto id = item.nonEmpty("id");
        auto state = item.nonEmpty("state");
        auto previous = queueStates.get(id, "");
        queueStates[id] = state;
        if (previous.length == 0
            && item.text("device_id") != deviceId
            && (state == "preparing" || state == "ready")) {
            auto text = item.text("text");
            if (!text.length) {
                switch (item.text("language")) {
                    case "sk": text = "Hlasová správa…"; break;
                    case "de": text = "Sprachnachricht…"; break;
                    default: text = "Voice message…"; break;
                }
            }
            if (item.text("kind") == "scheduled")
                writeNotice("Scheduled task queued: " ~ text, "gray");
            else
                writeTurn("queued", text, "gray");
            announcedQueueItems[id] = true;
        }
        if (state == "cancelled" && previous != "cancelled") {
            auto text = item.text("text");
            writeNotice(
                "Queued message cancelled" ~ (text.length ? ": " ~ text : "."),
                "gray",
            );
            foreach (ref turn; externalTurns) {
                if (turn.submissionId != id) continue;
                turn.cancelled = true;
            }
        }

        if ((state == "failed" || state == "interrupted") && previous != state) {
            auto text = item.text("text");
            auto detail = item.text("failure");
            auto label = state == "interrupted"
                ? "Queued message interrupted"
                : "Queued message failed";
            writeNotice(
                label
                    ~ (text.length ? ": " ~ text : ".")
                    ~ (detail.length ? " (" ~ detail ~ ")" : ""),
                "red",
            );
        }
    }

    void apply(ConversationEvent event)
    {
        auto previous = sequences.get(event.turnId, 0);
        if (event.sequence <= previous) return;
        sequences[event.turnId] = event.sequence;

        if (event.kind == ConversationEventKind.status
            && event.status.code == "conversation_accepted") {
            auto details = Json.parse(event.status.detailsJson);
            auto submissionId = details.text("submission_id");
            if (details.text("device_id") == deviceId && isLocalSubmission(submissionId)) return;
            auto cancelled = queueStates.get(submissionId, "") == "cancelled";
            externalTurns[event.turnId] = ExternalTurn(
                submissionId,
                details.text("user_text"),
                false,
                cancelled,
            );
            if (!cancelled && !announcedQueueItems.get(submissionId, false)) {
                writeTurn("queued", details.text("user_text"), "gray");
                announcedQueueItems[submissionId] = true;
            }
            return;
        }

        auto turn = event.turnId in externalTurns;
        if (turn is null || turn.cancelled) return;
        final switch (event.kind) {
            case ConversationEventKind.status:
                if (event.status.code == "api_text_pi_started" && !turn.started) {
                    turn.started = true;
                    writeNotice("Pi started queued message: " ~ turn.userText, "green");
                }
                break;
            case ConversationEventKind.assistantDelta:
            case ConversationEventKind.reasoning:
            case ConversationEventKind.artifact:
                break;
            case ConversationEventKind.tool:
                if (event.tool.stage == "start" && event.tool.message.length)
                    writeTurn(event.tool.displayPrefix, event.tool.message, "cyan");
                break;
            case ConversationEventKind.completed:
                auto response = event.completed.turn;
                writeTimedTurn(
                    assistantName,
                    response.assistantText,
                    response.metrics.durationMs < 0
                        ? "" : compactConsoleDuration(response.metrics.durationMs),
                );
                auto metricsText = consoleTurnMetricsText(response.metrics, response.language);
                if (metricsText.length) writeMutedTurn(assistantName, metricsText);
                externalTurns.remove(event.turnId);
                break;
            case ConversationEventKind.failed:
                writeError(assistantName ~ ": " ~ event.failed.message);
                externalTurns.remove(event.turnId);
                break;
        }
    }
}
