module wheatley.server.api.runtime.sync_responses;

import std.algorithm : canFind, startsWith;
import std.exception : enforce;
import std.string : endsWith, split;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.common.api.session_sync :
    SessionSyncManifest,
    SessionSyncManifestFile,
    sessionSyncManifestJson;
import wheatley.common.api.profile_replica : profileReplicaSnapshotJson;
import wheatley.common.json.object :
    jsonBoolField,
    jsonObject,
    jsonStringField;
import wheatley.server.api.http.file_response : sendPayloadFile;
import wheatley.server.api.http.json_response : handleJson, writeError;
import wheatley.server.api.http.request_params : queryParam;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.api.runtime.sync_requests : completedTurnImportRequest;
import wheatley.server.history.files : FilePayload;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.sync_export : SyncSessionSnapshot, SyncSnapshotFile;
import wheatley.server.history.store.sync_paths : parseSyncTurnPath;

void completedTurnImportResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, () {
        auto profileId = requireProfileId(req, store);
        auto imported = store.importCompletedTurn(
            completedTurnImportRequest(req, profileId),
        );
        return jsonObject([
            jsonBoolField("imported", imported.imported),
            jsonStringField("session_id", imported.sessionId),
            jsonStringField("turn_id", imported.turnId),
        ]);
    });
}

void latestSessionSyncManifestResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    res.headers["Cache-Control"] = "private, no-store";
    handleJson(res, corsOrigin, () {
        auto profileId = requireProfileId(req, store);
        return sessionSyncManifestJson(syncManifest(store.latestSessionSnapshot(profileId)));
    });
}

void profileReplicaSyncResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    res.headers["Cache-Control"] = "private, no-store";
    handleJson(res, corsOrigin, () {
        return profileReplicaSnapshotJson(
            store.syncProfileReplicaSnapshot(requireProfileId(req, store)),
        );
    });
}

void latestSessionSyncFileResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    res.headers["Cache-Control"] = "private, no-store";
    try {
        auto profileId = requireProfileId(req, store);
        auto latest = store.latestSessionSnapshot(profileId);
        enforce(
            queryParam(req, "session_path") == latest.sessionPath,
            "Requested session is not the latest session snapshot",
        );
        auto name = queryParam(req, "name");
        auto relativePath = snapshotRelativePath(queryParam(req, "turn_path"), name);
        auto file = store.resolveLatestSessionSnapshotFile(profileId, relativePath);
        sendPayloadFile(
            req,
            res,
            FilePayload(file.localPath, snapshotMediaType(name)),
            corsOrigin,
        );
    } catch (Exception error) {
        auto missing = error.msg.canFind("not found") || error.msg.canFind("Not found");
        writeError(
            res,
            missing ? HTTPStatus.notFound : HTTPStatus.badRequest,
            missing ? "not_found" : "bad_request",
            error.msg,
            corsOrigin,
        );
    }
}

private SessionSyncManifest syncManifest(SyncSessionSnapshot snapshot)
{
    SessionSyncManifestFile[] files;
    foreach (file; snapshot.files) {
        auto parts = file.relativePath.split("/");
        if (parts.length == 1) {
            enforce(isSessionSnapshotFile(parts[0]), "Unsupported session snapshot file");
            files ~= SessionSyncManifestFile("", parts[0]);
            continue;
        }

        enforce(parts.length == 3 && parts[0] == "turns", "Unsupported turn snapshot path");
        parseSyncTurnPath(parts[1]);
        enforce(isTurnSnapshotFile(parts[2]), "Unsupported turn snapshot file");
        files ~= SessionSyncManifestFile(parts[1], parts[2]);
    }
    return SessionSyncManifest(snapshot.sessionPath, files);
}

private string snapshotRelativePath(string turnPath, string name)
{
    if (!turnPath.length) {
        enforce(isSessionSnapshotFile(name), "Unsupported session snapshot file");
        return name;
    }

    parseSyncTurnPath(turnPath);
    enforce(isTurnSnapshotFile(name), "Unsupported turn snapshot file");
    return "turns/" ~ turnPath ~ "/" ~ name;
}

private bool isSessionSnapshotFile(string name)
{
    if (name == "session.json" || name == "pi_session.jsonl") return true;
    if (!name.startsWith("pi_session_") || !name.endsWith(".jsonl")) return false;
    auto number = name["pi_session_".length .. $ - ".jsonl".length];
    if (!number.length) return false;
    auto value = 0L;
    foreach (ch; number) {
        if (ch < '0' || ch > '9') return false;
        value = value * 10 + ch - '0';
    }
    return value >= 2;
}

private bool isTurnSnapshotFile(string name)
{
    return name == "turn.json"
        || name == "turn.md"
        || name == "user.opus"
        || name == "errors.json"
        || name == "tools.json";
}

private string snapshotMediaType(string name)
{
    if (name.endsWith(".json")) return "application/json; charset=UTF-8";
    if (name.endsWith(".jsonl")) return "application/x-ndjson; charset=UTF-8";
    if (name == "turn.md") return "text/markdown; charset=UTF-8";
    if (name == "user.opus") return "audio/ogg";
    throw new Exception("Unsupported session snapshot file");
}

unittest
{
    import std.exception : assertThrown;

    auto manifest = syncManifest(SyncSessionSnapshot(
        "tester",
        "2026/08/05/12_34_56",
        [
            SyncSnapshotFile("session.json", "/tmp/session.json"),
            SyncSnapshotFile(
                "turns/12_35_00_123456/user.opus",
                "/tmp/user.opus",
            ),
        ],
    ));
    assert(manifest.files == [
        SessionSyncManifestFile("", "session.json"),
        SessionSyncManifestFile("12_35_00_123456", "user.opus"),
    ]);
    assert(snapshotRelativePath("12_35_00_123456", "turn.json")
        == "turns/12_35_00_123456/turn.json");
    assertThrown!Exception(snapshotRelativePath("../../other", "turn.json"));
    assertThrown!Exception(snapshotRelativePath("", "../session.json"));
}
