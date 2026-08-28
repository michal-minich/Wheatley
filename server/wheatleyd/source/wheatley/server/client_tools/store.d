module wheatley.server.client_tools.store;

import core.time : dur;

import std.algorithm : endsWith, sort, startsWith;
import std.array : appender;
import std.conv : to;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file :
    SpanMode,
    copy,
    dirEntries,
    exists,
    getSize,
    isDir,
    isFile,
    mkdirRecurse,
    readText,
    timeLastModified,
    write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, dirSeparator;
import std.string : strip;
import std.uuid : randomUUID;

import wheatley.common.json.object :
    jsonArrayRaw,
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonObjectOrNullRaw,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField;
import wheatley.common.api.client_tools :
    ClientToolAdvertisement,
    ClientToolRequest,
    ClientToolRequestCreate,
    ClientToolResultCreate,
    clientToolRequestFromJson;
import wheatley.common.api.session : SessionKey;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.safe_token : requireSafeIdToken;
import wheatley.server.history.files : FilePayload;
import wheatley.server.history.store : HistoryStore;

struct ClientToolArtifactUpload
{
    string tempPath;
    string filename;
    string artifactId;
    string kind;
    string mimeType;
}

class ClientToolStore
{
    private string profilesRoot;
    private HistoryStore history;

    this(string profilesRoot, HistoryStore history = null)
    {
        this.profilesRoot = absolutePath(buildNormalizedPath(profilesRoot));
        this.history = history;
    }



    string advertiseClient(string profileId, ClientToolAdvertisement advertisement)
    {
        enforceProfileRoot(profileId);
        auto clientId = requireSafeIdToken(required(advertisement.clientId, "client_id"), "client_id");
        auto updatedAt = nowIso();
        auto path = clientPath(profileId, clientId);
        mkdirRecurse(dirName(path));
        auto body = clientJson(profileId, clientId, advertisement, updatedAt);
        write(path, body);
        return jsonObject([jsonRawField("client", body)]);
    }

    string createRequest(string profileId, ClientToolRequestCreate request)
    {
        enforceProfileRoot(profileId);
        auto requestId = request.requestId.length ? requireSafeIdToken(request.requestId) : newRequestId();
        auto createdAt = nowIso();
        auto path = requestPath(profileId, requestId);
        enforce(!exists(path), "Client tool request already exists");
        mkdirRecurse(dirName(path));
        auto body = requestJson(profileId, requestId, request, "pending", createdAt, createdAt);
        write(path, body);
        return detailJson(profileId, requestId);
    }

    string captureScreenScope(string profileId, string clientId)
    {
        if (!clientId.length) return "";
        auto path = clientPath(profileId, clientId);
        if (!exists(path) || !isFile(path)) return "";
        auto client = Json.parse(readText(path));
        foreach (value; client.array("capabilities").value.array) {
            auto capability = Json.object(value);
            if (capability.opt.textOrEmpty("name") != "capture_screen") continue;
            auto values = capability.object("schema")
                .object("properties")
                .object("scope")
                .array("enum")
                .value.array;
            bool activeWindow;
            bool activeDisplay;
            foreach (scopeValue; values) {
                if (scopeValue.type != JSONType.string) return "";
                if (scopeValue.str == "active_window") activeWindow = true;
                else if (scopeValue.str == "active_display") activeDisplay = true;
                else return "";
            }
            if (activeWindow && activeDisplay) return "both";
            if (activeWindow) return "active_window";
            if (activeDisplay) return "active_display";
            return "";
        }
        return "";
    }

    string requestsJson(string profileId, string status, string clientId, string capability)
    {
        enforceProfileRoot(profileId);
        string[] requests;
        auto root = requestsRoot(profileId);
        mkdirRecurse(root);
        foreach (entry; dirEntries(root, SpanMode.shallow)) {
            if (!entry.isDir) continue;
            auto requestId = baseName(entry.name);
            auto requestJson = loadRequest(profileId, requestId);
            if (!requestJson.length) continue;
            auto request = parseJSON(requestJson);
            if (request.type != JSONType.object) continue;
            if (!matchesRequest(request, status, clientId, capability)) continue;
            requests ~= detailJson(profileId, requestId);
        }
        sort(requests);
        return jsonObject([jsonRawField("requests", jsonArray(requests))]);
    }

