module wheatley.server.queue.session_queue_projection;

import wheatley.common.api.session : SessionKey;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.presentation.store : appendPresentation;
import wheatley.server.presentation.store : presentationEntriesAfter;
import wheatley.server.queue.session_queue :
    QueueItemState,
    QueueMutation,
    queueMutationFromJson,
    queueMutationJson;

/** Publishes a lightweight change marker after the queue file is durable.
    Missing a marker never invalidates the queue: reconnecting clients read the
    canonical snapshot. */
bool projectQueueMutation(
    HistoryStore store,
    SessionKey session,
    QueueMutation mutation,
)
{
    if (!mutation.changed) return true;
    try {
        appendPresentation(
            store.requireSession(session),
            "queue",
            "lifecycle",
            "",
            mutation.item.id,
            queueMutationJson(mutation),
        );
        return true;
    } catch (Exception) {
        // The queue snapshot is authoritative and will repair this projection
        // on reconnect or the next successful session change notification.
        return false;
    }
}

/** Recovers an idempotent terminal response after the active queue has
    compacted the item. The presentation journal is already the durable client
    projection and therefore the canonical tombstone for this narrow retry. */
bool findProjectedQueueMutation(
    string sessionRoot,
    string itemId,
    QueueItemState state,
    out QueueMutation mutation,
)
{
    auto entries = presentationEntriesAfter(sessionRoot, 0);
    foreach_reverse (entry; entries) {
        if (entry.source != "queue" || entry.kind != "lifecycle" || entry.itemId != itemId)
            continue;
        try {
            auto candidate = queueMutationFromJson(entry.payloadJson);
            if (candidate.item.state != state) continue;
            candidate.changed = false;
            mutation = candidate;
            return true;
        } catch (Exception) {
        }
    }
    return false;
}
