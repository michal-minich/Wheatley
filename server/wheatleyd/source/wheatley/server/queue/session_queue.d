module wheatley.server.queue.session_queue;

import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText, remove, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.string : strip;
import std.uuid : randomUUID;

import wheatley.common.json.object :
    jsonArrayRaw,
    jsonBoolField,
    jsonObject,
    jsonRawField,
    jsonStringField,
    jsonUlongField;
import wheatley.common.json.read : Json;
import wheatley.server.presentation.store : withSessionStorageLock;

enum queueSchemaVersion = 1UL;

enum QueueItemState
{
    preparing,
    ready,
    running,
    completed,
    failed,
    cancelled,
    interrupted,
}

string queueItemStateText(QueueItemState state)
{
    final switch (state) {
        case QueueItemState.preparing: return "preparing";
        case QueueItemState.ready: return "ready";
        case QueueItemState.running: return "running";
        case QueueItemState.completed: return "completed";
        case QueueItemState.failed: return "failed";
        case QueueItemState.cancelled: return "cancelled";
        case QueueItemState.interrupted: return "interrupted";
    }
}

QueueItemState parseQueueItemState(string value)
{
    enforce(
        ["preparing", "ready", "running", "completed", "failed", "cancelled", "interrupted"]
            .canFind(value),
        "Unknown session queue item state: " ~ value,
    );
    switch (value) {
        case "preparing": return QueueItemState.preparing;
        case "ready": return QueueItemState.ready;
        case "running": return QueueItemState.running;
        case "completed": return QueueItemState.completed;
        case "failed": return QueueItemState.failed;
        case "cancelled": return QueueItemState.cancelled;
        case "interrupted": return QueueItemState.interrupted;
        default: assert(0);
    }
}

struct QueueReservation
{
    string id;
    string sessionId;
    string kind = "user";
    string source;
    string deviceId;
    string submittedAt;
    string text;
    string model;
    string reasoningMode;
    string language;
    string artifactReference;
    string preparationSource;
    string fingerprint;
    bool ready;
    string preparationDeadlineAt;
    bool loadMemory;
}

struct QueueItem
{
    string id;
    string sessionId;
    ulong sequence;
    string kind;
    string source;
    string deviceId;
    string submittedAt;
    QueueItemState state;
    string text;
    string model;
    string reasoningMode;
    string language;
    string artifactReference;
    string preparationSource;
    string fingerprint;
    string executionId;
    string failure;
    string resultReference;
    string preparationStartedAt;
    string preparationProgressAt;
    string preparationDeadlineAt;
    bool loadMemory;
}

struct QueueMutation
{
    QueueItem item;
    ulong revision;
    bool changed;
}

/** One session's durable admission order and lifecycle invariant. */
final class SessionQueue
{
    private string sessionId_;
    private ulong revision_;
    private ulong nextSequence_ = 1;
    private QueueItem[] items_;

    this(string sessionId)
    {
        enforce(sessionId.length, "Session queue session ID is required");
        sessionId_ = sessionId;
    }

    /** Builds the first canonical snapshot for an already-readable session.
        Migration is the only caller; normal runtime mutations still go
        through the state-transition methods below. */
    static SessionQueue migrated(string sessionId, QueueItem[] items)
    {
        auto queue = new SessionQueue(sessionId);
        queue.items_ = items.dup;
        queue.nextSequence_ = cast(ulong) items.length + 1;
        queue.revision_ = items.length ? 1 : 0;
        queue.validate();
        return queue;
    }

    @property string sessionId() const { return sessionId_; }
    @property ulong revision() const { return revision_; }
    @property ulong nextSequence() const { return nextSequence_; }
    @property const(QueueItem)[] items() const { return items_; }

