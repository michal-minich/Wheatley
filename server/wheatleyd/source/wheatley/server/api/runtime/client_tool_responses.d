module wheatley.server.api.runtime.client_tool_responses;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.server.api.http.file_response : sendPayloadFile;
import wheatley.server.api.http.json_response : handleJson, writeError;
import wheatley.server.api.http.request_params : queryParam;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.api.runtime.requests :
    clientToolAdvertisement,
    clientToolArtifactUpload,
    clientToolRequestCreate,
    clientToolResultCreate;
import wheatley.server.client_tools.store : ClientToolStore;
import wheatley.server.history.store : HistoryStore;



void advertiseClientToolClientResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ClientToolStore clientTools,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, {
        auto profileId = requireProfileId(req, store);
        return clientTools.advertiseClient(profileId, clientToolAdvertisement(req));
    });
}

void clientToolRequestsResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ClientToolStore clientTools,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, {
        auto profileId = requireProfileId(req, store);
        return clientTools.requestsJson(
            profileId,
            queryParam(req, "status"),
            queryParam(req, "client_id"),
            queryParam(req, "capability"),
        );
    });
}

void createClientToolRequestResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ClientToolStore clientTools,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, {
        auto profileId = requireProfileId(req, store);
        return clientTools.createRequest(profileId, clientToolRequestCreate(req));
    });
}

void clientToolRequestDetailResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ClientToolStore clientTools,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, {
        auto profileId = requireProfileId(req, store);
        return clientTools.detailJson(profileId, req.params["request_id"]);
    });
}

void completeClientToolRequestResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ClientToolStore clientTools,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, {
        auto profileId = requireProfileId(req, store);
        return clientTools.completeRequest(
            profileId,
            req.params["request_id"],
            clientToolResultCreate(req),
        );
    });
}

void uploadClientToolArtifactResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ClientToolStore clientTools,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, {
        auto profileId = requireProfileId(req, store);
        return clientTools.saveArtifact(
            profileId,
            req.params["request_id"],
            clientToolArtifactUpload(req),
        );
    });
}

void clientToolArtifactResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ClientToolStore clientTools,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto payload = clientTools.artifactPayload(
            profileId,
            req.params["request_id"],
            req.params["artifact_id"],
        );
        sendPayloadFile(req, res, payload, corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.notFound, "not_found", error.msg, corsOrigin);
    }
}
