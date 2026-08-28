module wheatley.server.sync.http_client;

import core.time : dur;
import std.array : Appender, appender;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, read, write;
import std.format : format;
import std.json : parseJSON;
import std.path : dirName;
import std.socket : AddressFamily;
import std.string : strip;
import std.uri : encodeComponent;
import std.uuid : randomUUID;

import vibe.http.client : HTTPClientSettings, requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAll, readAllUTF8;

import wheatley.common.api.session_sync :
    SessionSyncManifest,
    SessionSyncManifestFile,
    sessionSyncManifestFromJson;
import wheatley.common.api.remote_turn_sync :
    RemoteTurnSessionHandoff,
    remoteTurnSessionHandoffJson;
import wheatley.common.api.accepted_voice_artifact :
    AcceptedVoiceArtifact,
    acceptedVoiceArtifactJson;
import wheatley.common.api.profile_replica :
    ProfileReplicaSnapshot,
    profileReplicaSnapshotFromJson;
import wheatley.server.history.store.sync_export : SyncCompletedTurnExport;
import wheatley.server.sync.remote_turn_peer : RemoteTurnSyncPeer;

/// HTTP boundary for synchronizing one appliance profile with its upstream peer.
class ProfileSyncHttpClient : RemoteTurnSyncPeer
{
    private string apiBase;

    this(string upstreamApiBase)
    {
        apiBase = normalizeApiBase(upstreamApiBase);
    }

    void uploadCompletedTurn(SyncCompletedTurnExport turn, bool includePi)
    {
        auto boundary = "wheatley-profile-sync-" ~ randomUUID().toString();
        auto body = completedTurnMultipart(boundary, turn, includePi);
        requestHTTP(turnUploadUrl(apiBase, turn.profileId), (scope request) {
            request.method = HTTPMethod.POST;
            request.writeBody(body, "multipart/form-data; boundary=" ~ boundary);
        }, (scope response) {
            enforceHttpOk(response, "Completed turn synchronization");
        }, httpSettings());
    }

    void ensureSession(string profileId, RemoteTurnSessionHandoff handoff)
    {
        requestHTTP(sessionHandoffUrl(apiBase, profileId), (scope request) {
            request.method = HTTPMethod.POST;
            request.writeBody(
                cast(ubyte[]) remoteTurnSessionHandoffJson(handoff),
                "application/json; charset=UTF-8",
            );
        }, (scope response) {
            enforceHttpOk(response, "Remote Conversation session handoff");
        }, httpSettings());
    }

    void importAcceptedVoice(AcceptedVoiceArtifact artifact, string opusPath)
    {
        auto boundary = "wheatley-accepted-voice-sync-" ~ randomUUID().toString();
        auto body = acceptedVoiceMultipart(boundary, artifact, opusPath);
        requestHTTP(acceptedVoiceImportUrl(apiBase, artifact.profileId), (scope request) {
            request.method = HTTPMethod.POST;
            request.writeBody(
                body,
                "multipart/form-data; boundary=" ~ boundary,
            );
        }, (scope response) {
            enforceHttpOk(response, "Accepted voice artifact synchronization");
        }, httpSettings());
    }

    SessionSyncManifest exactTurn(
        string profileId,
        string sessionPath,
        string turnPath,
    )
    {
        SessionSyncManifest manifest;
        requestHTTP(exactTurnUrl(
            apiBase,
            profileId,
            sessionPath,
            turnPath,
        ), (scope request) {
            request.method = HTTPMethod.GET;
        }, (scope response) {
            manifest = sessionSyncManifestFromJson(parseJSON(
                readTextResponse(response, "Exact remote turn synchronization"),
            ));
        }, httpSettings());
        return manifest;
    }

    void downloadExactTurnFile(
        string profileId,
        string sessionPath,
        string turnPath,
        SessionSyncManifestFile file,
        string targetPath,
    )
    {
        requestHTTP(exactTurnFileUrl(
            apiBase,
            profileId,
            sessionPath,
            turnPath,
            file,
        ), (scope request) {
            request.method = HTTPMethod.GET;
        }, (scope response) {
            enforceHttpOk(response, "Exact remote turn file synchronization");
            mkdirRecurse(dirName(targetPath));
            write(targetPath, response.bodyReader.readAll());
        }, httpSettings());
    }

    SessionSyncManifest latestSession(string profileId)
    {
        SessionSyncManifest manifest;
        requestHTTP(latestSessionUrl(apiBase, profileId), (scope request) {
            request.method = HTTPMethod.GET;
        }, (scope response) {
            manifest = sessionSyncManifestFromJson(parseJSON(
                readTextResponse(response, "Latest session synchronization"),
            ));
        }, httpSettings());
        return manifest;
    }

    ProfileReplicaSnapshot profileReplica(string profileId)
    {
        ProfileReplicaSnapshot snapshot;
        requestHTTP(profileReplicaUrl(apiBase, profileId), (scope request) {
            request.method = HTTPMethod.GET;
        }, (scope response) {
            snapshot = profileReplicaSnapshotFromJson(parseJSON(
                readTextResponse(response, "Profile replica synchronization"),
            ));
        }, httpSettings());
        return snapshot;
    }

