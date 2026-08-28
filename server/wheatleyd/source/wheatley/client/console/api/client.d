module wheatley.client.console.api.client;

import core.time : dur;
import std.array : Appender, appender;
import std.exception : enforce;
import std.file : read, write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : baseName;
import std.socket : AddressFamily;
import std.string : strip;

import vibe.http.client : HTTPClientSettings, requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAll, readAllUTF8;

import wheatley.client.console.api.paths :
    acceptedVoiceCommitStreamUrl,
    audioPlaybackEventsUrl,
    clientToolArtifactUploadUrl,
    clientToolClientsUrl,
    clientToolRequestResultUrl,
    clientToolRequestsUrl,
    generatedAudioUrl,
    profileStartupUrl,
    profileStartupStreamUrl,
    speechInterruptUrl,
    stopTextTurnUrl,
    textTurnStreamUrl,
    thinkingMusicUrl,
    turnClientMetricsUrl,
    ttsUrl,
    clientConfigUrl;
import wheatley.client.console.api.paths :
    codexEventsUrl,
    sessionPresentationUrl,
    sessionQueueUrl,
    sessionTurnEventsUrl;
import wheatley.client.console.api.sse_events : readConsoleSseEvents;
import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.api.client_tools :
    ClientToolAdvertisement,
    ClientToolResultCreate,
    clientToolAdvertisementJson,
    clientToolResultCreateJson;
import wheatley.common.api.media : thinkingMusicAssetSelectionFromJson;
import wheatley.common.api.profile_startup :
    ProfileStartupRequest,
    ProfileStartupResult,
    ProfileStartupState,
    profileStartupStateFromJson,
    profileStartupRequestJson;
import wheatley.common.api.reasoning : ReasoningMode, reasoningModeText;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.speech_interrupt :
    SpeechInterruptTranscription,
    speechInterruptTranscriptionFromJson;
import wheatley.common.api.text_turn : TextTurnRequest, textTurnRequestJson;
import wheatley.common.api.tts : TtsRequest, TtsResponse, ttsRequestJson, ttsResponseFromJson;
import wheatley.common.api.audio_playback : AudioPlaybackEvent, audioPlaybackEventJson;
import wheatley.client.console.api.startup_events : readConsoleStartupEvents;
import wheatley.client.console.text.events : readConsoleTextTurnEvents;
import wheatley.client.console.text.types : ConsoleTextTurnResult;

struct ConsoleAcceptedVoiceCommitRequest
{
    string sessionId;
    string submissionId;
    ReasoningMode reasoningMode;
    string model;
    ulong replayCursor;
}

/// Server-owned preferences shared by every client using one profile.
struct ConsoleProfilePreferences
{
    string model;
    ReasoningMode reasoningMode;
    bool autoSpeak;
    bool playMusic;
    bool keepMicrophoneOn;
    int speechCommitDelaySeconds;
}

class ConsoleApiClient
{
    private string apiBase;

    this(string apiBase)
    {
        this.apiBase = apiBase;
    }

    ProfileStartupState profileStartupState(string profileId, string language)
    {
        ProfileStartupState state;
        requestHTTP(profileStartupUrl(apiBase, profileId, language), (scope httpRequest) {
            httpRequest.method = HTTPMethod.GET;
        }, (scope response) {
            auto payload = parseJSON(readTextResponse(response, "Profile startup state"));
            state = profileStartupStateFromJson(payload);
        }, httpSettings());
        return state;
    }

    ConsoleProfilePreferences profilePreferences(string profileId)
    {
        auto payload = parseJSON(getJson(
            clientConfigUrl(apiBase, "web"),
            "Client config",
        ));
        return consoleProfilePreferencesFromJson(payload, profileId);
    }

    string sessionPresentation(string profileId, string sessionId)
    {
        return getJson(
            sessionPresentationUrl(apiBase, profileId, sessionId),
            "Session presentation",
        );
    }

    string sessionQueue(string profileId, string sessionId)
    {
        return getJson(
            sessionQueueUrl(apiBase, profileId, sessionId),
            "Session queue",
        );
    }

    void streamCodexEvents(
        string profileId,
        string sessionId,
        long afterSequence,
        void delegate(string dataJson) onEvent,
        bool delegate() keepRunning = null,
    )
    {
        requestHTTP(
            codexEventsUrl(apiBase, profileId, sessionId, afterSequence),
            (scope request) { request.method = HTTPMethod.GET; },
            (scope response) {
                enforceHttpOk(response, "Codex events");
                readConsoleSseEvents(response.bodyReader, (event) {
                    if (keepRunning !is null && !keepRunning()) return false;
                    if (event.name == "heartbeat") return true;
                    enforce(event.name == "codex", "Unsupported Codex event: " ~ event.name);
                    onEvent(event.data);
                    return true;
                });
            },
            httpSettings(),
        );
    }

