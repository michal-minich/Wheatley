module wheatley.client.console.live.types;

import std.format : format;

import wheatley.common.api.live_audio : LiveAudioStartRequest;
import wheatley.common.api.text_turn : TextTurnMetrics;
import wheatley.common.api.live_audio_events :
    LiveAudioStatus,
    LiveAudioThinkingMusic;
import wheatley.common.json.object : jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField,
    jsonUlongField;

struct ConsoleLiveAudioRequest
{
    LiveAudioStartRequest start;
    string ffmpegPath;
    string ffmpegAudioInput;
    int simulateUploadKbps;
}

struct ConsoleLiveAudioResult
{
    string turnId;
    string profileId;
    string sessionId;
    string userText;
    string assistantText;
    string language;
    string sessionResumeChoice;
    string sessionResumeTranscript;
    bool stopped;
    TextTurnMetrics metrics;
    ConsoleLiveAudioClientMetrics clientMetrics;
}

struct ConsoleLiveAudioClientMetrics
{
    string clientAudioFormat;
    ulong clientAudioBytes;
    ulong clientSentBytes;
    ulong clientFramesSent;
    long clientEncodeMs;
    long clientSendMs;
    long clientMaxSendBacklogMs;
    bool hasUserTotalMs;
    long userTotalMs;
    string ttsModel;
    bool hasTtsFirstAudioMs;
    long ttsFirstAudioMs;
    long ttsSynthesisMs;
    long ttsChunks;
    bool hasTtsSpokenAudioSeconds;
    double ttsSpokenAudioSeconds;
    bool hasEndpointToFirstSpokenAudioMs;
    long endpointToFirstSpokenAudioMs;
}

struct ConsoleLiveAudioHandlers
{
    void delegate(LiveAudioStatus status) onStatus;
    void delegate(string text) onPreviewTranscript;
    void delegate(string text, string userText, string language) onFinalTranscript;
    void delegate(LiveAudioThinkingMusic command) onThinkingMusic;
    void delegate(string token) onToken;
    void delegate(string dataJson) onTool;
    void delegate(string message) onError;
    void delegate(string dataJson) onReasoning;
    void delegate(
        string text,
        string userText,
        string language,
        string userAudioArtifactId,
    ) onAcceptedVoice;
    void delegate(ulong sequence) onConversationReplayCursor;
    void delegate(string turnId, ulong sequence) onConversationTerminal;
}

bool hasConsoleLiveAudioClientMetrics(ConsoleLiveAudioClientMetrics metrics)
{
    return metrics.clientFramesSent > 0
        || metrics.hasUserTotalMs
        || metrics.ttsChunks > 0
        || metrics.hasEndpointToFirstSpokenAudioMs;
}

string consoleLiveAudioClientMetricsJson(ConsoleLiveAudioClientMetrics metrics)
{
    return jsonObject([
        metrics.clientFramesSent > 0 ? jsonRawField("audio", jsonObject([
                jsonUlongField("client_audio_bytes", metrics.clientAudioBytes),
                jsonUlongField("client_sent_bytes", metrics.clientSentBytes),
                jsonUlongField("client_frames_sent", metrics.clientFramesSent),
                jsonLongField("client_encode_ms", metrics.clientEncodeMs),
                metrics.clientAudioBytes > 0
                ? jsonRawField(
                    "client_encode_realtime_ratio",
                    format!"%.3f"(
                    cast(double) metrics.clientEncodeMs / rawPcmAudioMs(metrics.clientAudioBytes)),
                ): "",
                jsonLongField("client_send_ms", metrics.clientSendMs),
                jsonLongField("client_max_send_backlog_ms", metrics.clientMaxSendBacklogMs),
                jsonStringField("client_audio_format", metrics.clientAudioFormat),
            ])): "",
        metrics.hasUserTotalMs ? jsonRawField("user", jsonObject([
                jsonLongField("total_ms", metrics.userTotalMs),
            ])): "",
        metrics.ttsChunks > 0 ? jsonRawField("tts", jsonObject([
                jsonStringField("model", metrics.ttsModel),
                metrics.hasTtsFirstAudioMs ? jsonLongField("first_audio_ms", metrics.ttsFirstAudioMs): "",
                jsonLongField("synthesis_ms", metrics.ttsSynthesisMs),
                jsonLongField("chunks", metrics.ttsChunks),
                metrics.hasTtsSpokenAudioSeconds
                ? jsonRawField("spoken_audio_seconds", format!"%.3f"(metrics.ttsSpokenAudioSeconds)): "",
            ])): "",
        metrics.hasEndpointToFirstSpokenAudioMs ? jsonRawField("turn", jsonObject([
                jsonLongField("endpoint_to_first_spoken_audio_ms", metrics
                    .endpointToFirstSpokenAudioMs),
            ])): "",
    ]);
}

private double rawPcmAudioMs(ulong pcmBytes)
{
    enum bytesPerSecond = 32_000.0;
    return cast(double) pcmBytes / bytesPerSecond * 1_000.0;
}