    void downloadSessionFile(
        string profileId,
        string sessionPath,
        SessionSyncManifestFile file,
        string targetPath,
    )
    {
        requestHTTP(sessionFileUrl(apiBase, profileId, sessionPath, file), (scope request) {
            request.method = HTTPMethod.GET;
        }, (scope response) {
            enforceHttpOk(response, "Session file synchronization");
            mkdirRecurse(dirName(targetPath));
            write(targetPath, response.bodyReader.readAll());
        }, httpSettings());
    }
}

private ubyte[] acceptedVoiceMultipart(
    string boundary,
    AcceptedVoiceArtifact artifact,
    string opusPath,
)
{
    auto output = appender!(ubyte[]);
    putMultipartField(
        output,
        boundary,
        "artifact",
        acceptedVoiceArtifactJson(artifact),
    );
    if (opusPath.length) {
        putMultipartFile(
            output,
            boundary,
            "audio",
            artifact.submissionId ~ ".opus",
            "audio/ogg",
            opusPath,
        );
    }
    putAscii(output, "--" ~ boundary ~ "--\r\n");
    return output.data;
}

private string normalizeApiBase(string value)
{
    auto result = value.strip;
    enforce(result.length, "Sync upstream API base is empty");
    while (result.length && result[$ - 1] == '/') result = result[0 .. $ - 1];
    return result;
}

private string turnUploadUrl(string apiBase, string profileId)
{
    return profileUrl(apiBase, profileId) ~ "/sync/turns";
}

private string sessionHandoffUrl(string apiBase, string profileId)
{
    return profileUrl(apiBase, profileId) ~ "/sync/remote-turn/session";
}

private string acceptedVoiceImportUrl(string apiBase, string profileId)
{
    return profileUrl(apiBase, profileId) ~ "/sync/remote-turn/accepted-voice";
}

private string exactTurnUrl(
    string apiBase,
    string profileId,
    string sessionPath,
    string turnPath,
)
{
    return profileUrl(apiBase, profileId) ~ "/sync/remote-turn/manifest" ~
        "?session_path=" ~ encodeComponent(sessionPath) ~
        "&turn_path=" ~ encodeComponent(turnPath);
}

private string exactTurnFileUrl(
    string apiBase,
    string profileId,
    string sessionPath,
    string turnPath,
    SessionSyncManifestFile file,
)
{
    return profileUrl(apiBase, profileId) ~ "/sync/remote-turn/files" ~
        "?session_path=" ~ encodeComponent(sessionPath) ~
        "&turn_path=" ~ encodeComponent(turnPath) ~
        "&file_turn_path=" ~ encodeComponent(file.turnPath) ~
        "&name=" ~ encodeComponent(file.name);
}

private string latestSessionUrl(string apiBase, string profileId)
{
    return profileUrl(apiBase, profileId) ~ "/sync/latest-session";
}

private string profileReplicaUrl(string apiBase, string profileId)
{
    return profileUrl(apiBase, profileId) ~ "/sync/profile-replica";
}

private string sessionFileUrl(
    string apiBase,
    string profileId,
    string sessionPath,
    SessionSyncManifestFile file,
)
{
    return profileUrl(apiBase, profileId) ~ "/sync/files" ~
        "?session_path=" ~ encodeComponent(sessionPath) ~
        "&turn_path=" ~ encodeComponent(file.turnPath) ~
        "&name=" ~ encodeComponent(file.name);
}

private string profileUrl(string apiBase, string profileId)
{
    return apiBase ~ "/profiles/" ~ encodeComponent(profileId);
}

private ubyte[] completedTurnMultipart(
    string boundary,
    SyncCompletedTurnExport turn,
    bool includePi,
)
{
    auto output = appender!(ubyte[]);
    putMultipartField(output, boundary, "session_path", turn.sessionPath);
    putMultipartField(output, boundary, "turn_path", turn.turnPath);
    putMultipartFile(output, boundary, "session", "session.json", "application/json", turn.sessionJsonPath);
    putMultipartFile(output, boundary, "turn", "turn.json", "application/json", turn.turnJsonPath);
    putMultipartFile(output, boundary, "turn_markdown", "turn.md", "text/markdown; charset=UTF-8", turn.turnMarkdownPath);
    if (includePi && turn.piSessionJsonlPath.length)
        putMultipartFile(output, boundary, "pi_session", "pi_session.jsonl", "application/x-ndjson", turn.piSessionJsonlPath);
    if (turn.userOpusPath.length)
        putMultipartFile(output, boundary, "user_audio", "user.opus", "audio/ogg", turn.userOpusPath);
    if (turn.errorsJsonPath.length)
        putMultipartFile(output, boundary, "errors", "errors.json", "application/json", turn.errorsJsonPath);
    if (turn.toolsJsonPath.length)
        putMultipartFile(output, boundary, "tools", "tools.json", "application/json", turn.toolsJsonPath);
    if (turn.llmRequestsJsonPath.length)
        putMultipartFile(
            output,
            boundary,
            "llm_requests",
            "llm-requests.json",
            "application/json",
            turn.llmRequestsJsonPath,
        );
    putAscii(output, "--" ~ boundary ~ "--\r\n");
    return output.data;
}