    void streamSessionTurnEvents(
        string profileId,
        string sessionId,
        long afterSequence,
        void delegate(string dataJson) onConversation,
        void delegate(string dataJson) onChanged = null,
        bool delegate() keepRunning = null,
    )
    {
        requestHTTP(
            sessionTurnEventsUrl(apiBase, profileId, sessionId, afterSequence),
            (scope request) { request.method = HTTPMethod.GET; },
            (scope response) {
                enforceHttpOk(response, "Session turn events");
                readConsoleSseEvents(response.bodyReader, (event) {
                    if (keepRunning !is null && !keepRunning()) return false;
                    if (event.name == "heartbeat") return true;
                    if (event.name == "changed") {
                        if (onChanged !is null) onChanged(event.data);
                        return true;
                    }
                    enforce(event.name == "conversation",
                        "Unsupported session turn event: " ~ event.name);
                    onConversation(event.data);
                    return true;
                });
            },
            httpSettings(),
        );
    }

    void reportAudioPlayback(AudioPlaybackEvent event)
    {
        requestHTTP(audioPlaybackEventsUrl(apiBase, event.session.profileId), (scope httpRequest) {
            httpRequest.method = HTTPMethod.POST;
            httpRequest.writeBody(
                cast(ubyte[]) audioPlaybackEventJson(event),
                "application/json; charset=UTF-8",
            );
        }, (scope response) {
            enforceHttpOk(response, "Audio playback acknowledgement");
        }, audioPlaybackHttpSettings());
    }

    double downloadThinkingMusic(string profileId, string targetPath)
    {
        auto selection = thinkingMusicAssetSelectionFromJson(parseJSON(getJson(
            thinkingMusicUrl(apiBase, profileId),
            "Thinking music selection",
        )));
        requestHTTP(generatedAudioUrl(apiBase, selection.asset.url), (scope httpRequest) {
            httpRequest.method = HTTPMethod.GET;
        }, (scope response) {
            enforceHttpOk(response, "Thinking music asset request");
            write(targetPath, response.bodyReader.readAll());
        }, httpSettings());
        return selection.gainDb;
    }

    ConsoleTextTurnResult streamTextTurn(
        string profileId,
        TextTurnRequest request,
        void delegate(string token) onToken = null,
        void delegate(string dataJson) onTool = null,
        void delegate(string dataJson) onStatus = null,
        void delegate(string dataJson) onReasoning = null,
        void delegate(ulong sequence) onReplayCursor = null,
        void delegate(string turnId, ulong sequence) onTerminal = null,
    )
    {
        ConsoleTextTurnResult result;
        requestHTTP(textTurnStreamUrl(apiBase, profileId), (scope httpRequest) {
            httpRequest.method = HTTPMethod.POST;
            httpRequest.writeBody(cast(ubyte[]) textTurnRequestJson(request), "application/json; charset=UTF-8");
        }, (scope response) {
            enforceHttpOk(response, "Text turn request");
            result = readConsoleTextTurnEvents(
                response.bodyReader,
                SessionKey(profileId, request.sessionId),
                cast(ulong) request.afterSequence,
                onToken,
                onTool,
                onStatus,
                onReasoning,
                onReplayCursor,
                onTerminal,
            );
        }, httpSettings());
        return result;
    }

    ConsoleTextTurnResult streamAcceptedVoiceCommit(
        string profileId,
        ConsoleAcceptedVoiceCommitRequest request,
        void delegate(string token) onToken = null,
        void delegate(string dataJson) onTool = null,
        void delegate(string dataJson) onStatus = null,
        void delegate(string dataJson) onReasoning = null,
        void delegate(ulong sequence) onReplayCursor = null,
        void delegate(string turnId, ulong sequence) onTerminal = null,
    )
    {
        enforce(request.sessionId.length, "Accepted voice session is required");
        enforce(request.submissionId.length, "Accepted voice submission is required");
        ConsoleTextTurnResult result;
        requestHTTP(acceptedVoiceCommitStreamUrl(apiBase, profileId, request.submissionId), (scope httpRequest) {
            httpRequest.method = HTTPMethod.POST;
            httpRequest.writeBody(cast(ubyte[]) jsonObject([
                jsonLongField("after_sequence", cast(long) request.replayCursor),
                jsonStringField("reasoning_mode", reasoningModeText(request.reasoningMode)),
                jsonStringField("model", request.model),
            ]), "application/json; charset=UTF-8");
        }, (scope response) {
            enforceHttpOk(response, "Accepted voice commit request");
            result = readConsoleTextTurnEvents(
                response.bodyReader,
                SessionKey(profileId, request.sessionId),
                request.replayCursor,
                onToken,
                onTool,
                onStatus,
                onReasoning,
                onReplayCursor,
                onTerminal,
            );
        }, httpSettings());
        return result;
    }

