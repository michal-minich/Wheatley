module wheatley.client.console.live.client;

import core.time : dur;
import std.algorithm.comparison : max;
import std.exception : enforce;
import std.json : parseJSON;

import vibe.http.client : HTTPClientSettings;
import vibe.http.websockets : WebSocket, WebSocketCloseReason, connectWebSocket;
import vibe.inet.url : URL;

import wheatley.client.console.api.paths : liveAudioTurnUrl;
import wheatley.client.console.live.capture : ConsoleAudioCapture;
import wheatley.client.console.live.types :
    ConsoleLiveAudioClientMetrics,
    ConsoleLiveAudioHandlers,
    ConsoleLiveAudioRequest,
    ConsoleLiveAudioResult;
import wheatley.client.console.live.socket : closeSocketQuietly;
import wheatley.common.api.live_audio : liveAudioStartJson;
import wheatley.common.api.live_audio : LiveAudioCommit, liveAudioCommitJson;
import wheatley.common.api.live_audio_events :
    LiveAudioStatus,
    liveAudioConversationEventFromJson,
    liveAudioMessageType,
    liveAudioVoiceEventFromJson,
    liveAudioThinkingMusicFromJson;
import wheatley.common.api.conversation_events :
    conversationReasoningEventJson,
    conversationToolEventJson;
import wheatley.common.conversation.events : ConversationEventKind;
import wheatley.common.voice.events : VoiceEventKind, voiceEventKindText;
import wheatley.common.json.read : Json;

