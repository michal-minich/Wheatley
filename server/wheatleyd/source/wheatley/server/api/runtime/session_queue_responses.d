module wheatley.server.api.runtime.session_queue_responses;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.common.api.session : SessionKey;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.json.read : Json;
import wheatley.server.api.http.json_response : writeError, writeJson;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.conversation.port : ConversationPort;
import wheatley.server.queue.session_queue :
    QueueItemState,
    QueueMutation,
    queueMutationJson,
    queueReservationFromJson;
import wheatley.server.queue.session_queue_projection :
    findProjectedQueueMutation,
    projectQueueMutation;
import wheatley.server.api.http.request_params : queryParam;

void sessionQueueResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ConversationPort conversations,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto sessionId = queryParam(req, "session_id");
        if (!sessionId.length) sessionId = Json.bodyObject(req).text("session_id");
        auto session = SessionKey(profileId, sessionId);
        writeJson(res, conversations.queueSnapshotJson(session), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
    }
}

void cancelSessionQueueItemResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ConversationPort conversations,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto sessionId = Json.bodyObject(req).text("session_id");
        auto session = SessionKey(profileId, sessionId);
        QueueMutation mutation;
        try {
            mutation = conversations.cancelQueueItem(session, req.params["item_id"]);
        } catch (Exception error) {
            if (!findProjectedQueueMutation(
                store.requireSession(session),
                req.params["item_id"],
                QueueItemState.cancelled,
                mutation,
            )) throw error;
        }
        if (mutation.changed) {
            auto projected = projectQueueMutation(store, session, mutation);
            bool historyReconciled = true;
            auto turn = store.findTurnBySubmission(session, mutation.item.id);
            if (turn.id.length && turn.status == "pending") {
                try store.cancelPendingConversationTurn(session, turn.id, nowIso());
                catch (Exception) {
                    // The queue cancellation is already durable. Startup
                    // recovery reconciles a turn record if this secondary
                    // projection write was interrupted.
                    historyReconciled = false;
                }
            }
            if (projected && historyReconciled)
                conversations.compactQueue(session);
            conversations.wake(session);
        }
        writeJson(res, queueMutationJson(mutation), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.conflict, "queue_conflict", error.msg, corsOrigin);
    }
}

void reserveSessionQueueItemResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto reservation = queueReservationFromJson(Json.bodyObject(req).value.toString());
        auto session = SessionKey(profileId, reservation.sessionId);
        // This is a server-to-server placement endpoint. The Voice server
        // already stamped the endpoint transition before sync/network delay;
        // preserving that timestamp keeps the user's submit moment truthful.
        auto mutation = store.sessionQueue(session).reserve(reservation);
        projectQueueMutation(store, session, mutation);
        writeJson(res, queueMutationJson(mutation), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.conflict, "queue_conflict", error.msg, corsOrigin);
    }
}

void touchSessionQueuePreparationResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto body = Json.bodyObject(req);
        auto session = SessionKey(profileId, body.nonEmpty("session_id"));
        auto mutation = store.sessionQueue(session).touchPreparation(
            req.params["item_id"],
            body.nonEmpty("progress_at"),
            body.text("deadline_at"),
        );
        writeJson(res, queueMutationJson(mutation), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.conflict, "queue_conflict", error.msg, corsOrigin);
    }
}

void failSessionQueuePreparationResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto body = Json.bodyObject(req);
        auto session = SessionKey(profileId, body.nonEmpty("session_id"));
        auto mutation = store.sessionQueue(session).fail(
            req.params["item_id"],
            body.nonEmpty("failure"),
        );
        if (projectQueueMutation(store, session, mutation))
            store.sessionQueue(session).compactTerminalPrefix();
        writeJson(res, queueMutationJson(mutation), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.conflict, "queue_conflict", error.msg, corsOrigin);
    }
}

void compactSessionQueueResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, Json.bodyObject(req).nonEmpty("session_id"));
        store.sessionQueue(session).compactTerminalPrefix();
        writeJson(res, store.sessionQueue(session).snapshot().json(), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.conflict, "queue_conflict", error.msg, corsOrigin);
    }
}
