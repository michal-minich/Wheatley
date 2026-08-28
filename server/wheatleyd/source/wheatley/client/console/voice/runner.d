module wheatley.client.console.voice.runner;

import core.thread : Thread;
import core.time : MonoTime, dur;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.format : format;
import std.string : strip, toLower;
import std.uuid : randomUUID;

import wheatley.common.api.live_audio : LiveAudioStartRequest;
import wheatley.common.api.live_audio_events : LiveAudioStatus;
import wheatley.common.api.text_turn : TextTurnRequest;
import wheatley.client.console.audio.input :
    audioInputNoticeText,
    describeConsoleAudioInput,
    effectiveConsoleAudioInput;
import wheatley.client.console.api.client :
    ConsoleApiClient;
import wheatley.client.console.config : ConsoleConfig;
import wheatley.client.console.codex.observer : startConsoleCodexObserver;
import wheatley.client.console.conversation.observer : startConsoleConversationObserver;
import wheatley.client.console.conversation.local_submissions :
    clearLocalSubmission,
    markLocalSubmission;
import wheatley.client.console.live.client :
    streamLiveAudioTurn;
import wheatley.client.console.audio.runtime : ConsoleAudioRuntime;
import wheatley.client.console.live.types :
    ConsoleLiveAudioClientMetrics,
    ConsoleLiveAudioHandlers,
    ConsoleLiveAudioRequest,
    ConsoleLiveAudioResult,
    consoleLiveAudioClientMetricsJson,
    hasConsoleLiveAudioClientMetrics;
import wheatley.client.console.ui.output :
    color,
    LivePreviewLine,
    writeAssistantPrefix,
    writeError,
    writeLine,
    writeMutedTurn,
    writeNotice,
    writeToken,
    writeTurn,
    writeTimedTurn;
import wheatley.client.console.ui.reasoning_output : ConsoleReasoningOutput;
import wheatley.client.console.ui.turn_metrics :
    compactConsoleDuration,
    consoleTurnMetricsText;
import wheatley.client.console.speech.settings : consoleStreamingSpeechSettings;
import wheatley.client.console.ui.startup_status :
    ConsoleStartupOptions,
    announceConsoleStartup;
import wheatley.client.console.speech.streaming : ConsoleStreamingSpeechMetrics;
import wheatley.client.console.ui.system_announcement : writeConsoleSystem;
import wheatley.client.console.tools.events :
    closeConsoleToolLine,
    handleConsoleToolEvent;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.client.console.voice.session_resume : promptConsoleVoiceSessionResume;

