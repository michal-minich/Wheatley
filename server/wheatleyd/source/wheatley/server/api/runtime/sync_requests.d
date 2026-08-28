module wheatley.server.api.runtime.sync_requests;

import std.exception : enforce;
import std.file : readText;
import std.json : parseJSON;

import vibe.http.server : HTTPServerRequest;

import wheatley.common.http.form : Form;
import wheatley.common.json.read : Json;
import wheatley.server.history.store.sync : CompletedTurnImport;

CompletedTurnImport completedTurnImportRequest(
    HTTPServerRequest req,
    string profileId,
)
{
    auto form = Form.from(req);
    auto turnJsonPath = uploadedPath(req, "turn", true);
    return CompletedTurnImport(
        profileId,
        form.nonEmpty("session_path"),
        form.nonEmpty("turn_path"),
        uploadedPath(req, "session", true),
        turnJsonPath,
        uploadedPath(req, "turn_markdown", true),
        uploadedPath(req, "pi_session", false),
        uploadedPath(req, "user_audio", false),
        uploadedPath(req, "errors", false),
        uploadedPath(req, "tools", false),
        uploadedPath(req, "llm_requests", false),
        Json.object(parseJSON(readText(turnJsonPath))).boolean("user_audio_required"),
    );
}

private string uploadedPath(HTTPServerRequest req, string name, bool required)
{
    auto uploaded = name in req.files;
    enforce(uploaded !is null || !required, "Sync file " ~ name ~ " is required");
    return uploaded is null ? "" : uploaded.tempPath.toString();
}
