module wheatley.server.queue.session_queue_migration;

import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists;
import std.json : JSONType, parseJSON;
import std.string : strip;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.reasoning : reasoningModeText;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.types : StoredTurn;
import wheatley.server.queue.session_queue :
    QueueItem,
    QueueItemState,
    SessionQueue,
    SessionQueueStore;

struct SessionQueueMigrationReport
{
    ulong sessions;
    ulong published;
    ulong alreadyCanonical;
    ulong items;
    string[] publishedSessions;

    string summary() const
    {
        import std.conv : to;
        return "sessions=" ~ sessions.to!string
            ~ " published=" ~ published.to!string
            ~ " items=" ~ items.to!string;
    }
}

/** Converts the currently supported history representation into the queue's
    first canonical snapshot. It only adds queue state; existing session and
    turn bytes are left untouched as the migration recovery source. */
final class SessionQueueMigrator
{
    private HistoryStore store;

    this(HistoryStore store)
    {
        enforce(store !is null, "History store is required for queue migration");
        this.store = store;
    }

    SessionQueueMigrationReport migrateAll(bool dryRun = false)
    {
        SessionQueueMigrationReport report;
        foreach (session; store.sessionKeys()) {
            ++report.sessions;
            auto queueStore = store.sessionQueue(session);
            if (exists(queueStore.path)) {
                // snapshot validates the already-canonical file and makes a
                // corrupt queue an exact startup error rather than a fallback.
                queueStore.snapshot();
                if (!dryRun) queueStore.removeLegacyMigratedHistory();
                ++report.alreadyCanonical;
                continue;
            }

            auto queue = migrateSession(session, store.sessionTurns(session));
            report.items += cast(ulong) queue.items.length;
            if (dryRun) continue;
            if (queueStore.publishIfAbsent(queue)) {
                ++report.published;
                report.publishedSessions ~= session.value;
            } else {
                // Another explicit migrator won the lock. Validate its result
                // before treating the session as canonical.
                queueStore.snapshot();
                ++report.alreadyCanonical;
            }
        }
        return report;
    }
}

SessionQueue migrateSession(SessionKey session, StoredTurn[] turns)
{
    QueueItem[] items;
    ulong sequence = 1;
    foreach (turn; turns) {
        if (turn.source == "memory_consolidation") continue;
        enforce(turn.id.length, "Queue migration found a turn without an ID in " ~ session.value);
        auto status = turn.status.length
            ? turn.status
            : turn.completedAt.length ? "completed" : "pending";
        // Terminal history already owns its result. The queue is an execution
        // concern, so migration carries only work which was still active.
        if (status == "completed" || status == "failed" || status == "stopped")
            continue;
        auto item = migratedQueueItem(session, turn, status, sequence++);
        foreach (existing; items)
            enforce(existing.id != item.id,
                "Queue migration found duplicate submission ID " ~ item.id
                    ~ " in " ~ session.value);
        items ~= item;
    }
    return SessionQueue.migrated(session.sessionId, items);
}

private QueueItem migratedQueueItem(
    SessionKey session,
    StoredTurn turn,
    string status,
    ulong sequence,
)
{
    QueueItem item;
    item.id = turn.submissionId.length ? turn.submissionId : "migrated-" ~ turn.id;
    item.sessionId = session.sessionId;
    item.sequence = sequence;
    item.kind = turn.source == "scheduled_task" ? "scheduled" : "user";
    item.source = turn.source.length ? turn.source : "migrated";
    item.deviceId = turn.deviceId;
    item.submittedAt = turn.startedAt;
    item.text = turn.userText;
    item.model = turn.modelName;
    item.reasoningMode = reasoningModeText(turn.reasoningMode);
    item.language = turn.language;
    item.loadMemory = migratedLoadMemory(turn.submissionJson);
    item.fingerprint = migrationFingerprint(turn);
    item.artifactReference = turn.hasUserAudio ? "turn:" ~ turn.id ~ ":user-audio" : "";

    switch (status) {
        case "running":
            item.state = QueueItemState.interrupted;
            item.executionId = turn.executionId;
            item.failure = "Conversation execution was interrupted during queue migration.";
            break;
        case "pending":
            if (turn.userText.strip.length || turn.hasUserImage || turn.hasUserAudio) {
                item.state = QueueItemState.ready;
            } else {
                item.state = QueueItemState.failed;
                item.failure = "Migrated pending turn has no durable user input.";
            }
            break;
        default:
            enforce(false, "Queue migration found unsupported turn status " ~ status
                ~ " for " ~ turn.id);
    }
    return item;
}

private string migrationFingerprint(StoredTurn turn)
{
    auto source = turn.submissionJson.length ? turn.submissionJson : (
        turn.id ~ "\n" ~ turn.userText ~ "\n" ~ turn.source ~ "\n"
            ~ turn.startedAt ~ "\n" ~ turn.modelName ~ "\n"
            ~ reasoningModeText(turn.reasoningMode) ~ "\n" ~ turn.language
    );
    return "migrated:" ~ toHexString!(LetterCase.lower)(sha256Of(cast(ubyte[]) source)).idup;
}

private bool migratedLoadMemory(string submissionJson)
{
    if (!submissionJson.length) return false;
    try {
        auto payload = parseJSON(submissionJson);
        auto field = "load_memory" in payload.object;
        return field !is null && field.type == JSONType.true_;
    } catch (Exception) {
        return false;
    }
}

unittest
{
    import std.exception : assertThrown;
    import wheatley.common.api.reasoning : ReasoningMode;

    auto session = SessionKey("tester", "2026/08/21/12_00_00");
    auto first = StoredTurn(
        "turn-1", "tester", "browser", "text", "completed",
        "2026-08-21T12:00:00Z", "2026-08-21T12:00:01Z", "pi:test", "en",
        ReasoningMode.off, "one", "answer", "", false, false, -1, null,
        "submission-1", "execution-1", "{}", false, "", "", 0, "", false, "{}",
    );
    auto second = first;
    second.id = "turn-2";
    second.submissionId = "submission-2";
    second.status = "running";
    second.executionId = "execution-2";
    auto queue = migrateSession(session, [first, second]);
    assert(queue.items.length == 1);
    assert(queue.items[0].state == QueueItemState.interrupted);
    assert(queue.items[0].executionId == "execution-2");

    auto bad = first;
    bad.status = "unknown";
    assertThrown(migrateSession(session, [bad]));
}