int runConsoleVoice(
    ConsoleApiClient client,
    ConsoleAudioRuntime audio,
    ConsoleConfig config,
)
{
    auto ffmpegPath = resolveBundledExecutable("ffmpeg", "ffmpeg binary", config.appDataRoot);
    auto assistantName = config.profileId.length ? config.profileId : "wheatley";
    writeConsoleSystem("Wheatley voice chat. Ctrl-C exits.");
    writeAudioInputNotice(ffmpegPath, config);
    writeAudioModeNotice(config);
    auto startupState = client.profileStartupState(config.profileId, config.language);
    auto resumeConfig = config;
    resumeConfig.language = startupState.language;
    auto resumeLastSession = startupState.canResumeLastSession
        && promptConsoleVoiceSessionResume(client, audio, resumeConfig, startupState, ffmpegPath);
    if (resumeLastSession) config.language = startupState.language;

    auto startup = announceConsoleStartup(
        client,
        audio,
        config,
        "voice",
        ConsoleStartupOptions(
            config.speak,
            resumeLastSession ? startupState.lastSessionId : "",
        ),
    );
    config.language = startup.language;
    config.sessionId = startup.sessionId;
    auto codexObserver = startConsoleCodexObserver(config.apiBase, config.profileId, config.sessionId);
    auto conversationObserver = startConsoleConversationObserver(
        config.apiBase,
        config.profileId,
        config.sessionId,
        config.deviceId,
    );
    scope(exit) {
        codexObserver.requestStop();
        conversationObserver.requestStop();
        codexObserver.join();
        conversationObserver.join();
    }
    int count;
    bool prewarmResumedSession = resumeLastSession;
    auto retryState = VoiceRetryState();
    while (config.turns <= 0 || count < config.turns) {
        auto previewLine = new LivePreviewLine;
        bool emittedAssistantTokens;
        bool assistantPrefixOpen;
        bool toolLineOpen;
        bool listeningAnnounced;
        bool stoppedAnnounced;
        bool turnErrorPrinted;
        auto reasoningOutput = new ConsoleReasoningOutput(
            toolLineOpen,
            assistantPrefixOpen,
            assistantName,
        );
        auto userTiming = VoiceUserTiming();
        scope(failure) {
            reasoningOutput.close();
            audio.cancelTurn();
        }
        ConsoleLiveAudioRequest request;
        request.start = LiveAudioStartRequest(
            TextTurnRequest(
                config.sessionId,
                "",
                "console-audio-live-" ~ randomUUID().toString(),
                config.deviceId,
                config.language,
                "",
                config.loadMemory,
            ),
            config.audio,
            "turn",
            prewarmResumedSession,
        );
        request.start.reasoningMode = config.reasoningMode;
        request.start.model = config.model;
        markLocalSubmission(request.start.submissionId);
        scope(exit) clearLocalSubmission(request.start.submissionId);
        setTurnAudioInputSnapshot(request.start, ffmpegPath, config);
        request.ffmpegPath = ffmpegPath;
        request.ffmpegAudioInput = config.audioInput;
        request.simulateUploadKbps = config.simulateUploadKbps;
        request.start.silenceSeconds = config.speechCommitDelaySeconds;
        audio.beginTurn(
            consoleStreamingSpeechSettings(config, config.language),
            request.start.sessionId,
            request.start.submissionId,
        );

        try {
            auto result = streamLiveAudioTurn(
                config.apiBase,
                config.profileId,
                request,
                ConsoleLiveAudioHandlers(
                    (status) {
                        reasoningOutput.close();
                        closeConsoleToolLine(toolLineOpen);
                        closeAssistantLine(assistantPrefixOpen);
                        if (shouldClearPreviewForStatus(status.kind)) {
                            previewLine.clear();
                        }
                        handleVoiceStatus(
                            listeningAnnounced,
                            stoppedAnnounced,
                            audio,
                            userTiming,
                            status,
                        );
                    },
                    (text) {
                        reasoningOutput.close();
                        closeConsoleToolLine(toolLineOpen);
                        closeAssistantLine(assistantPrefixOpen);
                        if (shouldRenderPreviewTranscript(text)) {
                            previewLine.update("you", "yellow", text);
                        }
                    },
                    (text, userText, language) {
                        reasoningOutput.close();
                        closeConsoleToolLine(toolLineOpen);
                        closeAssistantLine(assistantPrefixOpen);
                        audio.setSpeechLanguage(language.length ? language : config.language);
                        auto finalText = (userText.length ? userText : text).strip;
                        if (shouldRenderFinalTranscript(finalText)) {
                            previewLine.completeTurn("you", "yellow", finalText);
                        } else {
                            previewLine.clear();
                        }
                        auto turnId = request.start.submissionId;
                        audio.startSpeechInterrupt(config, ffmpegPath, () {
                            audio.cancelSpeech();
                            try {
                                auto stopClient = new ConsoleApiClient(config.apiBase);
                                stopClient.stopTextTurn(config.profileId, config.sessionId, turnId);
                            } catch (Exception) {
                            }
                        });
                    },
                    (command) {
                        if (config.playMusic)
                            audio.applyThinkingMusic(command.action, command.delayMs);
                    },
                    (token) {
                        reasoningOutput.close();
                        previewLine.clear();
                        if (toolLineOpen) {
                            if (!token.strip.length) return;
                            toolLineOpen = false;
                            assistantPrefixOpen = true;
                        } else {
                            closeConsoleToolLine(toolLineOpen);
                        }
                        if (!assistantPrefixOpen && !token.strip.length) {
                            return;
                        }
                        if (!assistantPrefixOpen) {
                            writeAssistantPrefix(assistantName);
                            assistantPrefixOpen = true;
                        }
                        emittedAssistantTokens = true;
                        writeToken(token);
                        audio.feedSpeech(token);
                    },
                    (dataJson) {
                        reasoningOutput.close();
                        previewLine.clear();
                        audio.feedSpeechImmediate(handleConsoleToolEvent(
                            assistantPrefixOpen,
                            toolLineOpen,
                            dataJson,
                        ));
                    },
                    (message) {
                        audio.stopThinkingMusic();
                        reasoningOutput.close();
                        closeConsoleToolLine(toolLineOpen);
                        previewLine.clear();
                        closeAssistantLine(assistantPrefixOpen);
                        turnErrorPrinted = true;
                        writeError(message);
                    },
                    (dataJson) {
                        reasoningOutput.handle(dataJson);
                    },
                    (text, userText, language, artifactId) {},
                    null,
                    null,
                ),
            );
            audio.stopThinkingMusic();
            reasoningOutput.close();
            previewLine.clear();
            if (!emittedAssistantTokens && result.assistantText.length) {
                closeConsoleToolLine(toolLineOpen);
                closeAssistantLine(assistantPrefixOpen);
                writeTimedTurn(
                    assistantName,
                    result.assistantText,
                    result.metrics.durationMs < 0
                        ? "" : compactConsoleDuration(result.metrics.durationMs),
                );
                audio.feedSpeech(result.assistantText);
            } else {
                closeConsoleToolLine(toolLineOpen);
                closeAssistantLine(
                    assistantPrefixOpen,
                    result.metrics.durationMs < 0
                        ? "" : compactConsoleDuration(result.metrics.durationMs),
                );
            }
            auto metricsText = consoleTurnMetricsText(
                result.metrics,
                result.language.length ? result.language : config.language,
            );
            if (metricsText.length) writeMutedTurn(assistantName, metricsText);
            audio.setSpeechLanguage(result.language.length ? result.language : config.language);
            if (result.stopped) {
                audio.stopSpeech();
            } else {
                audio.finishSpeech();
            }
            audio.stopSpeechInterrupt();
            applyUserTiming(result.clientMetrics, userTiming);
            applySpeakerTiming(result.clientMetrics, audio.speechMetrics, userTiming);
            postVoiceClientMetrics(client, result);
            prewarmResumedSession = false;
            retryState = VoiceRetryState();
            count++;
        } catch (Exception error) {
            reasoningOutput.close();
            previewLine.clear();
            closeConsoleToolLine(toolLineOpen);
            closeAssistantLine(assistantPrefixOpen);
            audio.cancelTurn();
            if (handleRecoverableVoiceError(error.msg, retryState)) {
                continue;
            }
            if (!turnErrorPrinted) writeError(error.msg);
            count++;
            continue;
        }
    }
    return 0;
}

