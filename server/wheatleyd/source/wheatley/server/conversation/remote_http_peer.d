module wheatley.server.conversation.remote_http_peer;

import core.time : dur;
import std.exception : enforce;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.socket : AddressFamily;
import std.string : endsWith, strip;
import std.uri : encodeComponent;

import vibe.http.client : HTTPClientSettings, requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAllUTF8;

import wheatley.common.api.conversation_events : conversationEventFromJson;
import wheatley.common.api.reasoning : ReasoningMode, reasoningModeText;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.text_turn : TextTurnRequest, textTurnRequestJson;
import wheatley.common.conversation.events : ConversationEventSink;
import wheatley.common.http.sse_events : readSseEvents;
import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonStringField;
import wheatley.server.conversation.remote_peer : RemoteConversationPeer;
import wheatley.server.queue.session_queue :
    QueueMutation,
    QueueReservation,
    queueMutationFromJson,
    queueReservationJson;

final class RemoteConversationHttpPeer : RemoteConversationPeer
{
    private string apiBase;

    this(string apiBase)
    {
        this.apiBase = normalizeApiBase(apiBase);
    }

    string queueSnapshotJson(SessionKey session)
    {
        return requestJson(
            HTTPMethod.GET,
            queueUrl(apiBase, session.profileId, session.sessionId),
            "",
            "Remote Conversation queue snapshot",
        );
    }

    QueueMutation reserveQueueItem(SessionKey session, QueueReservation reservation)
    {
        return queueMutationFromJson(requestJson(
            HTTPMethod.POST,
            queueReserveUrl(apiBase, session.profileId),
            queueReservationJson(reservation),
            "Remote Conversation queue reservation",
        ));
    }

    QueueMutation touchQueuePreparation(
        SessionKey session,
        string itemId,
        string progressAt,
        string deadlineAt,
    )
    {
        return queueMutationFromJson(requestJson(
            HTTPMethod.POST,
            queuePreparationUrl(apiBase, session.profileId, itemId, "touch"),
            jsonObject([
                jsonStringField("session_id", session.sessionId),
                jsonStringField("progress_at", progressAt),
                jsonStringField("deadline_at", deadlineAt),
            ]),
            "Remote Conversation queue preparation progress",
        ));
    }

    QueueMutation failQueuePreparation(SessionKey session, string itemId, string failure)
    {
        return queueMutationFromJson(requestJson(
            HTTPMethod.POST,
            queuePreparationUrl(apiBase, session.profileId, itemId, "fail"),
            jsonObject([
                jsonStringField("session_id", session.sessionId),
                jsonStringField("failure", failure),
            ]),
            "Remote Conversation queue preparation failure",
        ));
    }

    QueueMutation cancelQueueItem(SessionKey session, string itemId)
    {
        return queueMutationFromJson(requestJson(
            HTTPMethod.POST,
            queueItemUrl(apiBase, session.profileId, itemId) ~ "/cancel",
            jsonObject([jsonStringField("session_id", session.sessionId)]),
            "Remote Conversation queue cancellation",
        ));
    }

    void compactQueue(SessionKey session)
    {
        requestJson(
            HTTPMethod.POST,
            queueCompactUrl(apiBase, session.profileId),
            jsonObject([jsonStringField("session_id", session.sessionId)]),
            "Remote Conversation queue compaction",
        );
    }

    void streamText(
        string profileId,
        TextTurnRequest request,
        ConversationEventSink sink,
    )
    {
        postConversationStream(
            textTurnUrl(apiBase, profileId),
            textTurnRequestJson(request),
            "Remote text Conversation",
            sink,
        );
    }

    void streamAcceptedVoice(
        string profileId,
        string submissionId,
        ReasoningMode reasoningMode,
        string model,
        long afterSequence,
        ConversationEventSink sink,
    )
    {
        enforce(afterSequence >= 0, "Accepted voice replay cursor cannot be negative");
        postConversationStream(
            acceptedVoiceCommitUrl(apiBase, profileId, submissionId),
            jsonObject([
                jsonLongField("after_sequence", afterSequence),
                jsonStringField("reasoning_mode", reasoningModeText(reasoningMode)),
                jsonStringField("model", model),
            ]),
            "Remote accepted voice Conversation",
            sink,
        );
    }

    void stop(SessionKey session, string turnId)
    {
        requestHTTP(stopTurnUrl(
            apiBase,
            session.profileId,
            turnId,
        ), (scope request) {
            request.method = HTTPMethod.POST;
            request.writeBody(
                cast(ubyte[]) jsonObject([
                    jsonStringField("session_id", session.sessionId),
                ]),
                "application/json; charset=UTF-8",
            );
        }, (scope response) {
            enforceHttpOk(response, "Remote Conversation stop");
        }, httpSettings());
    }