    string detailJson(string profileId, string requestId)
    {
        enforceProfileRoot(profileId);
        requestId = requireSafeIdToken(requestId);
        auto request = loadRequest(profileId, requestId);
        enforce(request.length, "Client tool request not found");
        auto result = loadResult(profileId, requestId);
        return jsonObject([
            jsonRawField("request", request),
            jsonRawField("result", result.length ? result : "null"),
        ]);
    }

    string completeRequest(string profileId, string requestId, ClientToolResultCreate result)
    {
        enforceProfileRoot(profileId);
        requestId = requireSafeIdToken(requestId);
        auto existing = requestValue(profileId, requestId);
        auto status = result.ok ? "succeeded" : "failed";
        auto completedAt = nowIso();
        auto request = clientToolRequestFromJson(existing);
        if (request.clientId.length)
            enforce(result.clientId == request.clientId,
                "Client tool result came from the wrong client");
        if (result.ok && request.capability == "capture_screen")
            result.artifactsJson = promoteScreenCapture(profileId, request, result.artifactsJson);
        write(requestPath(profileId, requestId), requestJson(
            profileId,
            requestId,
            ClientToolRequestCreate(
                request.requestId,
                request.sessionId,
                request.turnId,
                request.toolCallId,
                request.clientId,
                request.target,
                request.capability,
                request.argumentsJson,
                request.timeoutMs,
            ),
            status,
            request.createdAt,
            completedAt,
        ));
        auto body = resultJson(profileId, requestId, result, status, completedAt);
        auto path = resultPath(profileId, requestId);
        mkdirRecurse(dirName(path));
        write(path, body);
        return detailJson(profileId, requestId);
    }

    private string promoteScreenCapture(
        string profileId,
        ClientToolRequest request,
        string artifactsJson,
    )
    {
        enforce(history !is null, "Screen capture history store is unavailable");
        auto artifactValues = parseJSON(artifactsJson);
        enforce(artifactValues.type == JSONType.array,
            "Screen capture artifacts must be an array");
        auto artifacts = artifactValues.array;
        enforce(artifacts.length == 1, "Screen capture must return one canonical artifact");
        auto artifact = Json.object(artifacts[0]);
        enforce(artifact.nonEmpty("kind") == "screen_capture",
            "Screen capture artifact kind is invalid");
        auto artifactId = artifact.nonEmpty("artifact_id");
        auto metadata = Json.parse(readText(artifactMetaPath(
            profileId,
            request.requestId,
            artifactId,
        )));
        auto sourcePath = artifactFilePath(
            profileId,
            request.requestId,
            metadata.nonEmpty("stored_filename"),
        );
        auto promoted = history.promoteScreenCapture(
            SessionKey(profileId, request.sessionId),
            request.turnId,
            sourcePath,
            artifact,
            request.toolCallId,
        );
        return "[" ~ promoted ~ "]";
    }

    string saveArtifact(string profileId, string requestId, ClientToolArtifactUpload upload)
    {
        enforceProfileRoot(profileId);
        requestId = requireSafeIdToken(requestId);
        enforce(loadRequest(profileId, requestId).length, "Client tool request not found");
        enforce(exists(upload.tempPath) && isFile(upload.tempPath), "Client tool artifact upload is missing");

        auto artifactId = upload.artifactId.length
            ? requireSafeIdToken(upload.artifactId)
            : "artifact-" ~ randomUUID().toString();
        auto filename = safeFilename(upload.filename.length ? upload.filename : artifactId);
        auto storedName = artifactId ~ "-" ~ filename;
        auto path = artifactFilePath(profileId, requestId, storedName);
        mkdirRecurse(dirName(path));
        copy(upload.tempPath, path);

        auto body = artifactJson(
            profileId,
            requestId,
            artifactId,
            upload.kind.length ? upload.kind : "file",
            upload.mimeType.length ? upload.mimeType : "application/octet-stream",
            filename,
            storedName,
            getSize(path),
            nowIso(),
        );
        write(artifactMetaPath(profileId, requestId, artifactId), body);
        return jsonObject([jsonRawField("artifact", body)]);
    }

