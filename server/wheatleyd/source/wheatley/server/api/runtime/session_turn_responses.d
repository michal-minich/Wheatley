module wheatley.server.api.runtime.session_turn_responses;

import core.time : dur;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;

import vibe.core.core : sleep;
import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.conversation_events : conversationEventFromJson;
import wheatley.common.json.object : jsonLongField, jsonObject;
import wheatley.server.api.http.json_response : writeError;
import wheatley.server.api.http.request_params : queryParam;
import wheatley.server.api.http.sse : startSse, writeSse;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.presentation.store :
    PresentationEntry,
    PresentationFollower;

/** Durable session presentation stream. Conversation events are replayed from
    the journal, so scheduled turns render as Pi produces them even though they
    were not started by this browser's request SSE connection. */
void sessionTurnEventsResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, queryParam(req, "session_id"));
        auto sessionRoot = store.requireSession(session);
        auto after = queryParam(req, "after_sequence");
        auto afterSequence = after.length ? after.to!long : 0;
        startSse(res, corsOrigin);
        auto follower = new PresentationFollower(sessionRoot, afterSequence);
        long idlePolls;
        while (true) {
            auto entries = follower.readAvailable();
            if (entries.length) {
                idlePolls = 0;
                foreach (entry; entries) {
                    auto isConversation = isConversationPresentation(entry);
                    if (isConversation) {
                        if (!writeSse(
                            res,
                            "conversation",
                            payloadWithPresentationSequence(entry),
                        )) return;
                    } else {
                        auto payload = entry.source == "queue"
                            ? payloadWithPresentationSequence(entry)
                            : jsonObject([jsonLongField("watermark", entry.sequence)]);
                        if (!writeSse(res, "changed", payload)) return;
                    }
                }
            } else if (++idlePolls >= 20) {
                idlePolls = 0;
                if (!writeSse(res, "heartbeat", "{}")) return;
            }
            sleep(dur!"msecs"(250));
        }
    } catch (Exception error) {
        if (!res.headerWritten) writeError(
            res,
            HTTPStatus.badRequest,
            "bad_request",
            error.msg,
            corsOrigin,
        );
    } finally {
        finalizeSessionObserverQuietly(res);
    }
}

private string payloadWithPresentationSequence(PresentationEntry entry)
{
    auto value = parseJSON(entry.payloadJson);
    enforce(value.type == JSONType.object, "Presentation payload is not an object");
    value.object["presentation_sequence"] = JSONValue(entry.sequence);
    return value.toString();
}

private void finalizeSessionObserverQuietly(HTTPServerResponse res)
{
    try {
        if (res.headerWritten) res.finalize();
    } catch (Exception) {
        // Session observers are disposable; the durable producer is not.
    }
}

/** Historical branch markers share some presentation kind names but have an
    empty payload. They preserve ordering only; never expose them as malformed
    live conversation events. */
private bool isConversationPresentation(PresentationEntry entry)
{
    if (entry.source != "pi") return false;
    if (entry.kind != "status"
        && entry.kind != "assistant_delta"
        && entry.kind != "reasoning"
        && entry.kind != "tool"
        && entry.kind != "artifact"
        && entry.kind != "completed"
        && entry.kind != "failed") return false;
    try {
        conversationEventFromJson(parseJSON(entry.payloadJson));
        return true;
    } catch (Exception) {
        return false;
    }
}

unittest
{
    auto payload = payloadWithPresentationSequence(PresentationEntry(
        42,
        "pi",
        "reasoning",
        "turn-1",
        "assistant:0:0",
        `{"sequence":7,"kind":"reasoning"}`,
    ));
    auto value = parseJSON(payload);
    assert(value["sequence"].integer == 7);
    assert(value["presentation_sequence"].integer == 42);
}
