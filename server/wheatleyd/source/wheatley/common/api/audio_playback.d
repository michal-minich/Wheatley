module wheatley.common.api.audio_playback;

import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue;

import wheatley.common.api.session : SessionKey;
import wheatley.common.json.object :
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;

enum AudioPlaybackEventKind
{
    queued,
    started,
    finished,
    cancelled,
    failed,
}

enum AudioPlaybackSource
{
    answer,
    reasoning,
}

struct AudioPlaybackEvent
{
    SessionKey session;
    string turnId;
    string outputId;
    AudioPlaybackSource source;
    AudioPlaybackEventKind kind;
    string adapter;
    string errorMessage;
}

AudioPlaybackEvent audioPlaybackEventFromJson(string profileId, JSONValue payload)
{
    auto json = Json.object(payload);
    auto event = AudioPlaybackEvent(
        SessionKey(profileId, json.nonEmpty("session_id")),
        json.nonEmpty("turn_id"),
        json.token("output_id"),
        json.enumeration!AudioPlaybackSource("source"),
        json.enumeration!AudioPlaybackEventKind("kind"),
        json.choice!("web_audio", "native_process")("adapter"),
        json.text("error_message"),
    );
    enforce(
        (event.kind == AudioPlaybackEventKind.failed) == (event.errorMessage.length > 0),
        "Playback failure must be the only event carrying an error message",
    );
    return event;
}

string audioPlaybackEventJson(AudioPlaybackEvent event)
{
    return jsonObject([
        jsonStringField("session_id", event.session.sessionId),
        jsonStringField("turn_id", event.turnId),
        jsonStringField("output_id", event.outputId),
        jsonStringField("source", event.source.to!string),
        jsonStringField("kind", event.kind.to!string),
        jsonStringField("adapter", event.adapter),
        jsonStringField("error_message", event.errorMessage),
    ]);
}

unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;

    auto event = AudioPlaybackEvent(
        SessionKey("tester", "2026/08/06/07_33_38"),
        "tester/sessions/2026/08/06/07_33_38/turns/07_34_00_123456",
        "speech-1",
        AudioPlaybackSource.answer,
        AudioPlaybackEventKind.started,
        "web_audio",
        "",
    );
    auto decoded = audioPlaybackEventFromJson("tester", parseJSON(audioPlaybackEventJson(event)));
    assert(decoded == event);

    auto failed = event;
    failed.kind = AudioPlaybackEventKind.failed;
    failed.errorMessage = "decode failed";
    assert(audioPlaybackEventFromJson(
        "tester",
        parseJSON(audioPlaybackEventJson(failed)),
    ) == failed);

    failed.errorMessage = "";
    assertThrown(audioPlaybackEventFromJson(
        "tester",
        parseJSON(audioPlaybackEventJson(failed)),
    ));
}