    FilePayload artifactPayload(string profileId, string requestId, string artifactId)
    {
        enforceProfileRoot(profileId);
        requestId = requireSafeIdToken(requestId);
        artifactId = requireSafeIdToken(artifactId);
        auto path = artifactMetaPath(profileId, requestId, artifactId);
        enforce(exists(path), "Client tool artifact not found");
        auto metadata = Json.parse(readText(path));
        auto storedName = metadata.text("stored_filename");
        auto filePath = artifactFilePath(profileId, requestId, storedName);
        enforce(exists(filePath) && isFile(filePath), "Client tool artifact file not found");
        return FilePayload(filePath, metadata.text("mime"));
    }

    private string clientJson(
        string profileId,
        string clientId,
        ClientToolAdvertisement advertisement,
        string updatedAt,
    )
    {
        return jsonObject([
            jsonStringField("type", "client_capabilities"),
            jsonStringField("profile_id", profileId),
            jsonStringField("client_id", clientId),
            jsonStringField("device_id", advertisement.deviceId),
            jsonStringField("label", advertisement.label),
            jsonStringField("updated_at", updatedAt),
            jsonRawField("capabilities", jsonArrayRaw(advertisement.capabilitiesJson)),
            jsonRawField("metadata", jsonObjectRaw(advertisement.metadataJson)),
        ]);
    }

    private string requestJson(
        string profileId,
        string requestId,
        ClientToolRequestCreate request,
        string status,
        string createdAt,
        string updatedAt,
    )
    {
        auto argumentsJson = jsonObjectRaw(request.argumentsJson);
        return jsonObject([
            jsonStringField("type", "client_tool_request"),
            jsonStringField("request_id", requestId),
            jsonStringField("profile_id", profileId),
            jsonStringField("status", status),
            jsonStringField("created_at", createdAt),
            jsonStringField("updated_at", updatedAt),
            jsonStringField("session_id", request.sessionId),
            jsonStringField("turn_id", request.turnId),
            jsonStringField("tool_call_id", request.toolCallId),
            jsonStringField("client_id", request.clientId),
            jsonStringField("target", request.target),
            jsonStringField("capability", required(request.capability, "capability")),
            jsonLongField("timeout_ms", request.timeoutMs > 0 ? request.timeoutMs : 30_000),
            jsonRawField("arguments", argumentsJson),
            jsonRawField("command", jsonObject([
                jsonStringField("capability", request.capability),
                jsonRawField("arguments", argumentsJson),
            ])),
        ]);
    }

    private string resultJson(
        string profileId,
        string requestId,
        ClientToolResultCreate result,
        string status,
        string completedAt,
    )
    {
        return jsonObject([
            jsonStringField("type", "client_tool_result"),
            jsonStringField("request_id", requestId),
            jsonStringField("profile_id", profileId),
            jsonStringField("client_id", result.clientId),
            jsonStringField("status", status),
            jsonStringField("completed_at", completedAt),
            jsonBoolField("ok", result.ok),
            jsonRawField("content", jsonArrayRaw(result.contentJson)),
            jsonRawField("artifacts", jsonArrayRaw(result.artifactsJson)),
            jsonRawField("error", jsonObjectOrNullRaw(result.errorJson)),
        ]);
    }

