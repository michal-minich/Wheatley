module wheatley.server.api.runtime.codex_responses;

import core.time : dur;

import std.conv : to;
import std.exception : enforce;

import vibe.core.core : sleep;
import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.common.api.session : SessionKey;
import wheatley.common.json.read : Json;
import wheatley.server.api.http.json_response : handleJson, writeError, writeJson;
import wheatley.server.api.http.request_params : queryParam;
import wheatley.server.api.http.sse : startSse, writeSse;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.codex.port : CodexSessionPort;
import wheatley.server.codex.client : CodexWorkerIoException;
import wheatley.server.codex.service :
    codexLiveEventJson,
    codexMessageResultJson,
    codexStatusResultJson;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.presentation.store : presentationSnapshotJson;
import wheatley.server.profile.runtime : ProfileRuntime;
import wheatley.server.turns.text.profile_runtime_settings : profileToolAvailability;

void codexMessageResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ProfileRuntime profiles,
    CodexSessionPort codex,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        enforce(codexToolsEnabled(profiles, profileId).codexMessage,
            "codex_message is disabled for this profile");
        auto payload = Json.bodyObject(req);
        auto session = SessionKey(profileId, payload.text("session_id"));
        auto sessionRoot = store.requireSession(session);
        writeJson(res, codexMessageResultJson(codex.message(
            session,
            sessionRoot,
            payload.text("turn_id"),
            payload.text("message"),
        )), corsOrigin);
    } catch (CodexWorkerIoException error) {
        writeError(
            res,
            HTTPStatus.badGateway,
            "io",
            error.msg,
            corsOrigin,
        );
    } catch (Exception error) {
        writeError(
            res,
            HTTPStatus.badRequest,
            "bad_request",
            error.msg,
            corsOrigin,
        );
    }
}

void sessionPresentationResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    CodexSessionPort codex,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, queryParam(req, "session_id"));
        auto sessionRoot = store.requireSession(session);
        try codex.status(session, sessionRoot);
        catch (Exception) {
            // Presentation remains available from the durable local journal.
        }
        return presentationSnapshotJson(sessionRoot);
    });
}

void codexStatusResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ProfileRuntime profiles,
    CodexSessionPort codex,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, {
        auto profileId = requireProfileId(req, store);
        enforce(codexToolsEnabled(profiles, profileId).codexStatus,
            "codex_status is disabled for this profile");
        auto session = SessionKey(profileId, queryParam(req, "session_id"));
        auto sessionRoot = store.requireSession(session);
        return codexStatusResultJson(codex.status(
            session,
            sessionRoot,
        ));
    });
}

void codexEventsResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    CodexSessionPort codex,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, queryParam(req, "session_id"));
        auto sessionRoot = store.requireSession(session);
        auto rawAfter = queryParam(req, "after_sequence");
        auto cursor = rawAfter.length ? rawAfter.to!long : 0;
        startSse(res, corsOrigin);
        long idlePolls;
        while (true) {
            foreach (event; codex.eventsAfter(session, sessionRoot, cursor)) {
                cursor = event.sequence;
                idlePolls = 0;
                if (!writeSse(res, "codex", codexLiveEventJson(event))) return;
            }
            if (++idlePolls >= 20) {
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
        finalizeCodexObserverQuietly(res);
    }
}

private void finalizeCodexObserverQuietly(HTTPServerResponse res)
{
    try {
        if (res.headerWritten) res.finalize();
    } catch (Exception) {
        // Codex observers may disconnect without affecting durable work.
    }
}

private auto codexToolsEnabled(ProfileRuntime profiles, string profileId)
{
    return profileToolAvailability(profiles.resolveSession(profileId).configIndex);
}