    QueueMutation reserve(QueueReservation request)
    {
        enforce(request.id.length, "Session queue item ID is required");
        enforce(request.sessionId == sessionId_, "Session queue session changed");
        enforce(request.kind == "user" || request.kind == "scheduled",
            "Session queue item kind is invalid");
        enforce(request.source.length, "Session queue item source is required");
        enforce(request.submittedAt.length, "Session queue submitted_at is required");
        enforce(request.fingerprint.length, "Session queue admission fingerprint is required");

        auto existing = find(request.id);
        if (existing !is null) {
            enforce(existing.fingerprint == request.fingerprint,
                "Session queue item ID was reused with different admission data");
            return QueueMutation(*existing, revision_, false);
        }

        QueueItem item;
        item.id = request.id;
        item.sessionId = request.sessionId;
        item.sequence = nextSequence_++;
        item.kind = request.kind;
        item.source = request.source;
        item.deviceId = request.deviceId;
        item.submittedAt = request.submittedAt;
        item.state = request.ready ? QueueItemState.ready : QueueItemState.preparing;
        item.text = request.text;
        item.model = request.model;
        item.reasoningMode = request.reasoningMode;
        item.language = request.language;
        item.artifactReference = request.artifactReference;
        item.preparationSource = request.preparationSource;
        item.fingerprint = request.fingerprint;
        item.loadMemory = request.loadMemory;
        if (!request.ready) {
            item.preparationStartedAt = request.submittedAt;
            item.preparationProgressAt = request.submittedAt;
            item.preparationDeadlineAt = request.preparationDeadlineAt;
        }
        items_ ~= item;
        revision_++;
        validate();
        return QueueMutation(item, revision_, true);
    }

    QueueMutation prepare(
        string id,
        string text,
        string artifactReference = "",
        string preparationSource = "",
        string effectiveReasoningMode = "",
    )
    {
        auto item = *require(id);
        if (item.state == QueueItemState.cancelled
            || item.state == QueueItemState.failed
            || item.state == QueueItemState.interrupted
            || item.state == QueueItemState.completed) {
            if (artifactReference.length && !item.artifactReference.length) {
                item.artifactReference = artifactReference;
                replace(item);
                revision_++;
                validate();
                return QueueMutation(item, revision_, true);
            }
            return QueueMutation(item, revision_, false);
        }
        enforce(item.state == QueueItemState.preparing || item.state == QueueItemState.ready,
            "Session queue item cannot be prepared from " ~ queueItemStateText(item.state));
        if (item.state == QueueItemState.ready) {
            enforce(item.text == text, "Session queue preparation changed item text");
            enforce(!effectiveReasoningMode.length
                || item.reasoningMode == effectiveReasoningMode,
                "Session queue preparation changed effective reasoning mode");
            return QueueMutation(item, revision_, false);
        }
        enforce(text.length || artifactReference.length,
            "Session queue preparation requires text or an artifact");
        item.text = text;
        if (artifactReference.length) item.artifactReference = artifactReference;
        if (preparationSource.length) item.preparationSource = preparationSource;
        if (effectiveReasoningMode.length) item.reasoningMode = effectiveReasoningMode;
        item.state = QueueItemState.ready;
        item.preparationStartedAt = "";
        item.preparationProgressAt = "";
        item.preparationDeadlineAt = "";
        replace(item);
        revision_++;
        validate();
        return QueueMutation(item, revision_, true);
    }

    QueueMutation claim(string id)
    {
        auto item = *require(id);
        if (item.state == QueueItemState.running)
            return QueueMutation(item, revision_, false);
        enforce(item.state == QueueItemState.ready,
            "Session queue item cannot be claimed from " ~ queueItemStateText(item.state));
        auto first = firstNonTerminal();
        enforce(first !is null && first.id == id,
            "Session queue item is blocked by an earlier non-terminal item");
        enforce(!hasRunning(), "Session queue already has a running item");
        item.state = QueueItemState.running;
        item.executionId = randomUUID().toString();
        replace(item);
        revision_++;
        validate();
        return QueueMutation(item, revision_, true);
    }

