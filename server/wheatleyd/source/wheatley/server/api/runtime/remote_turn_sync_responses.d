module wheatley.server.api.runtime.remote_turn_sync_responses;

import std.exception : enforce;
import std.json : parseJSON;
import std.string : endsWith, startsWith;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.common.api.remote_turn_sync : remoteTurnSessionHandoffFromJson;
import wheatley.common.api.session_sync :
    SessionSyncManifest,
    SessionSyncManifestFile,
    sessionSyncManifestJson;
import wheatley.common.json.object :
    jsonBoolField,
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.api.http.file_response : sendPayloadFile;
import wheatley.server.api.http.json_response : handleJson, writeError;
import wheatley.server.api.http.request_params : queryParam;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.history.files : FilePayload;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.sync_export :
    SyncSessionSnapshot,
    SyncSnapshotFile;
import wheatley.server.history.store.sync_paths : parseSyncSessionPath, parseSyncTurnPath;

void remoteTurnSessionHandoffResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, () {
        auto profileId = requireProfileId(req, store);
        auto handoff = remoteTurnSessionHandoffFromJson(
            Json.bodyObject(req).value,
        );
        auto created = store.ensureSyncedSession(profileId, handoff);
        return jsonObject([
            jsonBoolField("created", created),
            jsonStringField("session_id", handoff.sessionPath),
        ]);
    });
}

void remoteTurnManifestResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    res.headers["Cache-Control"] = "private, no-store";
    handleJson(res, corsOrigin, () {
        auto profileId = requireProfileId(req, store);
        auto sessionPath = queryParam(req, "session_path");
        auto turnPath = queryParam(req, "turn_path");
        parseSyncSessionPath(sessionPath);
        parseSyncTurnPath(turnPath);
        return sessionSyncManifestJson(exactManifest(
            store.sessionTurnSnapshot(profileId, sessionPath, turnPath),
            turnPath,
        ));
    });
}

void remoteTurnFileResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    res.headers["Cache-Control"] = "private, no-store";
    try {
        auto profileId = requireProfileId(req, store);
        auto sessionPath = queryParam(req, "session_path");
        auto turnPath = queryParam(req, "turn_path");
        auto fileTurnPath = queryParam(req, "file_turn_path");
        auto name = queryParam(req, "name");
        parseSyncSessionPath(sessionPath);
        parseSyncTurnPath(turnPath);
        enforce(!fileTurnPath.length || fileTurnPath == turnPath,
            "Remote turn file identity changed");
        enforce(remoteTurnFileAllowed(fileTurnPath, name),
            "Unsupported remote turn file");
        auto relativePath = fileTurnPath.length
            ? "turns/" ~ fileTurnPath ~ "/" ~ name
            : name;
        auto file = store.resolveSessionTurnSnapshotFile(
            profileId,
            sessionPath,
            turnPath,
            relativePath,
        );
        sendPayloadFile(
            req,
            res,
            FilePayload(file.localPath, remoteTurnMediaType(name)),
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

private SessionSyncManifest exactManifest(SyncSessionSnapshot snapshot, string turnPath)
{
    SessionSyncManifestFile[] files;
    foreach (file; snapshot.files) {
        auto prefix = "turns/" ~ turnPath ~ "/";
        if (file.relativePath.startsWith(prefix)) {
            files ~= SessionSyncManifestFile(turnPath, file.relativePath[prefix.length .. $]);
            continue;
        }
        enforce(!file.relativePath.startsWith("turns/"),
            "Exact remote manifest contains another turn");
        files ~= SessionSyncManifestFile("", file.relativePath);
    }
    return SessionSyncManifest(snapshot.sessionPath, files);
}

private bool remoteTurnFileAllowed(string turnPath, string name)
{
    if (turnPath.length) {
        return name == "turn.json" || name == "turn.md" || name == "user.opus"
            || name == "errors.json" || name == "tools.json";
    }
    if (name == "session.json" || name == "pi_session.jsonl") return true;
    if (!name.startsWith("pi_session_") || !name.endsWith(".jsonl")) return false;
    auto number = name["pi_session_".length .. $ - ".jsonl".length];
    if (!number.length) return false;
    long value;
    foreach (ch; number) {
        if (ch < '0' || ch > '9') return false;
        value = value * 10 + ch - '0';
    }
    return value >= 2;
}

private string remoteTurnMediaType(string name)
{
    if (name.endsWith(".json")) return "application/json; charset=UTF-8";
    if (name.endsWith(".jsonl")) return "application/x-ndjson; charset=UTF-8";
    if (name == "turn.md") return "text/markdown; charset=UTF-8";
    if (name == "user.opus") return "audio/ogg";
    throw new Exception("Unsupported remote turn file");
}

unittest
{
    import std.exception : assertThrown;

    auto manifest = exactManifest(SyncSessionSnapshot(
        "tester",
        "2026/08/05/12_00_00",
        [
            SyncSnapshotFile(
                "session.json",
                "/tmp/session.json",
            ),
            SyncSnapshotFile(
                "turns/12_00_01_000001/turn.json",
                "/tmp/turn.json",
            ),
        ],
    ), "12_00_01_000001");
    assert(manifest.files == [
        SessionSyncManifestFile("", "session.json"),
        SessionSyncManifestFile("12_00_01_000001", "turn.json"),
    ]);
    assert(remoteTurnFileAllowed("", "pi_session_2.jsonl"));
    assert(!remoteTurnFileAllowed("", "pi_session_bad.jsonl"));
    assertThrown!Exception(exactManifest(SyncSessionSnapshot(
        "tester",
        "2026/08/05/12_00_00",
        [SyncSnapshotFile(
            "turns/12_00_02_000001/turn.json",
            "/tmp/other.json",
        )],
    ), "12_00_01_000001"));
}