    ProfileStartupResult streamStartup(
        string profileId,
        string language,
        string mode,
        string resumeSessionId,
        string model,
        void delegate(string kind, string message) onSystemMessage,
    )
    {
        ProfileStartupResult result;
        requestHTTP(profileStartupStreamUrl(apiBase, profileId), (scope httpRequest) {
            httpRequest.method = HTTPMethod.POST;
            auto body = profileStartupRequestJson(ProfileStartupRequest(
                language,
                mode,
                resumeSessionId,
                model,
            ));
            httpRequest.writeBody(cast(ubyte[]) body, "application/json; charset=UTF-8");
        }, (scope response) {
            enforceHttpOk(response, "Startup request");
            result = readConsoleStartupEvents(response.bodyReader, onSystemMessage);
        }, httpSettings());
        return result;
    }

    TtsResponse synthesizeSpeech(string profileId, string text, string language)
    {
        TtsResponse result;
        requestHTTP(ttsUrl(apiBase, profileId), (scope httpRequest) {
            httpRequest.method = HTTPMethod.POST;
            auto body = ttsRequestJson(TtsRequest(text, language));
            httpRequest.writeBody(cast(ubyte[]) body, "application/json; charset=UTF-8");
        }, (scope response) {
            result = ttsResponseFromJson(parseJSON(readTextResponse(response, "TTS request")));
        }, httpSettings());
        return result;
    }

    SpeechInterruptTranscription transcribeSpeechInterrupt(
        string profileId,
        string audioPath,
        string language,
    )
    {
        auto boundary = "wheatley-speech-interrupt";
        auto body = multipartSpeechInterruptBody(boundary, audioPath, language);
        SpeechInterruptTranscription result;
        requestHTTP(speechInterruptUrl(apiBase, profileId), (scope httpRequest) {
            httpRequest.method = HTTPMethod.POST;
            httpRequest.writeBody(body, "multipart/form-data; boundary=" ~ boundary);
        }, (scope response) {
            result = speechInterruptTranscriptionFromJson(parseJSON(
                readTextResponse(response, "Speech interrupt transcription"),
            ));
        }, httpSettings());
        return result;
    }

    void stopTextTurn(string profileId, string sessionId, string turnId)
    {
        postJson(
            stopTextTurnUrl(apiBase, profileId, turnId),
            format!`{"session_id":%s}`(JSONValue(sessionId).toString()),
            "Stop text turn",
        );
    }

    void downloadGeneratedAudio(TtsResponse result, string targetPath)
    {
        requestHTTP(generatedAudioUrl(apiBase, result.audioUrl), (scope httpRequest) {
            httpRequest.method = HTTPMethod.GET;
        }, (scope response) {
            enforceHttpOk(response, "Generated audio request");
            write(targetPath, response.bodyReader.readAll());
        }, httpSettings());
    }

    string postTurnClientMetrics(
        string profileId,
        string sessionId,
        string turnId,
        string metricsJson,
    )
    {
        return postJson(
            turnClientMetricsUrl(apiBase, profileId, turnId),
            jsonObject([
                jsonStringField("session_id", sessionId),
                jsonRawField("metrics", jsonObjectRaw(metricsJson)),
            ]),
            "Turn client metrics",
        );
    }

    string advertiseClientTools(
        string profileId,
        ClientToolAdvertisement advertisement,
    )
    {
        return postJson(
            clientToolClientsUrl(apiBase, profileId),
            clientToolAdvertisementJson(advertisement),
            "Client tool advertisement",
        );
    }

    string pendingClientToolRequests(string profileId, string clientId)
    {
        import std.uri : encodeComponent;

        auto url = clientToolRequestsUrl(apiBase, profileId) ~
            "?status=pending&client_id=" ~ encodeComponent(clientId);
        return getJson(url, "Client tool request polling");
    }

    string completeClientToolRequest(string profileId, string requestId, ClientToolResultCreate result)
    {
        return postJson(
            clientToolRequestResultUrl(apiBase, profileId, requestId),
            clientToolResultCreateJson(result),
            "Client tool result",
        );
    }

    string uploadClientToolArtifact(
        string profileId,
        string requestId,
        string path,
        string artifactId,
        string kind,
        string mimeType,
    )
    {
        auto boundary = "wheatley-client-tool-" ~ requestId;
        auto body = multipartArtifactBody(boundary, path, artifactId, kind, mimeType);
        string responseText;
        requestHTTP(
            clientToolArtifactUploadUrl(apiBase, profileId, requestId),
            (scope httpRequest) {
                httpRequest.method = HTTPMethod.POST;
                httpRequest.writeBody(body, "multipart/form-data; boundary=" ~ boundary);
            },
            (scope response) {
                responseText = readTextResponse(response, "Client tool artifact upload");
            },
            httpSettings(),
        );
        return responseText;
    }