ConsoleLiveAudioResult streamLiveAudioTurn(
    string apiBase,
    string profileId,
    ConsoleLiveAudioRequest request,
    ConsoleLiveAudioHandlers handlers = ConsoleLiveAudioHandlers.init,
)
{
    auto ws = connectWebSocket(URL(liveAudioTurnUrl(apiBase, profileId)), websocketSettings());
    auto result = ConsoleLiveAudioResult();
    result.sessionId = request.start.sessionId;
    ConsoleLiveAudioClientMetrics clientMetrics;
    ConsoleAudioCapture capture;
    bool finalReceived;
    bool acceptedArtifact;
    bool acceptedPersisted;
    bool done;
    string streamError;
    string captureError;
    ulong lastConversationSequence;
    string conversationTurnId;

    scope(exit) {
        stopCapture(capture, captureError, clientMetrics);
        closeSocketQuietly(ws, WebSocketCloseReason.normalClosure, "Done");
    }

    ws.send(startMessage(request));

    while (ws.connected && !done) {
        if (!ws.waitForData(dur!"msecs"(250))) {
            if (capture !is null && capture.error.length) throw new Exception(capture.error);
            continue;
        }

        auto message = Json.parse(ws.receiveText()).value;
        auto kind = liveAudioMessageType(message);
        switch (kind) {
            case "voice_event": {
                auto event = liveAudioVoiceEventFromJson(message);
                auto status = LiveAudioStatus(voiceEventKindText(event.kind), event.message.message);
                final switch (event.kind) {
                    case VoiceEventKind.ready:
                        enforce(event.ready.profileId == profileId, "Live audio ready profile changed");
                        enforce(event.ready.submissionId == request.start.submissionId,
                            "Live audio ready submission changed");
                        call(handlers.onStatus, LiveAudioStatus("ready", ""));
                        break;
                    case VoiceEventKind.listeningStarted:
                    case VoiceEventKind.listeningRetry:
                    case VoiceEventKind.listeningResumed:
                    case VoiceEventKind.candidateRejected:
                        if (capture is null) startCapture(capture, request, ws);
                        call(handlers.onStatus, status);
                        break;
                    case VoiceEventKind.listeningSuspended:
                        stopCapture(capture, captureError, clientMetrics);
                        call(handlers.onStatus, status);
                        break;
                    case VoiceEventKind.transcriptDraftSelected:
                    case VoiceEventKind.audioReceiving:
                    case VoiceEventKind.speechDetected:
                        call(handlers.onStatus, status);
                        break;
                    case VoiceEventKind.previewChanged:
                        call(handlers.onPreviewTranscript, event.preview.text);
                        break;
                    case VoiceEventKind.endpointReached:
                        stopCapture(capture, captureError, clientMetrics);
                        call(handlers.onStatus, status);
                        break;
                    case VoiceEventKind.transcriptAccepted: {
                        finalReceived = true;
                        auto transcript = event.transcript;
                        result.userText = transcript.userText;
                        result.language = transcript.language;
                        if (transcript.userAudioArtifactId.length) {
                            enforce(
                                transcript.userAudioArtifactId ==
                                    "runtime-user-audio:" ~ request.start.submissionId,
                                "Accepted voice artifact changed",
                            );
                            enforce(handlers.onAcceptedVoice !is null,
                                "Live audio accepted-voice persistence is required");
                            handlers.onAcceptedVoice(
                                transcript.text,
                                result.userText,
                                result.language,
                                transcript.userAudioArtifactId,
                            );
                            acceptedArtifact = true;
                            acceptedPersisted = true;
                        } else if (request.start.purpose == "turn") {
                            enforce(request.start.text.length,
                                "Live audio turn without accepted audio must provide text");
                        }
                        call(
                            handlers.onFinalTranscript,
                            transcript.text,
                            result.userText,
                            result.language,
                        );
                        ws.send(liveAudioCommitJson(LiveAudioCommit(
                            request.start.reasoningMode,
                            request.start.model,
                        )));
                        break;
                    }
                    case VoiceEventKind.sessionResumeChoice:
                        stopCapture(capture, captureError, clientMetrics);
                        result.sessionResumeChoice = event.sessionResumeChoice.choice;
                        result.sessionResumeTranscript = event.sessionResumeChoice.transcript;
                        done = true;
                        break;
                    case VoiceEventKind.failed:
                        stopCapture(capture, captureError, clientMetrics);
                        streamError = event.failed.message;
                        call(handlers.onError, streamError);
                        done = true;
                        break;
                }
                break;
            }
            case "thinking_music":
                if (handlers.onThinkingMusic !is null)
                    handlers.onThinkingMusic(liveAudioThinkingMusicFromJson(message));
                break;
            case "conversation_event": {
                auto event = liveAudioConversationEventFromJson(message);
                if (acceptedArtifact)
                    enforce(acceptedPersisted,
                        "Conversation arrived before accepted voice was persisted");
                enforce(event.session.profileId == profileId, "Conversation profile changed");
                enforce(event.session.sessionId == request.start.sessionId, "Conversation session changed");
                enforce(event.turnId.length, "Conversation turn ID is required");
                enforce(
                    !conversationTurnId.length || event.turnId == conversationTurnId,
                    "Conversation turn changed",
                );
                enforce(
                    event.sequence == lastConversationSequence + 1,
                    "Conversation event sequence gap",
                );
                lastConversationSequence = event.sequence;
                conversationTurnId = event.turnId;
                final switch (event.kind) {
                    case ConversationEventKind.status:
                        if (handlers.onConversationReplayCursor !is null)
                            handlers.onConversationReplayCursor(event.sequence);
                        call(handlers.onStatus, LiveAudioStatus(
                            event.status.code,
                            profileId ~ ": " ~ event.status.message,
                        ));
                        break;
                    case ConversationEventKind.assistantDelta:
                        if (handlers.onConversationReplayCursor !is null)
                            handlers.onConversationReplayCursor(event.sequence);
                        call(handlers.onToken, event.assistantDelta.text);
                        break;
                    case ConversationEventKind.tool:
                        if (handlers.onConversationReplayCursor !is null)
                            handlers.onConversationReplayCursor(event.sequence);
                        call(handlers.onTool, conversationToolEventJson(event.tool));
                        break;
                    case ConversationEventKind.artifact:
                        if (handlers.onConversationReplayCursor !is null)
                            handlers.onConversationReplayCursor(event.sequence);
                        call(handlers.onStatus, LiveAudioStatus(
                            "generated_image",
                            event.artifact.path,
                        ));
                        break;
                    case ConversationEventKind.reasoning:
                        if (handlers.onConversationReplayCursor !is null)
                            handlers.onConversationReplayCursor(event.sequence);
                        call(
                            handlers.onReasoning,
                            conversationReasoningEventJson(event.reasoning),
                        );
                        break;
                    case ConversationEventKind.completed:
                        stopCapture(capture, captureError, clientMetrics);
                        auto response = event.completed;
                        enforce(response.turn.profileId == profileId,
                            "Completed Conversation profile changed");
                        enforce(response.turn.turnId == conversationTurnId,
                            "Completed Conversation turn changed");
                        result.turnId = response.turn.turnId;
                        result.profileId = response.turn.profileId;
                        result.userText = response.turn.userText;
                        result.assistantText = response.turn.assistantText;
                        result.metrics = response.turn.metrics;
                        result.stopped = response.stopped;
                        if (handlers.onConversationTerminal !is null)
                            handlers.onConversationTerminal(conversationTurnId, event.sequence);
                        done = true;
                        break;
                    case ConversationEventKind.failed:
                        stopCapture(capture, captureError, clientMetrics);
                        streamError = event.failed.message;
                        if (handlers.onConversationTerminal !is null)
                            handlers.onConversationTerminal(conversationTurnId, event.sequence);
                        call(handlers.onError, streamError);
                        done = true;
                        break;
                }
                break;
            }
            default:
                throw new Exception("Unsupported live audio message type: " ~ kind);
        }
    }

    stopCapture(capture, captureError, clientMetrics);
    result.clientMetrics = clientMetrics;

    if (captureError.length && !done) throw new Exception(captureError);
    if (streamError.length) throw new Exception(streamError);
    enforce(finalReceived || done, "Live audio stream ended without final transcript");
    enforce(done, "Live audio stream ended without final response");
    return result;
}

