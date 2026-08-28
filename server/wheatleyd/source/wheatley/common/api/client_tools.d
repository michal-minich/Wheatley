module wheatley.common.api.client_tools;

import std.json : JSONValue;

import wheatley.common.json.object :
    jsonArrayRaw,
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonObjectOrNullRaw,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

struct ClientToolAdvertisement
{
    string clientId;
    string deviceId;
    string label;
    string capabilitiesJson;
    string metadataJson;
}

struct ClientToolRequestCreate
{
    string requestId;
    string sessionId;
    string turnId;
    string toolCallId;
    string clientId;
    string target;
    string capability;
    string argumentsJson;
    long timeoutMs;
}

struct ClientToolRequest
{
    string requestId;
    string profileId;
    string status;
    string createdAt;
    string updatedAt;
    string sessionId;
    string turnId;
    string toolCallId;
    string clientId;
    string target;
    string capability;
    string argumentsJson;
    long timeoutMs;
}

struct ClientToolResultCreate
{
    string clientId;
    bool ok;
    string contentJson;
    string artifactsJson;
    string errorJson;
}

ClientToolAdvertisement clientToolAdvertisementFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ClientToolAdvertisement(
        json.text("client_id"),
        json.text("device_id"),
        json.text("label"),
        json.arrayRaw("capabilities"),
        json.objectRaw("metadata"),
    );
}

string clientToolAdvertisementJson(ClientToolAdvertisement request)
{
    return jsonObject([
        jsonStringField("client_id", request.clientId),
        jsonStringField("device_id", request.deviceId),
        jsonStringField("label", request.label),
        jsonRawField("capabilities", jsonArrayRaw(request.capabilitiesJson)),
        jsonRawField("metadata", jsonObjectRaw(request.metadataJson)),
    ]);
}

ClientToolRequestCreate clientToolRequestCreateFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ClientToolRequestCreate(
        json.text("request_id"),
        json.text("session_id"),
        json.text("turn_id"),
        json.text("tool_call_id"),
        json.text("client_id"),
        json.text("target"),
        json.text("capability"),
        json.objectRaw("arguments"),
        json.integer("timeout_ms"),
    );
}

ClientToolRequest clientToolRequestFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ClientToolRequest(
        json.text("request_id"),
        json.text("profile_id"),
        json.text("status"),
        json.text("created_at"),
        json.text("updated_at"),
        json.text("session_id"),
        json.text("turn_id"),
        json.text("tool_call_id"),
        json.text("client_id"),
        json.text("target"),
        json.text("capability"),
        json.objectRaw("arguments"),
        json.integer("timeout_ms"),
    );
}

ClientToolRequest[] clientToolRequestsFromJson(JSONValue payload)
{
    ClientToolRequest[] result;
    auto requests = Json.object(payload).array("requests");
    foreach (item; requests.value.array) {
        result ~= clientToolRequestFromJson(Json.object(item).object("request").value);
    }
    return result;
}

ClientToolResultCreate clientToolResultCreateFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ClientToolResultCreate(
        json.text("client_id"),
        json.boolean("ok"),
        json.arrayRaw("content"),
        json.arrayRaw("artifacts"),
        json.objectOrNullRaw("error"),
    );
}

string clientToolResultCreateJson(ClientToolResultCreate request)
{
    return jsonObject([
        jsonStringField("client_id", request.clientId),
        jsonBoolField("ok", request.ok),
        jsonRawField("content", jsonArrayRaw(request.contentJson)),
        jsonRawField("artifacts", jsonArrayRaw(request.artifactsJson)),
        jsonRawField("error", jsonObjectOrNullRaw(request.errorJson)),
    ]);
}

string clientToolUploadedArtifactJson(JSONValue payload)
{
    return Json.object(payload).object("artifact").value.toString();
}