    QueueMutation claimNext()
    {
        auto first = firstNonTerminal();
        if (first is null || first.state != QueueItemState.ready || hasRunning())
            return QueueMutation(QueueItem(), revision_, false);
        return claim(first.id);
    }

    QueueMutation complete(string id, string resultReference = "")
    {
        return finish(id, QueueItemState.completed, "", resultReference);
    }

    QueueMutation fail(string id, string failure)
    {
        enforce(failure.length, "Session queue failure is required");
        return finish(id, QueueItemState.failed, failure, "");
    }

    QueueMutation cancel(string id)
    {
        auto item = *require(id);
        if (item.state == QueueItemState.cancelled)
            return QueueMutation(item, revision_, false);
        enforce(item.state == QueueItemState.preparing || item.state == QueueItemState.ready,
            "Only preparing or ready session queue items may be cancelled");
        item.state = QueueItemState.cancelled;
        replace(item);
        revision_++;
        validate();
        return QueueMutation(item, revision_, true);
    }

    QueueMutation interrupt(string id, string failure)
    {
        enforce(failure.length, "Session queue interruption reason is required");
        return finish(id, QueueItemState.interrupted, failure, "");
    }

    /** Records producer progress without changing queue position or state.
        A producer may also move its operation-specific deadline forward when
        it has received a new bounded progress milestone. */
    QueueMutation touchPreparation(
        string id,
        string progressAt,
        string deadlineAt = "",
    )
    {
        enforce(progressAt.length, "Preparation progress timestamp is required");
        auto item = *require(id);
        if (item.state != QueueItemState.preparing)
            return QueueMutation(item, revision_, false);
        auto nextDeadline = deadlineAt.length ? deadlineAt : item.preparationDeadlineAt;
        if (item.preparationProgressAt == progressAt
            && item.preparationDeadlineAt == nextDeadline)
            return QueueMutation(item, revision_, false);
        item.preparationProgressAt = progressAt;
        item.preparationDeadlineAt = nextDeadline;
        replace(item);
        revision_++;
        validate();
        return QueueMutation(item, revision_, true);
    }

    /** Fails only a preparing item with an explicit producer-owned deadline.
        The watchdog never guesses a timeout for an operation that did not
        publish one. */
    QueueMutation expirePreparation(string id, string at, string failure)
    {
        auto item = *require(id);
        if (item.state != QueueItemState.preparing || !item.preparationDeadlineAt.length)
            return QueueMutation(item, revision_, false);
        if (SysTime.fromISOExtString(at) < SysTime.fromISOExtString(item.preparationDeadlineAt))
            return QueueMutation(item, revision_, false);
        return fail(id, failure);
    }

    QueueItem[] migratedItems() const
    {
        return items_.dup;
    }

    QueueItem* find(string id)
    {
        foreach (ref item; items_) if (item.id == id) return &item;
        return null;
    }

    const(QueueItem)* find(string id) const
    {
        foreach (ref item; items_) if (item.id == id) return &item;
        return null;
    }

    void validate() const
    {
        enforce(sessionId_.length, "Session queue session ID is missing");
        ulong previousSequence;
        bool running;
        foreach (item; items_) {
            enforce(item.sessionId == sessionId_, "Session queue item session changed");
            enforce(item.sequence > previousSequence, "Session queue sequence is not increasing");
            previousSequence = item.sequence;
            enforce(item.id.length && item.fingerprint.length,
                "Session queue item identity is incomplete");
            if (item.state == QueueItemState.running) {
                enforce(!running, "Session queue has more than one running item");
                running = true;
                enforce(item.executionId.length, "Running queue item has no execution ID");
            }
            if (item.state != QueueItemState.running)
                enforce(!item.executionId.length || item.state == QueueItemState.interrupted,
                    "Non-running queue item has an execution ID");
        }
        enforce(nextSequence_ > previousSequence, "Session queue next sequence is invalid");
    }