    private void postConversationStream(
        string url,
        string body,
        string label,
        ConversationEventSink sink,
    )
    {
        enforce(sink !is null, "Remote Conversation event sink is required");
        requestHTTP(url, (scope request) {
            request.method = HTTPMethod.POST;
            request.writeBody(
                cast(ubyte[]) body,
                "application/json; charset=UTF-8",
            );
        }, (scope response) {
            enforceHttpOk(response, label);
            readSseEvents(response.bodyReader, (event) {
                enforce(
                    event.name == "conversation",
                    label ~ " returned an unsupported SSE event: " ~ event.name,
                );
                sink(conversationEventFromJson(parseJSON(event.data)));
                return true;
            });
        }, httpSettings());
    }

    private string requestJson(HTTPMethod method, string url, string body, string label)
    {
        string result;
        requestHTTP(url, (scope request) {
            request.method = method;
            if (body.length) request.writeBody(
                cast(ubyte[]) body,
                "application/json; charset=UTF-8",
            );
        }, (scope response) {
            enforceHttpOk(response, label);
            result = response.bodyReader.readAllUTF8();
        }, httpSettings());
        return result;
    }
}

private string normalizeApiBase(string value)
{
    auto result = value.strip;
    enforce(result.length, "Remote Conversation API base is empty");
    while (result.length && result[$ - 1] == '/') result = result[0 .. $ - 1];
    return result;
}

private string textTurnUrl(string apiBase, string profileId)
{
    return profileUrl(apiBase, profileId) ~ "/turns/text/stream";
}

private string queueUrl(string apiBase, string profileId, string sessionId)
{
    return profileUrl(apiBase, profileId)
        ~ "/queue?session_id=" ~ encodeComponent(sessionId);
}

private string queueReserveUrl(string apiBase, string profileId)
{
    return profileUrl(apiBase, profileId) ~ "/queue/reserve";
}

private string queueCompactUrl(string apiBase, string profileId)
{
    return profileUrl(apiBase, profileId) ~ "/queue/compact";
}

private string queueItemUrl(string apiBase, string profileId, string itemId)
{
    return profileUrl(apiBase, profileId) ~ "/queue/" ~ encodeComponent(itemId);
}

private string queuePreparationUrl(
    string apiBase,
    string profileId,
    string itemId,
    string operation,
)
{
    return queueItemUrl(apiBase, profileId, itemId) ~ "/preparation/" ~ operation;
}

private string acceptedVoiceCommitUrl(
    string apiBase,
    string profileId,
    string submissionId,
)
{
    return profileUrl(apiBase, profileId)
        ~ "/accepted-voice/" ~ encodeComponent(submissionId) ~ "/commit/stream";
}

private string stopTurnUrl(string apiBase, string profileId, string turnId)
{
    return profileUrl(apiBase, profileId)
        ~ "/turns/text/" ~ encodeComponent(turnId) ~ "/stop";
}

private string profileUrl(string apiBase, string profileId)
{
    return apiBase ~ "/profiles/" ~ encodeComponent(profileId);
}

private void enforceHttpOk(Response)(Response response, string label)
{
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw new Exception(format!"%s failed with HTTP %s: %s"(
        label,
        response.statusCode,
        response.bodyReader.readAllUTF8().strip,
    ));
}

private HTTPClientSettings httpSettings()
{
    auto settings = new HTTPClientSettings;
    settings.connectTimeout = dur!"msecs"(2_000);
    settings.readTimeout = dur!"msecs"(600_000);
    settings.dnsAddressFamily = AddressFamily.INET;
    return settings;
}

unittest
{
    assert(textTurnUrl("http://server.local/api", "sample") ==
        "http://server.local/api/profiles/sample/turns/text/stream");
    assert(acceptedVoiceCommitUrl(
        "http://server.local/api",
        "sample",
        "voice / one",
    ) == "http://server.local/api/profiles/sample/accepted-voice/voice%20%2F%20one/commit/stream");
    assert(stopTurnUrl(
        "http://server.local/api",
        "sample",
        "sample/sessions/2026/08/05/12_00_00/turns/12_00_01_000001",
    ).length);
    assert(queueUrl("http://server.local/api", "sample", "2026/08/05/12_00_00") ==
        "http://server.local/api/profiles/sample/queue?session_id=2026%2F08%2F05%2F12_00_00");
    assert(queueReserveUrl("http://server.local/api", "sample").endsWith("/queue/reserve"));
    assert(queueCompactUrl("http://server.local/api", "sample").endsWith("/queue/compact"));
}
