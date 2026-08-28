module wheatley.server.api.http.request_params;

import vibe.http.server : HTTPServerRequest;

string queryParam(HTTPServerRequest req, string name)
{
    if (auto value = name in req.query) return *value;
    return "";
}

string headerValue(HTTPServerRequest req, string name)
{
    if (auto value = name in req.headers) return *value;
    return "";
}
