module wheatley.server.api.runtime.audio_playback_responses;

import std.conv : to;
import std.exception : enforce;

import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.common.api.audio_playback : audioPlaybackEventFromJson;
import wheatley.common.api.session : SessionKey;
import wheatley.common.json.object :
    jsonBoolField,
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.api.http.json_response : handleJson;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.voice.runtime : VoiceRuntime;

void audioPlaybackEventResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    VoiceRuntime voice,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, () {
        auto profileId = requireProfileId(req, store);
        auto event = audioPlaybackEventFromJson(profileId, Json.bodyObject(req).value);
        auto turn = store.findTurn(event.session, event.turnId);
        if (!turn.id.length)
            turn = store.findTurnBySubmission(event.session, event.turnId);
        enforce(turn.id.length, "Playback turn not found");
        event.turnId = turn.id;
        auto receipt = voice.observePlayback(event);
        return jsonObject([
            jsonBoolField("ok", true),
            jsonStringField("turn_id", receipt.turnId),
            jsonStringField("output_id", receipt.outputId),
            jsonStringField("kind", receipt.kind.to!string),
            jsonBoolField("speaking", receipt.speaking),
        ]);
    });
}