private void putMultipartField(ref Appender!(ubyte[]) output, string boundary, string name, string value)
{
    putAscii(output, "--" ~ boundary ~ "\r\n");
    putAscii(output, `Content-Disposition: form-data; name="` ~ name ~ `"` ~ "\r\n\r\n");
    putAscii(output, value);
    putAscii(output, "\r\n");
}

private void putMultipartFile(
    ref Appender!(ubyte[]) output,
    string boundary,
    string name,
    string filename,
    string mimeType,
    string path,
)
{
    enforce(exists(path), "Sync upload file is missing: " ~ path);
    putAscii(output, "--" ~ boundary ~ "\r\n");
    putAscii(
        output,
        `Content-Disposition: form-data; name="` ~ name ~ `"; filename="` ~ filename ~ `"` ~ "\r\n",
    );
    putAscii(output, "Content-Type: " ~ mimeType ~ "\r\n\r\n");
    output.put(cast(ubyte[]) read(path));
    putAscii(output, "\r\n");
}

private void putAscii(ref Appender!(ubyte[]) output, string text)
{
    output.put(cast(ubyte[]) text);
}

private void enforceHttpOk(Response)(Response response, string label)
{
    if (httpOk(response.statusCode)) return;
    throw httpFailure(label, response.statusCode, response.bodyReader.readAllUTF8());
}

private string readTextResponse(Response)(Response response, string label)
{
    auto body = response.bodyReader.readAllUTF8();
    if (!httpOk(response.statusCode)) throw httpFailure(label, response.statusCode, body);
    return body;
}

private bool httpOk(Status)(Status statusCode)
{
    return statusCode >= 200 && statusCode < 300;
}

private Exception httpFailure(Status)(string label, Status statusCode, string body)
{
    return new Exception(format!"%s failed with HTTP %s: %s"(label, statusCode, body.strip));
}

private HTTPClientSettings httpSettings()
{
    auto settings = new HTTPClientSettings;
    settings.connectTimeout = dur!"msecs"(2_000);
    settings.readTimeout = dur!"msecs"(600_000);
    settings.dnsAddressFamily = AddressFamily.INET;
    return settings;
}

unittest
{
    import std.algorithm : canFind;
    import std.file : remove, tempDir;
    import std.path : buildPath;

    import wheatley.common.api.accepted_voice_artifact : acceptedVoiceArtifactSha256;
    import wheatley.common.api.reasoning : ReasoningMode;

    assert(normalizeApiBase(" http://server.local:8765/api/// ") == "http://server.local:8765/api");
    assert(turnUploadUrl("http://server.local/api", "sample / test") ==
        "http://server.local/api/profiles/sample%20%2F%20test/sync/turns");
    assert(sessionFileUrl(
        "http://server.local/api",
        "sample",
        "2026/08/05/10_00_00",
        SessionSyncManifestFile("10_00_01_000001", "turn.md"),
    ) == "http://server.local/api/profiles/sample/sync/files" ~
        "?session_path=2026%2F08%2F05%2F10_00_00" ~
        "&turn_path=10_00_01_000001&name=turn.md");
    assert(exactTurnUrl(
        "http://server.local/api",
        "sample",
        "2026/08/05/10_00_00",
        "10_00_01_000001",
    ) == "http://server.local/api/profiles/sample/sync/remote-turn/manifest" ~
        "?session_path=2026%2F08%2F05%2F10_00_00" ~
        "&turn_path=10_00_01_000001");
    assert(acceptedVoiceImportUrl("http://server.local/api", "sample") ==
        "http://server.local/api/profiles/sample/sync/remote-turn/accepted-voice");

    auto audioBytes = cast(ubyte[]) [1, 2, 3];
    auto artifact = AcceptedVoiceArtifact(
        "sample", "2026/08/05/10_00_00", "submission-a",
        "runtime-user-audio:submission-a", "audio_live", "Prompt", "en",
        "device", true, ReasoningMode.off, "model", "2026-08-05T10:00:00Z",
        audioBytes.length, 1, true, 4, true, acceptedVoiceArtifactSha256(audioBytes),
        "", "{}", "{}", "{}",
    );
    auto replayBody = cast(string) acceptedVoiceMultipart("boundary", artifact, "");
    assert(replayBody.canFind(`name="artifact"`));
    assert(!replayBody.canFind(`name="audio"`));
    auto opusPath = buildPath(
        tempDir(),
        "wheatley-http-accepted-test-" ~ randomUUID().toString() ~ ".opus",
    );
    scope(exit) if (exists(opusPath)) remove(opusPath);
    write(opusPath, audioBytes);
    auto uploadBody = cast(string) acceptedVoiceMultipart("boundary", artifact, opusPath);
    assert(uploadBody.canFind(`name="audio"`));
    assert(uploadBody.canFind(`filename="submission-a.opus"`));
}
