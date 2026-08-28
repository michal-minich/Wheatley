module wheatley.server.api.http.file_response;

import vibe.core.path : NativePath;
import vibe.http.fileserver : HTTPFileServerSettings, sendFile;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.server.api.http.json_response : addCommonHeaders;
import wheatley.server.history.files : FilePayload;

void sendPayloadFile(HTTPServerRequest req, HTTPServerResponse res, FilePayload payload, string corsOrigin)
{
    addCommonHeaders(res, corsOrigin);
    res.headers["Content-Type"] = payload.mediaType;
    auto settings = new HTTPFileServerSettings;
    auto mediaType = payload.mediaType;
    settings.preWriteCallback = (scope request, scope response, ref string physicalPath) {
        response.headers["Content-Type"] = mediaType;
    };
    sendFile(req, res, NativePath(payload.path), settings);
}
