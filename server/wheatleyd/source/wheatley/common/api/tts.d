module wheatley.common.api.tts;

import std.json : JSONValue;

import wheatley.common.json.object :
    jsonObject,
    jsonStringField,
    jsonUlongField;
import wheatley.common.json.read : Json;

struct TtsRequest
{
    string text;
    string language;
}

struct TtsResponse
{
    string artifactId;
    string profileId;
    string createdAt;
    string mediaType;
    ulong bytes;
    string sha256;
    string provider;
    string model;
    string voice;
    string language;
    string relativePath;
    string audioUrl;
}

TtsRequest ttsRequestFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return TtsRequest(
        json.text("text"),
        json.token("language"),
    );
}

string ttsRequestJson(TtsRequest request)
{
    return jsonObject([
        jsonStringField("text", request.text),
        jsonStringField("language", request.language),
    ]);
}

TtsResponse ttsResponseFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return TtsResponse(
        json.text("artifact_id"),
        json.text("profile_id"),
        json.text("created_at"),
        json.text("media_type"),
        requiredTtsBytes(json),
        json.text("sha256"),
        json.text("provider"),
        json.text("model"),
        json.text("voice"),
        json.text("language"),
        json.text("relative_path"),
        json.text("audio_url"),
    );
}

private ulong requiredTtsBytes(Json json)
{
    return cast(ulong) json.integer("bytes", 0);
}

string ttsResponseJson(TtsResponse response)
{
    return jsonObject([
        jsonStringField("artifact_id", response.artifactId),
        jsonStringField("profile_id", response.profileId),
        jsonStringField("created_at", response.createdAt),
        jsonStringField("media_type", response.mediaType),
        jsonUlongField("bytes", response.bytes),
        jsonStringField("sha256", response.sha256),
        jsonStringField("provider", response.provider),
        jsonStringField("model", response.model),
        jsonStringField("voice", response.voice),
        jsonStringField("language", response.language),
        jsonStringField("relative_path", response.relativePath),
        jsonStringField("audio_url", ttsAudioUrl(response)),
    ]);
}

string ttsAudioUrl(TtsResponse response)
{
    return response.audioUrl.length
        ? response.audioUrl
        : "/api/profiles/" ~ response.profileId ~ "/generated-audio/" ~ response.artifactId;
}