    /** Removes the terminal prefix once no earlier item can still block it.
        Durable turn history owns completed results; cancelled preparation may
        be forgotten after its terminal mutation has been projected. */
    bool compactTerminalPrefix()
    {
        size_t terminalPrefix;
        foreach (item; items_) {
            if (!isTerminal(item.state)) break;
            terminalPrefix++;
        }
        if (!terminalPrefix) return false;
        items_ = items_[terminalPrefix .. $].dup;
        revision_++;
        validate();
        return true;
    }

    /** One-time correction for the first queue migration, which copied
        completed/failed history into the operational queue. Sequence values
        remain immutable; gaps are valid after compaction and migration. */
    bool removeLegacyMigratedHistory()
    {
        QueueItem[] kept;
        foreach (item; items_) {
            auto historical = item.fingerprint.startsWith("migrated:")
                && (item.state == QueueItemState.completed
                    || (item.state == QueueItemState.failed
                        && item.failure.startsWith("Migrated terminal Conversation status:")));
            if (!historical) kept ~= item;
        }
        if (kept.length == items_.length) return false;
        items_ = kept;
        revision_++;
        validate();
        return true;
    }

    string json() const
    {
        string[] encoded;
        foreach (item; items_) encoded ~= queueItemJson(item);
        return jsonObject([
            jsonUlongField("schema_version", queueSchemaVersion),
            jsonStringField("session_id", sessionId_),
            jsonUlongField("revision", revision_),
            jsonUlongField("next_sequence", nextSequence_),
            jsonRawField("items", "[" ~ joinJson(encoded) ~ "]"),
        ]);
    }

    static SessionQueue fromJson(string value)
    {
        auto root = Json.object(parseJSON(value), "queue");
        enforce(root.integer("schema_version", 1, cast(long) queueSchemaVersion)
            == cast(long) queueSchemaVersion, "Unsupported session queue schema");
        auto queue = new SessionQueue(root.nonEmpty("session_id"));
        queue.revision_ = root.integer("revision", 0).to!ulong;
        queue.nextSequence_ = root.integer("next_sequence", 1).to!ulong;
        foreach (itemJson; root.objects("items"))
            queue.items_ ~= queueItemFromJson(itemJson);
        queue.validate();
        return queue;
    }

private:
    QueueItem* firstNonTerminal()
    {
        foreach (ref item; items_) {
            if (item.state != QueueItemState.completed
                && item.state != QueueItemState.failed
                && item.state != QueueItemState.cancelled
                && item.state != QueueItemState.interrupted)
                return &item;
        }
        return null;
    }

    bool hasRunning() const
    {
        foreach (item; items_) if (item.state == QueueItemState.running) return true;
        return false;
    }

    QueueItem* require(string id)
    {
        auto item = find(id);
        enforce(item !is null, "Session queue item not found: " ~ id);
        return item;
    }

    QueueMutation finish(string id, QueueItemState state, string failure, string resultReference)
    {
        auto item = *require(id);
        if (item.state == state)
            return QueueMutation(item, revision_, false);
        if (state == QueueItemState.failed) {
            enforce(item.state == QueueItemState.preparing
                || item.state == QueueItemState.ready
                || item.state == QueueItemState.running,
                "Session queue item cannot fail from " ~ queueItemStateText(item.state));
        } else {
            enforce(item.state == QueueItemState.running,
                "Session queue item cannot finish from " ~ queueItemStateText(item.state));
        }
        item.state = state;
        if (state != QueueItemState.interrupted) item.executionId = "";
        item.failure = failure;
        item.resultReference = resultReference;
        replace(item);
        revision_++;
        validate();
        return QueueMutation(item, revision_, true);
    }

    void replace(QueueItem item)
    {
        foreach (ref candidate; items_) {
            if (candidate.id == item.id) {
                candidate = item;
                return;
            }
        }
        assert(0);
    }
}

/** Atomic filesystem adapter for one session queue. */
final class SessionQueueStore
{
    private string sessionRoot_;
    private string sessionId_;

