module wheatley.server.api.http.json_response;

import std.format : format;
import std.json : JSONValue;
import std.string : indexOf;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerResponse;

void writeJson(HTTPServerResponse res, string body, string corsOrigin = "", HTTPStatus status = HTTPStatus.ok)
{
    addCommonHeaders(res, corsOrigin);
    res.statusCode = status;
    res.writeBody(body, "application/json; charset=UTF-8");
}

void writeError(HTTPServerResponse res, HTTPStatus status, string code, string message, string corsOrigin = "")
{
    writeJson(res, apiErrorJson(code, message), corsOrigin, status);
}

string apiErrorJson(string code, string message)
{
    return format!`{"error":{"code":%s,"message":%s}}`(
        JSONValue(code).toString(),
        JSONValue(message).toString(),
    );
}

void handleJson(HTTPServerResponse res, string corsOrigin, string delegate() load)
{
    try {
        writeJson(res, load(), corsOrigin);
    } catch (Exception error) {
        auto status = error.msg.indexOf("not found") >= 0 || error.msg.indexOf("Not found") >= 0
            ? HTTPStatus.notFound
            : HTTPStatus.badRequest;
        writeError(
            res,
            status,
            status == HTTPStatus.notFound ? "not_found" : "bad_request",
            error.msg,
            corsOrigin,
        );
    }
}

void addCommonHeaders(HTTPServerResponse res, string corsOrigin)
{
    if (corsOrigin.length) {
        res.headers["Access-Control-Allow-Origin"] = corsOrigin;
        res.headers["Access-Control-Allow-Methods"] = "GET, HEAD, POST, PUT, DELETE, OPTIONS";
        res.headers["Access-Control-Allow-Headers"] = "Content-Type";
    }
}