private void setTurnAudioInputSnapshot(
    ref LiveAudioStartRequest start,
    string ffmpegPath,
    ConsoleConfig config,
)
{
    start.audioInputSelector = effectiveConsoleAudioInput(config.audioInput);
    try {
        auto input = describeConsoleAudioInput(ffmpegPath, config.audioInput, config.appDataRoot);
        start.audioInputSelector = input.selector;
        start.audioInputLabel = input.label;
    } catch (Exception) {
        // Capture remains usable even if the optional human-readable lookup fails.
    }
}

private void handleVoiceStatus(
    ref bool listeningAnnounced,
    ref bool stoppedAnnounced,
    ConsoleAudioRuntime audio,
    ref VoiceUserTiming userTiming,
    LiveAudioStatus status,
)
{
    if (status.kind == "generated_image") {
        writeNotice(status.message, "cyan");
        return;
    }

    if (status.kind == "pi_compaction_started"
        || status.kind == "pi_compaction_completed"
        || status.kind == "pi_compaction_failed") {
        writeNotice(status.message, status.kind == "pi_compaction_failed" ? "red" : "cyan");
        audio.feedSpeechImmediate(status.kind == "pi_compaction_started"
            ? "Compacting context."
            : status.kind == "pi_compaction_completed"
                ? "Context compacted."
                : "Context compaction failed.");
        return;
    }

    if (status.kind == "listening_started") {
        audio.beginCapture();
        announceListeningStart(listeningAnnounced, audio, userTiming);
        return;
    }

    if (status.kind == "endpoint_reached") {
        audio.releaseCapture();
        announceListeningStop(stoppedAnnounced, audio, userTiming);
        return;
    }

    if (status.kind == "listening_retry" || status.kind == "candidate_rejected")
        audio.beginCapture();
}