private void startCapture(
    ref ConsoleAudioCapture capture,
    ConsoleLiveAudioRequest request,
    WebSocket ws,
)
{
    if (capture !is null) return;
    capture = new ConsoleAudioCapture(request, ws);
}

private void stopCapture(
    ref ConsoleAudioCapture capture,
    ref string captureError,
    ref ConsoleLiveAudioClientMetrics clientMetrics,
)
{
    if (capture is null) return;
    capture.stop();
    capture.join();
    mergeCaptureMetrics(clientMetrics, capture.metrics);
    if (capture.error.length && !captureError.length) captureError = capture.error;
    capture = null;
}

private void mergeCaptureMetrics(
    ref ConsoleLiveAudioClientMetrics total,
    ConsoleLiveAudioClientMetrics capture,
)
{
    if (!capture.clientFramesSent) return;
    if (!total.clientAudioFormat.length) total.clientAudioFormat = capture.clientAudioFormat;
    total.clientAudioBytes += capture.clientAudioBytes;
    total.clientSentBytes += capture.clientSentBytes;
    total.clientFramesSent += capture.clientFramesSent;
    total.clientEncodeMs += capture.clientEncodeMs;
    total.clientSendMs += capture.clientSendMs;
    total.clientMaxSendBacklogMs = max(total.clientMaxSendBacklogMs, capture.clientMaxSendBacklogMs);
}

private string startMessage(ConsoleLiveAudioRequest request)
{
    return liveAudioStartJson(request.start);
}

private HTTPClientSettings websocketSettings()
{
    auto settings = new HTTPClientSettings;
    settings.connectTimeout = dur!"msecs"(2_000);
    settings.readTimeout = dur!"msecs"(3_600_000);
    settings.webSocketPayloadMaxLength = 10 * 1024 * 1024;
    return settings;
}

private void call(void delegate(string) callback, string value)
{
    if (callback !is null && value.length) callback(value);
}

private void call(void delegate(LiveAudioStatus) callback, LiveAudioStatus value)
{
    if (callback !is null) callback(value);
}

private void call(void delegate(string, string) callback, string first, string second)
{
    if (callback !is null) callback(first, second);
}

private void call(void delegate(string, string, string) callback, string first, string second, string third)
{
    if (callback !is null) callback(first, second, third);
}