    private string getJson(string url, string label)
    {
        string responseText;
        requestHTTP(url, (scope httpRequest) {
            httpRequest.method = HTTPMethod.GET;
        }, (scope response) {
            responseText = readTextResponse(response, label);
        }, httpSettings());
        return responseText;
    }

    private string postJson(string url, string body, string label)
    {
        string responseText;
        requestHTTP(url, (scope httpRequest) {
            httpRequest.method = HTTPMethod.POST;
            httpRequest.writeBody(cast(ubyte[]) body, "application/json; charset=UTF-8");
        }, (scope response) {
            responseText = readTextResponse(response, label);
        }, httpSettings());
        return responseText;
    }
}

private ConsoleProfilePreferences consoleProfilePreferencesFromJson(
    JSONValue payload,
    string profileId,
)
{
    auto config = Json.object(payload);
    auto speechCommitDelaySeconds = config.intRange("speech_commit_delay_seconds", 1, 12);
    foreach (entry; config.array("profiles").value.array) {
        auto profile = Json.object(entry);
        if (profile.text("profile_id") != profileId) continue;
        return ConsoleProfilePreferences(
            profile.text("model"),
            profile.enumeration!ReasoningMode("reasoning_mode"),
            profile.boolean("auto_speak"),
            profile.boolean("play_music"),
            profile.boolean("keep_microphone_on"),
            speechCommitDelaySeconds,
        );
    }
    throw new Exception("Client config is missing profile: " ~ profileId);
}

unittest
{
    auto preferences = consoleProfilePreferencesFromJson(parseJSON(`{
        "speech_commit_delay_seconds": 6,
        "profiles": [{
            "profile_id": "wheatley",
            "model": "lmstudio/unsloth/qwen3.8-27b",
            "reasoning_mode": "low",
            "auto_speak": true,
            "play_music": true,
            "keep_microphone_on": false
        }]
    }`), "wheatley");
    assert(preferences.model == "lmstudio/unsloth/qwen3.8-27b");
    assert(preferences.reasoningMode == ReasoningMode.low);
    assert(preferences.autoSpeak);
    assert(preferences.playMusic);
    assert(!preferences.keepMicrophoneOn);
    assert(preferences.speechCommitDelaySeconds == 6);
}

private void enforceHttpOk(Response)(Response response, string label)
{
    if (httpOk(response.statusCode)) return;
    auto body = response.bodyReader.readAllUTF8();
    throw httpFailure(label, response.statusCode, body);
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
    return new Exception(format!"%s failed with HTTP %s: %s"(
        label,
        statusCode,
        body.strip,
    ));
}

private ubyte[] multipartArtifactBody(
    string boundary,
    string path,
    string artifactId,
    string kind,
    string mimeType,
)
{
    auto output = appender!(ubyte[]);
    putMultipartField(output, boundary, "artifact_id", artifactId);
    putMultipartField(output, boundary, "kind", kind);
    putMultipartField(output, boundary, "mime_type", mimeType);
    putMultipartFile(output, boundary, "artifact", baseName(path), mimeType, cast(ubyte[]) read(path));
    putAscii(output, "--" ~ boundary ~ "--\r\n");
    return output.data;
}

private ubyte[] multipartSpeechInterruptBody(string boundary, string path, string language)
{
    auto output = appender!(ubyte[]);
    putMultipartField(output, boundary, "language", language);
    putMultipartFile(output, boundary, "audio", baseName(path), "audio/wav", cast(ubyte[]) read(path));
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
    ubyte[] bytes,
)
{
    putAscii(output, "--" ~ boundary ~ "\r\n");
    putAscii(
        output,
        `Content-Disposition: form-data; name="` ~ name ~ `"; filename="` ~ filename ~ `"` ~ "\r\n",
    );
    putAscii(output, "Content-Type: " ~ (mimeType.length ? mimeType : "application/octet-stream") ~ "\r\n\r\n");
    output.put(bytes);
    putAscii(output, "\r\n");
}

private void putAscii(ref Appender!(ubyte[]) output, string text)
{
    output.put(cast(ubyte[]) text);
}

private HTTPClientSettings httpSettings()
{
    auto settings = new HTTPClientSettings;
    settings.connectTimeout = dur!"msecs"(2_000);
    settings.readTimeout = dur!"msecs"(600_000);
    settings.dnsAddressFamily = AddressFamily.INET;
    return settings;
}

private HTTPClientSettings audioPlaybackHttpSettings()
{
    auto settings = new HTTPClientSettings;
    settings.connectTimeout = dur!"msecs"(500);
    settings.readTimeout = dur!"msecs"(2_000);
    settings.dnsAddressFamily = AddressFamily.INET;
    return settings;
}