    private string artifactJson(
        string profileId,
        string requestId,
        string artifactId,
        string kind,
        string mime,
        string originalFilename,
        string storedFilename,
        ulong byteCount,
        string createdAt,
    )
    {
        auto urlPath = "/api/profiles/" ~ profileId ~
            "/client-tools/requests/" ~ requestId ~
            "/artifacts/" ~ artifactId;
        return jsonObject([
            jsonStringField("type", "client_tool_artifact"),
            jsonStringField("profile_id", profileId),
            jsonStringField("request_id", requestId),
            jsonStringField("artifact_id", artifactId),
            jsonStringField("kind", kind),
            jsonStringField("mime", mime),
            jsonStringField("filename", originalFilename),
            jsonStringField("stored_filename", storedFilename),
            jsonStringField("path", "profiles/" ~ profileId ~
                "/client-tools/requests/" ~ requestId ~ "/artifacts/" ~ storedFilename),
            jsonStringField("url", urlPath),
            jsonLongField("byte_count", cast(long) byteCount),
            jsonStringField("created_at", createdAt),
        ]);
    }

    private bool matchesRequest(JSONValue request, string status, string clientId, string capability)
    {
        auto json = Json.object(request);
        if (status.length && json.text("status") != status) return false;
        if (capability.length && json.text("capability") != capability) return false;
        if (!clientId.length) return true;
        auto explicitClient = json.text("client_id");
        auto target = json.text("target");
        return explicitClient == clientId ||
            target == clientId ||
            target == "any" ||
            target == "active_voice_client" ||
            (!explicitClient.length && !target.length);
    }

    private JSONValue requestValue(string profileId, string requestId)
    {
        auto path = requestPath(profileId, requestId);
        enforce(exists(path), "Client tool request not found");
        return Json.parse(readText(path)).value;
    }

    private string loadRequest(string profileId, string requestId)
    {
        auto path = requestPath(profileId, requireSafeIdToken(requestId));
        if (!exists(path)) return "";
        return readText(path);
    }

    private string loadResult(string profileId, string requestId)
    {
        auto path = resultPath(profileId, requireSafeIdToken(requestId));
        if (!exists(path)) return "";
        return readText(path);
    }

    private string clientPath(string profileId, string clientId)
    {
        return buildPath(clientsRoot(profileId), clientId ~ ".json");
    }

    private string requestPath(string profileId, string requestId)
    {
        return buildPath(requestsRoot(profileId), requestId, "request.json");
    }

    private string resultPath(string profileId, string requestId)
    {
        return buildPath(requestsRoot(profileId), requestId, "result.json");
    }

    private string artifactFilePath(string profileId, string requestId, string storedFilename)
    {
        return buildPath(requestsRoot(profileId), requestId, "artifacts", safeFilename(storedFilename));
    }

    private string artifactMetaPath(string profileId, string requestId, string artifactId)
    {
        return buildPath(requestsRoot(profileId), requestId, "artifacts", requireSafeIdToken(artifactId) ~ ".json");
    }

    private string clientsRoot(string profileId)
    {
        return buildPath(profileClientToolsRoot(profileId), "clients");
    }

    private string requestsRoot(string profileId)
    {
        return buildPath(profileClientToolsRoot(profileId), "requests");
    }

    private string profileClientToolsRoot(string profileId)
    {
        return buildPath(enforceProfileRoot(profileId), "client-tools");
    }

    private string enforceProfileRoot(string profileId)
    {
        auto token = requireSafeIdToken(profileId);
        auto root = absolutePath(buildNormalizedPath(buildPath(profilesRoot, token)));
        enforce(root == profilesRoot || root.startsWith(profilesRoot ~ dirSeparator), "Profile path escaped root");
        enforce(exists(root) && isDir(root), "Profile not found");
        return root;
    }
}

private string jsonArray(scope const string[] values)
{
    auto output = appender!string;
    output.put("[");
    foreach (index, value; values) {
        if (index) output.put(",");
        output.put(value);
    }
    output.put("]");
    return output.data;
}

private string required(string value, string label)
{
    enforce(value.length, label ~ " is required");
    return value;
}

private string safeFilename(string value)
{
    auto text = baseName(required(value, "filename"));
    auto output = appender!string;
    foreach (ch; text) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            output.put(ch);
        } else if (ch == '-' || ch == '_' || ch == '.') {
            output.put(ch);
        } else {
            output.put("-");
        }
    }
    auto result = output.data.strip;
    enforce(result.length, "filename is empty");
    return result;
}

private string newRequestId()
{
    return "ctr-" ~ randomUUID().toString();
}