    this(string sessionRoot, string sessionId)
    {
        enforce(sessionRoot.length && sessionId.length, "Session queue store location is required");
        sessionRoot_ = sessionRoot;
        sessionId_ = sessionId;
    }

    string path() const { return buildPath(sessionRoot_, "queue.json"); }

    SessionQueue snapshot()
    {
        SessionQueue result;
        withSessionStorageLock(sessionRoot_, {
            result = loadUnlocked();
        });
        return result;
    }

    QueueMutation reserve(QueueReservation request)
    {
        return mutate((queue) { return queue.reserve(request); });
    }

    QueueMutation prepare(
        string id,
        string text,
        string artifactReference = "",
        string preparationSource = "",
        string effectiveReasoningMode = "",
    )
    {
        return mutate((queue) {
            return queue.prepare(
                id,
                text,
                artifactReference,
                preparationSource,
                effectiveReasoningMode,
            );
        });
    }

    QueueMutation claim(string id)
    {
        return mutate((queue) { return queue.claim(id); });
    }

    QueueMutation claimNext()
    {
        return mutate((queue) { return queue.claimNext(); });
    }

    QueueMutation complete(string id, string resultReference = "")
    {
        return mutate((queue) { return queue.complete(id, resultReference); });
    }

    QueueMutation fail(string id, string failure)
    {
        return mutate((queue) { return queue.fail(id, failure); });
    }

    QueueMutation cancel(string id)
    {
        return mutate((queue) { return queue.cancel(id); });
    }

    QueueMutation interrupt(string id, string failure)
    {
        return mutate((queue) { return queue.interrupt(id, failure); });
    }

    QueueMutation touchPreparation(
        string id,
        string progressAt,
        string deadlineAt = "",
    )
    {
        return mutate((queue) {
            return queue.touchPreparation(id, progressAt, deadlineAt);
        });
    }

    QueueMutation expirePreparation(string id, string at, string failure)
    {
        return mutate((queue) {
            return queue.expirePreparation(id, at, failure);
        });
    }

    bool compactTerminalPrefix()
    {
        bool changed;
        withSessionStorageLock(sessionRoot_, {
            auto queue = loadUnlocked();
            changed = queue.compactTerminalPrefix();
            if (changed) writeUnlocked(queue.json());
        });
        return changed;
    }

    bool removeLegacyMigratedHistory()
    {
        bool changed;
        withSessionStorageLock(sessionRoot_, {
            auto queue = loadUnlocked();
            changed = queue.removeLegacyMigratedHistory();
            if (changed) writeUnlocked(queue.json());
        });
        return changed;
    }

    /** Publishes the first queue file without replacing an existing canonical
        file. The session lock makes discovery and publication one cutover
        decision for competing startup/migration processes. */
    bool publishIfAbsent(SessionQueue queue)
    {
        enforce(queue !is null, "Migrated session queue is required");
        enforce(queue.sessionId == sessionId_, "Migrated queue session changed");
        bool published;
        withSessionStorageLock(sessionRoot_, {
            if (exists(path())) {
                auto existing = loadUnlocked();
                enforce(existing.sessionId == sessionId_,
                    "Existing session queue session ID changed");
            } else {
                writeUnlocked(queue.json());
                published = true;
            }
        });
        return published;
    }

private:
    QueueMutation mutate(scope QueueMutation delegate(SessionQueue) operation)
    {
        QueueMutation result;
        withSessionStorageLock(sessionRoot_, {
            auto queue = loadUnlocked();
            result = operation(queue);
            if (result.changed) writeUnlocked(queue.json());
        });
        return result;
    }

    SessionQueue loadUnlocked()
    {
        if (!exists(path())) return new SessionQueue(sessionId_);
        auto queue = SessionQueue.fromJson(readText(path()));
        enforce(queue.sessionId == sessionId_, "Session queue session ID changed");
        return queue;
    }