private void announceListeningStart(
    ref bool listeningAnnounced,
    ConsoleAudioRuntime audio,
    ref VoiceUserTiming userTiming,
)
{
    if (listeningAnnounced) return;
    writeNotice("listening...", "green");
    userTiming.markListeningStart();
    audio.playListeningStart();
    listeningAnnounced = true;
}

private void announceListeningStop(
    ref bool stoppedAnnounced,
    ConsoleAudioRuntime audio,
    ref VoiceUserTiming userTiming,
)
{
    if (stoppedAnnounced) return;
    userTiming.markListeningStop();
    audio.playListeningStop();
    stoppedAnnounced = true;
}

private struct VoiceUserTiming
{
    bool hasListeningStart;
    bool hasListeningStop;
    MonoTime listeningStartMono;
    MonoTime listeningStopMono;

    void markListeningStart()
    {
        if (hasListeningStart) return;
        listeningStartMono = MonoTime.currTime;
        hasListeningStart = true;
    }

    void markListeningStop()
    {
        if (hasListeningStop) return;
        listeningStopMono = MonoTime.currTime;
        hasListeningStop = true;
    }

    bool hasTotalMs() const
    {
        return hasListeningStart && hasListeningStop && listeningStopMono >= listeningStartMono;
    }

    long totalMs() const
    {
        if (!hasTotalMs) return 0;
        return cast(long) (listeningStopMono - listeningStartMono).total!"msecs";
    }
}

private void applyUserTiming(
    ref ConsoleLiveAudioClientMetrics metrics,
    VoiceUserTiming userTiming,
)
{
    if (!userTiming.hasTotalMs) return;
    metrics.hasUserTotalMs = true;
    metrics.userTotalMs = userTiming.totalMs;
}

private void applySpeakerTiming(
    ref ConsoleLiveAudioClientMetrics metrics,
    ConsoleStreamingSpeechMetrics speakerMetrics,
    VoiceUserTiming userTiming,
)
{
    if (!speakerMetrics.hasTtsMetrics) return;

    metrics.ttsModel = speakerMetrics.model;
    metrics.hasTtsFirstAudioMs = speakerMetrics.hasFirstPlayback && speakerMetrics.hasFirstText;
    metrics.ttsFirstAudioMs = speakerMetrics.firstAudioMs;
    metrics.ttsSynthesisMs = speakerMetrics.synthesisMs;
    metrics.ttsChunks = speakerMetrics.chunks;
    if (speakerMetrics.spokenAudioSeconds > 0.0) {
        metrics.hasTtsSpokenAudioSeconds = true;
        metrics.ttsSpokenAudioSeconds = speakerMetrics.spokenAudioSeconds;
    }
    if (userTiming.hasListeningStop && speakerMetrics.hasFirstPlayback) {
        metrics.hasEndpointToFirstSpokenAudioMs = true;
        metrics.endpointToFirstSpokenAudioMs =
            cast(long) (speakerMetrics.firstPlaybackMono - userTiming.listeningStopMono).total!"msecs";
    }
}

