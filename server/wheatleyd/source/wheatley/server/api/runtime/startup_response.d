module wheatley.server.api.runtime.startup_response;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
import vibe.core.core : yield;

import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.api.runtime.requests : profileStartupRequest;
import wheatley.server.api.http.json_response : writeError;
import wheatley.server.api.http.sse : startSse, writeSse;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.pi.models : PiModels;
import wheatley.server.profile.runtime : ProfileRuntime;
import wheatley.common.api.profile_startup :
    ProfileStartupRequest,
    profileStartupErrorJson;
import wheatley.server.startup.profile_startup : streamProfileStartup;
import wheatley.server.conversation.port : ConversationPreparationPort;
import wheatley.server.turns.text.pi_run_gate : PiRunGate;
import wheatley.server.session_use_registry : SessionUseRegistry;

void profileStartupStreamResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ProfileRuntime profiles,
    ConversationPreparationPort conversationPreparation,
    PiRunGate piRuns,
    SessionUseRegistry sessionUses,
    PiModels models,
    bool delegate() imageGenerationAvailable,
    string resourcesRoot,
    string corsOrigin,
)
{
    ProfileStartupRequest request;
    string profileId;
    try {
        profileId = requireProfileId(req, store);
        request = profileStartupRequest(req);
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
        return;
    }

    startSse(res, corsOrigin);
    try {
        streamProfileStartup(store, profiles, profileId, request, resourcesRoot, conversationPreparation, piRuns, sessionUses, models, imageGenerationAvailable, (eventName, dataJson) {
            writeSse(res, eventName, dataJson);
            yield();
        });
    } catch (Exception error) {
        writeSse(res, "error", profileStartupErrorJson(error.msg));
    } finally {
        res.finalize();
    }
}