    void writeUnlocked(string value)
    {
        mkdirRecurse(sessionRoot_);
        auto temporary = path() ~ "." ~ randomUUID().toString() ~ ".tmp";
        scope(exit) if (exists(temporary)) remove(temporary);
        write(temporary, value ~ "\n");
        rename(temporary, path());
    }
}

private bool isTerminal(QueueItemState state)
{
    return state == QueueItemState.completed
        || state == QueueItemState.failed
        || state == QueueItemState.cancelled
        || state == QueueItemState.interrupted;
}

string queueItemJson(QueueItem item)
{
    return jsonObject([
        jsonStringField("id", item.id),
        jsonStringField("session_id", item.sessionId),
        jsonUlongField("sequence", item.sequence),
        jsonStringField("kind", item.kind),
        jsonStringField("source", item.source),
        jsonStringField("device_id", item.deviceId),
        jsonStringField("submitted_at", item.submittedAt),
        jsonStringField("state", queueItemStateText(item.state)),
        jsonStringField("text", item.text),
        jsonStringField("model", item.model),
        jsonStringField("reasoning_mode", item.reasoningMode),
        jsonStringField("language", item.language),
        jsonStringField("artifact_reference", item.artifactReference),
        jsonStringField("preparation_source", item.preparationSource),
        jsonStringField("fingerprint", item.fingerprint),
        jsonStringField("execution_id", item.executionId),
        jsonStringField("failure", item.failure),
        jsonStringField("result_reference", item.resultReference),
        jsonStringField("preparation_started_at", item.preparationStartedAt),
        jsonStringField("preparation_progress_at", item.preparationProgressAt),
        jsonStringField("preparation_deadline_at", item.preparationDeadlineAt),
        jsonBoolField("load_memory", item.loadMemory),
    ]);
}

QueueItem queueItemFromJson(Json itemJson)
{
    QueueItem item;
    item.id = itemJson.nonEmpty("id");
    item.sessionId = itemJson.nonEmpty("session_id");
    item.sequence = itemJson.integer("sequence", 1).to!ulong;
    item.kind = itemJson.nonEmpty("kind");
    item.source = itemJson.nonEmpty("source");
    item.deviceId = itemJson.text("device_id");
    item.submittedAt = itemJson.nonEmpty("submitted_at");
    item.state = parseQueueItemState(itemJson.nonEmpty("state"));
    item.text = itemJson.text("text");
    item.model = itemJson.text("model");
    item.reasoningMode = itemJson.text("reasoning_mode");
    item.language = itemJson.text("language");
    item.artifactReference = itemJson.text("artifact_reference");
    item.preparationSource = itemJson.text("preparation_source");
    item.fingerprint = itemJson.nonEmpty("fingerprint");
    item.executionId = itemJson.text("execution_id");
    item.failure = itemJson.text("failure");
    item.resultReference = itemJson.text("result_reference");
    item.preparationStartedAt = itemJson.text("preparation_started_at");
    item.preparationProgressAt = itemJson.text("preparation_progress_at");
    item.preparationDeadlineAt = itemJson.text("preparation_deadline_at");
    auto loadMemory = itemJson.opt.boolean("load_memory");
    item.loadMemory = !loadMemory.isNull && loadMemory.get;
    return item;
}

string queueReservationJson(QueueReservation reservation)
{
    return jsonObject([
        jsonStringField("id", reservation.id),
        jsonStringField("session_id", reservation.sessionId),
        jsonStringField("kind", reservation.kind),
        jsonStringField("source", reservation.source),
        jsonStringField("device_id", reservation.deviceId),
        jsonStringField("submitted_at", reservation.submittedAt),
        jsonStringField("text", reservation.text),
        jsonStringField("model", reservation.model),
        jsonStringField("reasoning_mode", reservation.reasoningMode),
        jsonStringField("language", reservation.language),
        jsonStringField("artifact_reference", reservation.artifactReference),
        jsonStringField("preparation_source", reservation.preparationSource),
        jsonStringField("fingerprint", reservation.fingerprint),
        jsonBoolField("ready", reservation.ready),
        jsonStringField("preparation_deadline_at", reservation.preparationDeadlineAt),
        jsonBoolField("load_memory", reservation.loadMemory),
    ]);
}

