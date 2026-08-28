module wheatley.server.api.http.sse;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerResponse;

import wheatley.server.api.http.json_response : addCommonHeaders;

void startSse(HTTPServerResponse res, string corsOrigin)
{
    addCommonHeaders(res, corsOrigin);
    res.statusCode = HTTPStatus.ok;
    res.headers["Content-Type"] = "text/event-stream; charset=UTF-8";
    res.headers["Cache-Control"] = "no-cache";
    res.headers["X-Accel-Buffering"] = "no";
}

bool writeSse(HTTPServerResponse res, string eventName, string dataJson)
{
    auto body = "event: " ~ eventName ~ "\n" ~ "data: " ~ dataJson ~ "\n\n";
    try {
        auto writer = res.bodyWriter;
        writer.write(cast(const(ubyte)[]) body);
        writer.flush();
        return true;
    } catch (Exception) {
        return false;
    }
}
