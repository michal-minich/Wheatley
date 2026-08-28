module wheatley.common.api.live_audio;

import std.exception : enforce;
import std.json : JSONValue, parseJSON;

import wheatley.common.api.reasoning : ReasoningMode, reasoningModeText;
import wheatley.common.choice : requireChoice;
import wheatley.common.api.text_turn : TextTurnRequest;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

struct LiveAudioFormat
{
    string format = "pcm_s16le";
    int sampleRate = 16_000;
    int channels = 1;
    int bitrate;
    int frameMs;
    string application;
    int complexity;
    string container;
}

struct LiveAudioStartRequest
{
    TextTurnRequest turn;
    alias turn this;

    LiveAudioFormat audio;
    string purpose;
    bool prewarmExistingSession;
    string audioInputSelector;
    string audioInputLabel;
    int silenceSeconds;
}

struct LiveAudioCommit
{
    ReasoningMode reasoningMode;
    string model;
}

LiveAudioStartRequest liveAudioStartFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    json.choice!("start")("type");
    auto purpose = json.choice!("turn", "session_resume")("purpose");
    return LiveAudioStartRequest(
        TextTurnRequest(
            json.text("session_id"),
            json.text("text"),
            json.nonEmpty("submission_id"),
            json.text("device_id"),
            json.text("language"),
            "",
            json.boolean("load_memory"),
            json.enumeration!ReasoningMode("reasoning_mode"),
            json.text("model"),
            json.nonNegativeInt("after_sequence"),
        ),
        liveAudioFormatFromStart(json),
        purpose,
        json.boolean("prewarm_existing_session"),
        json.text("audio_input_selector"),
        json.text("audio_input_label"),
        purpose == "turn"
            ? json.intRange("silence_seconds", 1, 12)
            : json.intRange("silence_seconds", 0, 0),
    );
}

string liveAudioStartJson(LiveAudioStartRequest request)
{
    return jsonObject([
        jsonStringField("type", "start"),
        jsonStringField("session_id", request.sessionId),
        jsonStringField("submission_id", request.submissionId),
        jsonStringField("device_id", request.deviceId),
        jsonStringField("text", request.text),
        jsonStringField("language", request.language),
        jsonRawField("audio", liveAudioFormatJson(request.audio)),
        jsonBoolField("load_memory", request.loadMemory),
        jsonStringField("reasoning_mode", reasoningModeText(request.reasoningMode)),
        jsonStringField("model", request.model),
        jsonLongField("after_sequence", request.afterSequence),
        jsonStringField("purpose", request.purpose),
        jsonBoolField("prewarm_existing_session", request.prewarmExistingSession),
        jsonStringField("audio_input_selector", request.audioInputSelector),
        jsonStringField("audio_input_label", request.audioInputLabel),
        jsonLongField("silence_seconds", request.silenceSeconds),
    ]);
}

LiveAudioCommit liveAudioCommitFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    json.choice!("commit")("type");
    return LiveAudioCommit(
        json.enumeration!ReasoningMode("reasoning_mode"),
        json.text("model"),
    );
}

string liveAudioCommitJson(LiveAudioCommit commit)
{
    return jsonObject([
        jsonStringField("type", "commit"),
        jsonStringField("reasoning_mode", reasoningModeText(commit.reasoningMode)),
        jsonStringField("model", commit.model),
    ]);
}

string liveAudioConfigureJson(int silenceSeconds)
{
    return jsonObject([
        jsonStringField("type", "configure"),
        jsonLongField("silence_seconds", silenceSeconds),
    ]);
}

LiveAudioFormat liveAudioFormatFromStart(Json json)
{
    LiveAudioFormat result;

    auto audio = json.object("audio");

    result.format = audio.choice!("pcm_s16le", "opus")("format");
    result.sampleRate = audio.intRange("sample_rate", 16_000, 16_000);
    result.channels = audio.intRange("channels", 1, 1);
    result.frameMs = audio.positiveInt("frame_ms");
    result.bitrate = audio.nonNegativeInt("bitrate");
    result.application = audio.text("application");
    result.complexity = audio.intRange("complexity", 0, 10);
    result.container = audio.text("container");

    validateLiveAudioFormat(result);
    return result;
}

string liveAudioFormatJson(LiveAudioFormat format)
{
    validateLiveAudioFormat(format);
    return jsonObject([
        jsonStringField("format", format.format),
        jsonLongField("sample_rate", format.sampleRate),
        jsonLongField("channels", format.channels),
        jsonLongField("frame_ms", format.frameMs),
        jsonLongField("bitrate", format.bitrate),
        jsonStringField("application", format.application),
        jsonLongField("complexity", format.complexity),
        jsonStringField("container", format.container),
    ]);
}