QueueReservation queueReservationFromJson(string value)
{
    auto json = Json.object(parseJSON(value), "queue reservation");
    return QueueReservation(
        json.nonEmpty("id"),
        json.nonEmpty("session_id"),
        json.nonEmpty("kind"),
        json.nonEmpty("source"),
        json.text("device_id"),
        json.nonEmpty("submitted_at"),
        json.text("text"),
        json.text("model"),
        json.text("reasoning_mode"),
        json.text("language"),
        json.text("artifact_reference"),
        json.text("preparation_source"),
        json.nonEmpty("fingerprint"),
        json.boolean("ready"),
        json.text("preparation_deadline_at"),
        json.boolean("load_memory"),
    );
}

string queueMutationJson(QueueMutation mutation)
{
    return jsonObject([
        jsonStringField("session_id", mutation.item.sessionId),
        jsonUlongField("revision", mutation.revision),
        jsonBoolField("changed", mutation.changed),
        jsonRawField("item", queueItemJson(mutation.item)),
    ]);
}

QueueMutation queueMutationFromJson(string value)
{
    auto json = Json.object(parseJSON(value), "queue mutation");
    return QueueMutation(
        queueItemFromJson(json.object("item")),
        json.integer("revision", 0).to!ulong,
        json.boolean("changed"),
    );
}

private string joinJson(string[] values)
{
    string result;
    foreach (index, value; values) {
        if (index) result ~= ",";
        result ~= value;
    }
    return result;
}

unittest
{
    import std.exception : assertThrown;
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto reservation = QueueReservation(
        "item-1", "session-1", "user", "text", "browser", "2026-08-21T12:00:00Z",
        "hello", "pi:test", "off", "en", "", "", "fingerprint-1", true,
    );
    auto queue = new SessionQueue("session-1");
    auto first = queue.reserve(reservation);
    assert(first.changed && first.item.sequence == 1 && first.revision == 1);
    auto retry = queue.reserve(reservation);
    assert(!retry.changed && retry.item.id == "item-1" && retry.revision == 1);
    assertThrown(queue.reserve(QueueReservation(
        "item-1", "session-1", "user", "text", "browser", "2026-08-21T12:00:00Z",
        "different", "pi:test", "off", "en", "", "", "fingerprint-2", true,
    )));
    auto claimed = queue.claim("item-1");
    assert(claimed.item.state == QueueItemState.running);
    assert(queue.complete("item-1").item.state == QueueItemState.completed);
    assert(!queue.complete("item-1").changed);
    assert(queueReservationFromJson(queueReservationJson(reservation)) == reservation);
    auto roundTrip = queueMutationFromJson(queueMutationJson(first));
    assert(roundTrip.item == first.item && roundTrip.revision == first.revision);
    assert(roundTrip.changed == first.changed);
}

unittest
{
    auto queue = new SessionQueue("session-preparation-watchdog");
    auto reserved = queue.reserve(QueueReservation(
        "voice-watch", "session-preparation-watchdog", "user", "voice", "mic",
        "2026-08-21T12:00:00Z", "", "pi:test", "off", "en", "audio", "audio",
        "watch-fingerprint", false, "2026-08-21T12:00:05Z",
    ));
    assert(reserved.item.preparationStartedAt == "2026-08-21T12:00:00Z");
    assert(!queue.expirePreparation(
        "voice-watch", "2026-08-21T12:00:04Z", "late",
    ).changed);
    auto touched = queue.touchPreparation(
        "voice-watch",
        "2026-08-21T12:00:04Z",
        "2026-08-21T12:00:10Z",
    );
    assert(touched.changed && touched.item.preparationProgressAt == "2026-08-21T12:00:04Z");
    assert(!queue.expirePreparation(
        "voice-watch", "2026-08-21T12:00:09Z", "late",
    ).changed);
    auto expired = queue.expirePreparation(
        "voice-watch", "2026-08-21T12:00:10Z", "preparation deadline elapsed",
    );
    assert(expired.changed && expired.item.state == QueueItemState.failed);
}