private void postVoiceClientMetrics(
    ConsoleApiClient client,
    ConsoleLiveAudioResult result,
)
{
    if (!result.turnId.length || !hasConsoleLiveAudioClientMetrics(result.clientMetrics)) return;
    try {
        client.postTurnClientMetrics(
            result.profileId,
            result.sessionId,
            result.turnId,
            consoleLiveAudioClientMetricsJson(result.clientMetrics),
        );
    } catch (Exception) {
    }
}

private bool shouldClearPreviewForStatus(string kind)
{
    return kind == "candidate_rejected";
}

private bool shouldRenderPreviewTranscript(string text)
{
    return text.strip.length > 0;
}

private bool shouldRenderFinalTranscript(string text)
{
    auto normalized = text.strip;
    return normalized.length && normalized != "[BLANK_AUDIO]";
}

private void closeAssistantLine(
    ref bool assistantPrefixOpen,
    string duration = "",
)
{
    if (!assistantPrefixOpen) return;
    if (duration.length) writeToken(" " ~ color(duration, "gray"));
    writeLine();
    assistantPrefixOpen = false;
}

private void writeAudioInputNotice(string ffmpegPath, ConsoleConfig config)
{
    try {
        auto notice = audioInputNoticeText(
            describeConsoleAudioInput(ffmpegPath, config.audioInput, config.appDataRoot),
        );
        if (notice.length) {
            writeConsoleSystem(notice);
        }
    } catch (Exception) {
        writeConsoleSystem("microphone: default input");
    }
}

private void writeAudioModeNotice(ConsoleConfig config)
{
    auto suffix = config.simulateUploadKbps > 0
        ? format!", simulated upload %s kb/s"(config.simulateUploadKbps)
        : "";
    if (config.audio.format == "opus") {
        writeConsoleSystem(format!"audio mode: opus %s b/s, %s ms frames, %s, complexity %s, %s, 16 kHz mono%s"(
            config.audio.bitrate,
            config.audio.frameMs,
            config.audio.application,
            config.audio.complexity,
            config.audio.container,
            suffix,
        ));
        return;
    }

    writeConsoleSystem(format!"audio mode: pcm_s16le 16 kHz mono, %s ms frames%s"(config.audio.frameMs, suffix));
}

private struct VoiceRetryState
{
    bool unavailablePrinted;
    bool hasLastReconnectAt;
    MonoTime lastReconnectAt;
}

private bool handleRecoverableVoiceError(
    string message,
    ref VoiceRetryState retryState,
)
{
    auto friendly = friendlyVoiceError(message);
    if (!friendly.length) return false;

    if (!retryState.unavailablePrinted) {
        writeError(friendly);
        retryState.unavailablePrinted = true;
        retryState.lastReconnectAt = MonoTime.currTime;
        retryState.hasLastReconnectAt = true;
    } else if (shouldPrintReconnectNotice(retryState)) {
        writeConsoleSystem("Trying to reconnect...");
        retryState.lastReconnectAt = MonoTime.currTime;
        retryState.hasLastReconnectAt = true;
    }

    Thread.sleep(dur!"seconds"(5));
    return true;
}

private bool shouldPrintReconnectNotice(VoiceRetryState retryState)
{
    if (!retryState.hasLastReconnectAt) return true;
    return MonoTime.currTime - retryState.lastReconnectAt >= dur!"seconds"(60);
}

private string friendlyVoiceError(string message)
{
    auto text = message.toLower;
    if (
        text.canFind("failed to connect") ||
        text.canFind("connection refused") ||
        text.canFind(" connect to ") ||
        text.canFind("refused")
    ) {
        return "Could not connect to Wheatley server.";
    }
    if (text.canFind("live audio stream ended without final response")) {
        return "Connection lost before the response finished.";
    }
    return "";
}