void validateLiveAudioFormat(LiveAudioFormat format)
{
    enforce(format.sampleRate == 16_000, "JSON audio.sample_rate");
    enforce(format.channels == 1, "JSON audio.channels");
    enforce(format.frameMs > 0, "JSON audio.frame_ms");
    enforce(format.complexity >= 0 && format.complexity <= 10, "JSON audio.complexity");

    if (format.format == "opus") {
        enforce(format.bitrate > 0, "JSON audio.bitrate");
        requireChoice!("audio")(format.application);
        requireChoice!("ogg-opus")(format.container);
    } else {
        requireChoice!("pcm_s16le")(format.format);
        enforce(format.bitrate == 0, "JSON audio.bitrate");
        enforce(format.application.length == 0, "JSON audio.application");
        enforce(format.container.length == 0, "JSON audio.container");
    }
}

unittest
{
    auto pcmStart = parseJSON(`{"type":"start","session_id":"2026/07/14/10_00_00","text":"","submission_id":"session-resume-1","device_id":"","language":"","model":"","load_memory":false,"reasoning_mode":"off","after_sequence":0,"purpose":"session_resume","prewarm_existing_session":false,"audio_input_selector":":0","audio_input_label":"Yealink BH71","silence_seconds":0,"audio":{"format":"pcm_s16le","sample_rate":16000,"channels":1,"frame_ms":20,"bitrate":0,"application":"","complexity":0,"container":""}}`);
    auto pcmRequest = liveAudioStartFromJson(pcmStart);
    assert(pcmRequest.audio.format == "pcm_s16le");
    assert(pcmRequest.audio.frameMs == 20);
    assert(pcmRequest.purpose == "session_resume");
    assert(pcmRequest.silenceSeconds == 0);
    assert(!pcmRequest.prewarmExistingSession);
    assert(pcmRequest.audioInputSelector == ":0");
    assert(pcmRequest.audioInputLabel == "Yealink BH71");
    auto encodedPcmStart = parseJSON(liveAudioStartJson(pcmRequest));
    assert(encodedPcmStart.object["audio_input_label"].str == "Yealink BH71");
    assert(encodedPcmStart.object["silence_seconds"].integer == 0);
    assert(encodedPcmStart.object["audio"].object["bitrate"].integer == 0);

    auto opusStart = parseJSON(`{"type":"start","session_id":"2026/07/14/10_00_00","text":"","submission_id":"voice-turn-1","device_id":"","language":"","model":"","load_memory":false,"reasoning_mode":"off","after_sequence":0,"purpose":"turn","prewarm_existing_session":true,"audio_input_selector":"","audio_input_label":"","silence_seconds":4,"audio":{"format":"opus","sample_rate":16000,"channels":1,"bitrate":32000,"frame_ms":20,"application":"audio","complexity":3,"container":"ogg-opus"}}`);
    auto opusFormat = liveAudioFormatFromStart(Json.object(opusStart));
    assert(opusFormat.format == "opus");
    assert(opusFormat.bitrate == 32_000);
    assert(opusFormat.frameMs == 20);
    assert(opusFormat.application == "audio");
    assert(opusFormat.complexity == 3);
    assert(opusFormat.container == "ogg-opus");
    assert(liveAudioFormatJson(opusFormat).length);
    auto commit = liveAudioCommitFromJson(parseJSON(
        `{"type":"commit","reasoning_mode":"high","model":"pi:test/model"}`,
    ));
    assert(commit.reasoningMode == ReasoningMode.high);
    assert(commit.model == "pi:test/model");
    assert(parseJSON(liveAudioCommitJson(commit)).object["type"].str == "commit");

    auto configure = parseJSON(liveAudioConfigureJson(4));
    assert(configure.object["type"].str == "configure");
    assert(configure.object["silence_seconds"].integer == 4);

    auto turnStart = liveAudioStartFromJson(parseJSON(
        `{"type":"start","session_id":"2026/07/14/10_00_00","text":"","submission_id":"voice-turn-2","device_id":"","language":"","model":"","load_memory":true,"reasoning_mode":"off","after_sequence":0,"purpose":"turn","prewarm_existing_session":false,"audio_input_selector":"","audio_input_label":"","silence_seconds":4,"audio":{"format":"pcm_s16le","sample_rate":16000,"channels":1,"frame_ms":20,"bitrate":0,"application":"","complexity":0,"container":""}}`,
    ));
    assert(turnStart.purpose == "turn");
    assert(turnStart.silenceSeconds == 4);
    assert(parseJSON(liveAudioStartJson(turnStart)).object["silence_seconds"].integer == 4);
}