unittest
{
    auto queue = new SessionQueue("session-failure");
    queue.reserve(QueueReservation(
        "preparing-1", "session-failure", "user", "voice", "mic",
        "2026-08-21T12:00:00Z", "", "pi:test", "off", "en", "audio-1", "audio-1",
        "fingerprint-failure", false,
    ));
    auto failed = queue.fail("preparing-1", "Preparation was interrupted.");
    assert(failed.changed && failed.item.state == QueueItemState.failed);
    assert(!queue.fail("preparing-1", "Preparation was interrupted.").changed);
}

unittest
{
    import std.exception : assertThrown;
    auto queue = new SessionQueue("session-2");
    auto preparing = queue.reserve(QueueReservation(
        "voice-1", "session-2", "user", "voice", "mic", "2026-08-21T12:00:00Z",
        "", "pi:test", "off", "en", "audio-1", "audio-1", "voice-fingerprint", false,
    ));
    auto later = queue.reserve(QueueReservation(
        "text-2", "session-2", "user", "text", "browser", "2026-08-21T12:01:00Z",
        "later", "pi:test", "off", "en", "", "", "text-fingerprint", true,
    ));
    assert(preparing.item.sequence == 1 && later.item.sequence == 2);
    assert(!queue.claimNext().changed);
    auto prepared = queue.prepare("voice-1", "think about the first", "", "", "xhigh");
    assert(prepared.item.state == QueueItemState.ready);
    assert(prepared.item.reasoningMode == "xhigh");
    assert(prepared.item.fingerprint == "voice-fingerprint");
    assert(!queue.prepare("voice-1", "think about the first", "", "", "xhigh").changed);
    assert(queue.claimNext().item.id == "voice-1");
    assertThrown(queue.cancel("voice-1"));
    assert(queue.complete("voice-1").item.state == QueueItemState.completed);
    assert(queue.claimNext().item.id == "text-2");
    auto cancelled = new SessionQueue("session-3");
    cancelled.reserve(QueueReservation(
        "voice-3", "session-3", "user", "voice", "mic", "2026-08-21T12:00:00Z",
        "", "pi:test", "off", "en", "audio-3", "audio-3", "voice-fingerprint", false,
    ));
    assert(cancelled.cancel("voice-3").item.state == QueueItemState.cancelled);
    assert(!cancelled.prepare("voice-3", "late result").changed);
}

unittest
{
    import std.exception : assertThrown;
    import std.file : exists, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-session-queue-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto store = new SessionQueueStore(root, "session-store");
    auto reservation = QueueReservation(
        "item-store", "session-store", "user", "text", "browser", "2026-08-21T12:00:00Z",
        "hello", "pi:test", "off", "en", "", "", "fingerprint-store", true, "", true,
    );
    assert(store.reserve(reservation).revision == 1);
    assert(store.snapshot().items.length == 1);
    auto reopened = new SessionQueueStore(root, "session-store");
    assert(reopened.snapshot().items[0].id == "item-store");
    assert(reopened.snapshot().items[0].loadMemory);
    auto before = readText(reopened.path());
    assertThrown(reopened.cancel("missing"));
    assert(readText(reopened.path()) == before);
    reopened.claim("item-store");
    auto completed = reopened.complete("item-store", "turn:item-store");
    assert(completed.item.state == QueueItemState.completed);
    assert(completed.revision == 3);
    assert(reopened.compactTerminalPrefix());
    auto compacted = reopened.snapshot();
    assert(compacted.items.length == 0);
    assert(compacted.nextSequence == 2);
}
