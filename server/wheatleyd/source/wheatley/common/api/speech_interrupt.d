module wheatley.common.api.speech_interrupt;

import std.json : JSONValue;

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;

struct SpeechInterruptTranscription
{
    string text;
    string language;
    long durationMs;
}

string speechInterruptTranscriptionJson(SpeechInterruptTranscription value)
{
    return jsonObject([
        jsonStringField("text", value.text),
        jsonStringField("language", value.language),
        jsonLongField("duration_ms", value.durationMs),
    ]);
}

SpeechInterruptTranscription speechInterruptTranscriptionFromJson(JSONValue value)
{
    auto json = Json.object(value);
    return SpeechInterruptTranscription(
        json.text("text"),
        json.text("language"),
        json.integer("duration_ms"),
    );
}
