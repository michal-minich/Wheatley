module wheatley.server.voice.runtime;

import core.time : Duration, MonoTime, dur;

import std.algorithm.comparison : max;
import std.exception : enforce;
import std.format : format;
import std.math : ceil;
import std.string : strip;

import vibe.http.websockets :
    WebSocket,
    WebSocketCloseReason;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField,
    jsonUlongField;
import wheatley.common.api.live_audio : LiveAudioCommit, LiveAudioStartRequest;
import wheatley.common.api.reasoning : ReasoningMode, reasoningEnabled, reasoningModeText;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.profile_startup : ProfileSessionResumeAnswers;
import wheatley.common.conversation.events : ConversationEvent, ConversationEventKind;
import wheatley.common.api.text_turn : TextTurnRequest;
import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.profile.runtime : ProfileRuntime;
import wheatley.server.stt.whisper_cpp : WhisperCppWorkers;
import wheatley.server.turns.audio.final_transcription :
    FinalAudioTurnTranscription,
    transcribeFinalAudioTurnWavBytes;
import wheatley.server.turns.audio.input_audio_artifacts :
    persistAcceptedUserAudioPcmAsOpus;
import wheatley.server.turns.image.input_image_artifacts : loadStagedUserImage;
import wheatley.server.turns.audio.live_audio_decoder :
    LiveAudioDecoder,
    createLiveAudioDecoder;
import wheatley.server.turns.audio.live_audio_incoming : readLiveAudioIncoming;
import wheatley.server.turns.audio.live_audio_messages :
    readLiveAudioCommand,
    readLiveAudioCommit,
    readStartMessage,
    sendSocket,
    sendTurnEvent;
import wheatley.server.turns.audio.live_audio_responses :
    sendLiveEndpointDetected,
    sendLiveError,
    sendLiveFinalTranscript,
    sendLivePreviewTranscript,
    sendLiveReady,
    sendLiveSessionResumeChoice,
    sendLiveStatus,
    sendLiveThinkingMusic;
import wheatley.server.turns.audio.live_audio_settings :
    LiveAudioRuntimeSettings,
    applySessionResumeChoiceSettings,
    loadLiveAudioRuntimeSettings;
import wheatley.server.turns.audio.live_audio_state : LiveAudioTurnState;
import wheatley.server.turns.audio.live_preview_transcriber :
    LivePreviewTranscriber,
    transcribeLiveAudioDraft;
import wheatley.server.turns.audio.live_final_transcript :
    finalTranscriptSource,
    selectFinalTranscript;
import wheatley.server.turns.audio.live_transcript_text :
    normalizeLiveTranscript,
    spokenSubmitCommand,
    speechTextFromTranscript;
import wheatley.server.turns.audio.pcm16_wav :
    pcm16RawBytes,
    pcm16SampleDurationSeconds,
    pcm16WavBytes;
import wheatley.server.turns.audio.session_resume_choice : sessionResumeChoice;
import wheatley.server.conversation.port :
    ConversationPort,
    ConversationPreparationPort,
    ConversationPromptPrewarm;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.voice.events : VoiceEventKind;
import wheatley.server.conversation.turn_request :
    ConversationTurnRequest,
    conversationSubmissionId,
    conversationTurnRequest;
import wheatley.server.session_use_registry : SessionUseRegistry;
import wheatley.server.voice.session_coordinator : VoiceSessionCoordinator;
import wheatley.server.voice.accepted_manifest : writeAcceptedVoiceManifest;
import wheatley.server.voice.playback_registry :
    AudioPlaybackReceipt,
    VoicePlaybackRegistry;
import wheatley.common.api.audio_playback : AudioPlaybackEvent;
import wheatley.server.queue.session_queue :
    QueueReservation;
import wheatley.server.queue.session_queue_projection : projectQueueMutation;
import wheatley.server.scheduled_tasks.schedule : addSeconds;

final class VoiceRuntime
{
    private ServerConfig config;
    private HistoryStore store;
    private ProfileRuntime profiles;
    private ConversationPort conversations;
    private ConversationPreparationPort conversationPreparation;
    private SessionUseRegistry sessionUses;
    private WhisperCppWorkers stt;
    private VoicePlaybackRegistry playback;

    this(
        ServerConfig config,
        HistoryStore store,
        ProfileRuntime profiles,
        ConversationPort conversations,
        ConversationPreparationPort conversationPreparation,
        SessionUseRegistry sessionUses,
        WhisperCppWorkers stt,
    )
    {
        this.config = config;
        this.store = store;
        this.profiles = profiles;
        this.conversations = conversations;
        this.conversationPreparation = conversationPreparation;
        this.sessionUses = sessionUses;
        this.stt = stt;
        this.playback = new VoicePlaybackRegistry;
    }

    AudioPlaybackReceipt observePlayback(AudioPlaybackEvent event)
    {
        return playback.observe(event);
    }

    bool speaking(SessionKey session)
    {
        return playback.speaking(session);
    }

    void run(scope WebSocket socket)
    {
        auto lifecycle = new VoiceSessionCoordinator;
        scope(exit) if (!lifecycle.terminal) lifecycle.cancel();
        runSession(socket, lifecycle);
    }

    private void runSession(scope WebSocket socket, VoiceSessionCoordinator lifecycle)
    {
        SessionKey session;
        bool sessionUseActive;
        bool queueReserved;
        string reservedQueueItemId;
        scope(exit) if (sessionUseActive) sessionUses.finish(session);
        try {
        auto profileId = requireProfileId(socket.request, store);
        auto start = readStartMessage(socket);
        session = SessionKey(profileId, start.sessionId);
        sessionUses.begin(session);
        sessionUseActive = true;
        auto resolved = profiles.resolveSession(profileId, start.language);
        auto settings = loadLiveAudioRuntimeSettings(config, resolved);
        auto recognizingSessionResume = start.purpose == "session_resume";
        if (recognizingSessionResume)
            settings = applySessionResumeChoiceSettings(settings);
        else
            settings.silenceSeconds = start.silenceSeconds;
        auto decoder = createLiveAudioDecoder(config, start.audio);
        scope(exit) decoder.close();

        sendLiveReady(socket, profileId, start, settings);
        sendLiveStatus(
            socket,
            config.resourcesRoot,
            start.language,
            VoiceEventKind.listeningStarted,
            "listeningStarted",
        );
        lifecycle.beginListening();
        ConversationPromptPrewarm promptPrewarm;
        if (!recognizingSessionResume) {
            promptPrewarm = conversationPreparation.startPromptPrewarm(
                session,
                start.language,
                start.loadMemory,
                start.prewarmExistingSession,
            );
        }
        scope(exit) if (promptPrewarm !is null) promptPrewarm.stop();

        bool audioReceivedReported;
        long candidateId;
        while (socket.connected) {
            ++candidateId;
            auto state = new LiveAudioTurnState(settings);
            auto previewTranscriber = new LivePreviewTranscriber(settings, stt);
            scope(exit) previewTranscriber.stop();
            auto candidateStartedAt = MonoTime.currTime;
            LiveAudioTransferStats transferStats;
            transferStats.inputFormat = start.audio.format;
            transferStats.sampleRate = settings.sampleRate;
            transferStats.channels = settings.channels;
            transferStats.bitrate = start.audio.bitrate;
            transferStats.frameMs = start.audio.frameMs;
            auto decodeBaseMs = decoder.stats.decodeMs;

            bool finishRequested;
            bool speechDetectedReported;
            bool quietCandidateExpired;
            DraftEndpointReason draftEndpointReason;
            auto spokenSubmitDetector = SpokenSubmitDetector(
                settings.spokenSubmitConfirmationCount,
            );
            bool hasDraftChange;
            MonoTime lastDraftChangeMono;
            bool hasStrongVoice;
            MonoTime lastStrongVoiceMono;
            bool thinkingMusicRequested;
            bool suspended;
            MonoTime suspendedAt;
            while (socket.connected && !finishRequested && !state.endpointReached) {
                if (suspended) {
                    if (!socket.waitForData(dur!"msecs"(250))) continue;
                    auto incoming = readLiveAudioIncoming(socket);
                    if (!incoming.commandText.length) continue;
                    auto command = readLiveAudioCommand(incoming.commandText);
                    if (command.kind == "cancel") {
                        lifecycle.cancel();
                        return;
                    }
                    if (command.kind != "resume") continue;
                    auto pausedFor = MonoTime.currTime - suspendedAt;
                    candidateStartedAt += pausedFor;
                    if (hasDraftChange) lastDraftChangeMono += pausedFor;
                    if (hasStrongVoice) lastStrongVoiceMono += pausedFor;
                    suspended = false;
                    sendLiveStatus(
                        socket,
                        config.resourcesRoot,
                        start.language,
                        VoiceEventKind.listeningResumed,
                        "listeningResumed",
                    );
                    continue;
                }
                if (!socket.waitForData(dur!"msecs"(250))) {
                    auto drained = decoder.drain();
                    auto decodedResult = acceptDecodedLiveAudio(
                        socket,
                        config.resourcesRoot,
                        candidateId,
                        state,
                        previewTranscriber,
                        start,
                        drained,
                        audioReceivedReported,
                        speechDetectedReported,
                        transferStats,
                    );
                    if (sendDetectedSessionResumeChoice(
                        socket,
                        config.resourcesRoot,
                        start.language,
                        decodedResult.speechText,
                        settings.resumeAnswers,
                        recognizingSessionResume,
                        lifecycle,
                    )) return;
                    if (!recognizingSessionResume) {
                        auto detectedDraftEndpoint = draftEndpoint(
                            decodedResult.speechText,
                            decodedResult.previewObserved,
                            decodedResult.observedSpeechText,
                            state,
                            spokenSubmitDetector,
                            hasDraftChange,
                            lastDraftChangeMono,
                            hasStrongVoice,
                            lastStrongVoiceMono,
                        );
                        if (detectedDraftEndpoint != DraftEndpointReason.none) {
                            draftEndpointReason = detectedDraftEndpoint;
                            break;
                        }
                    }
                    if (decodedResult.quietCandidateExpired) {
                        quietCandidateExpired = true;
                        break;
                    }
                    transferStats.decodeMs = decoder.stats.decodeMs - decodeBaseMs;
                    if (state.endpointReached) break;
                    if (noSpeechWaitExpired(candidateStartedAt, settings.maxWaitSeconds)) {
                        sendLiveStatus(
                            socket,
                            config.resourcesRoot,
                            start.language,
                            VoiceEventKind.listeningRetry,
                            "listeningRetry",
                        );
                        quietCandidateExpired = true;
                        break;
                    }
                    continue;
                }

                auto incoming = readLiveAudioIncoming(socket);
                if (incoming.commandText.length) {
                    auto command = readLiveAudioCommand(incoming.commandText);
                    if (command.kind == "configure") {
                        state.setSilenceSeconds(command.silenceSeconds);
                        continue;
                    }
                    if (command.kind == "cancel") {
                        lifecycle.cancel();
                        return;
                    }
                    if (command.kind == "suspend") {
                        suspended = true;
                        suspendedAt = MonoTime.currTime;
                        sendLiveStatus(
                            socket,
                            config.resourcesRoot,
                            start.language,
                            VoiceEventKind.listeningSuspended,
                            "listeningSuspended",
                        );
                        continue;
                    }
                    if (command.kind == "resume") continue;
                    auto flushed = decoder.finish();
                    auto decodedResult = acceptDecodedLiveAudio(
                        socket,
                        config.resourcesRoot,
                        candidateId,
                        state,
                        previewTranscriber,
                        start,
                        flushed,
                        audioReceivedReported,
                        speechDetectedReported,
                        transferStats,
                    );
                    if (sendDetectedSessionResumeChoice(
                        socket,
                        config.resourcesRoot,
                        start.language,
                        decodedResult.speechText,
                        settings.resumeAnswers,
                        recognizingSessionResume,
                        lifecycle,
                    )) return;
                    if (!recognizingSessionResume) {
                        auto detectedDraftEndpoint = draftEndpoint(
                            decodedResult.speechText,
                            decodedResult.previewObserved,
                            decodedResult.observedSpeechText,
                            state,
                            spokenSubmitDetector,
                            hasDraftChange,
                            lastDraftChangeMono,
                            hasStrongVoice,
                            lastStrongVoiceMono,
                        );
                        if (detectedDraftEndpoint != DraftEndpointReason.none) {
                            draftEndpointReason = detectedDraftEndpoint;
                            break;
                        }
                    }
                    if (decodedResult.quietCandidateExpired) {
                        quietCandidateExpired = true;
                    }
                    transferStats.decodeMs = decoder.stats.decodeMs - decodeBaseMs;
                    finishRequested = true;
                    break;
                }

                if (incoming.audioBytes.length) {
                    transferStats.acceptPayload(incoming.audioBytes.length);
                    auto decoded = decoder.accept(incoming.audioBytes);
                    auto decodedResult = acceptDecodedLiveAudio(
                        socket,
                        config.resourcesRoot,
                        candidateId,
                        state,
                        previewTranscriber,
                        start,
                        decoded,
                        audioReceivedReported,
                        speechDetectedReported,
                        transferStats,
                    );
                    if (sendDetectedSessionResumeChoice(
                        socket,
                        config.resourcesRoot,
                        start.language,
                        decodedResult.speechText,
                        settings.resumeAnswers,
                        recognizingSessionResume,
                        lifecycle,
                    )) return;
                    if (!recognizingSessionResume) {
                        auto detectedDraftEndpoint = draftEndpoint(
                            decodedResult.speechText,
                            decodedResult.previewObserved,
                            decodedResult.observedSpeechText,
                            state,
                            spokenSubmitDetector,
                            hasDraftChange,
                            lastDraftChangeMono,
                            hasStrongVoice,
                            lastStrongVoiceMono,
                        );
                        if (detectedDraftEndpoint != DraftEndpointReason.none) {
                            draftEndpointReason = detectedDraftEndpoint;
                            break;
                        }
                    }
                    if (decodedResult.quietCandidateExpired) {
                        quietCandidateExpired = true;
                        break;
                    }
                    transferStats.decodeMs = decoder.stats.decodeMs - decodeBaseMs;
                    if (state.endpointReached) break;
                }
            }

            auto clientDisconnected = !socket.connected;
            if (clientDisconnected) {
                auto flushed = decoder.finish();
                acceptDecodedLiveAudio(
                    socket,
                    config.resourcesRoot,
                    candidateId,
                    state,
                    previewTranscriber,
                    start,
                    flushed,
                    audioReceivedReported,
                    speechDetectedReported,
                    transferStats,
                );
                transferStats.decodeMs = decoder.stats.decodeMs - decodeBaseMs;
                finishRequested = true;
            }
            if (quietCandidateExpired) {
                if (recognizingSessionResume) {
                    sendLiveSessionResumeChoice(socket, "unclear", "");
                    lifecycle.complete();
                    return;
                }
                lifecycle.rejectCandidate();
                continue;
            }
            if (
                !state.endpointReached &&
                draftEndpointReason == DraftEndpointReason.none &&
                !finishRequested
            ) {
                return;
            }

            previewTranscriber.seal();
            auto acceptedPreviewText = previewTranscriber.acceptedText;
            if (draftEndpointReason == DraftEndpointReason.spokenSubmit) {
                auto command = spokenSubmitCommand(acceptedPreviewText);
                enforce(
                    command.found && command.promptText.length,
                    "Spoken submit endpoint requires a nonempty prompt",
                );
                acceptedPreviewText = command.promptText;
            }
            if (shouldIgnoreAutomaticEndpoint(
                recognizingSessionResume,
                finishRequested,
                acceptedPreviewText,
            )) {
                sendLiveThinkingMusic(socket, "stop");
                sendLiveStatus(
                    socket,
                    config.resourcesRoot,
                    start.language,
                    VoiceEventKind.candidateRejected,
                    "listeningIgnored",
                );
                lifecycle.rejectCandidate();
                decoder.close();
                decoder = createLiveAudioDecoder(config, start.audio);
                continue;
            }
            if (!state.hasFinalSamples && start.text.strip.length) {
                lifecycle.reachEndpoint();
                lifecycle.acceptTranscript();
                sendTypedTextTurn(
                    socket,
                    conversations,
                    session,
                    start,
                    settings.responseMusicDelayMs,
                    promptPrewarm,
                    config.resourcesRoot,
                    lifecycle,
                );
                return;
            }

            if (!state.hasFinalSamples) {
                sendLiveStatus(
                    socket,
                    config.resourcesRoot,
                    start.language,
                    VoiceEventKind.listeningRetry,
                    "listeningRetry",
                );
                lifecycle.rejectCandidate();
                continue;
            }

            auto endpointReason = clientDisconnected
                ? "client_disconnect"
                : finishRequested
                    ? "client_stop"
                : state.maximumDurationReached
                    ? "max_duration"
                    : draftEndpointReason == DraftEndpointReason.recognizedShortSpeech
                        ? "recognized_short_speech"
                        : draftEndpointReason == DraftEndpointReason.spokenSubmit
                            ? "spoken_submit"
                        : draftEndpointReason == DraftEndpointReason.stableDraft
                            ? "draft_stable"
                            : "silence";
            auto endpointMessageKey = recognizingSessionResume
                ? "sessionChoiceDetected"
                : finishRequested
                    || state.maximumDurationReached
                    || draftEndpointReason == DraftEndpointReason.spokenSubmit
                    ? "listeningStoppedFinal"
                    : "speechEndpointDetected";
            sendLiveEndpointDetected(
                socket,
                config.resourcesRoot,
                start.language,
                endpointMessageKey,
            );
            lifecycle.reachEndpoint();
            if (!recognizingSessionResume && reasoningEnabled(start.reasoningMode)) {
                sendLiveThinkingMusic(socket, "play");
                thinkingMusicRequested = true;
            }
            auto endpointCommittedMono = MonoTime.currTime;
            auto endpointCommittedAt = nowIso();
            auto endpointLagMs = state.hasEndpointLag ? state.endpointLagMs : 0;
            auto finalSamples = state.finalSamples;
            if (recognizingSessionResume) {
                lifecycle.beginFinalTranscription();
                auto transcript = transcribeLiveAudioDraft(stt, finalSamples, settings, "").text;
                auto choice = sessionResumeChoice(transcript, settings.resumeAnswers);
                if (choice == "unclear") {
                    auto finalChoiceTranscript = transcribeFinalAudioTurnWavBytes(
                        stt,
                        settings.finalStt,
                        start.language,
                        pcm16WavBytes(finalSamples, settings.sampleRate, settings.channels),
                        "",
                    );
                    transcript = finalChoiceTranscript.transcriptText;
                    choice = sessionResumeChoice(transcript, settings.resumeAnswers);
                }
                sendLiveSessionResumeChoice(socket, choice, transcript);
                lifecycle.complete();
                return;
            }
            auto finalAudioSeconds = pcm16SampleDurationSeconds(
                finalSamples,
                settings.sampleRate,
                settings.channels,
            );
            auto finalWavBytes = pcm16WavBytes(finalSamples, settings.sampleRate, settings.channels);

            // Endpoint closure is the durable ordering boundary. Reserve the
            // sequence before either Opus encoding or final STT can delay this
            // producer behind a later text submission.
            auto artifactKey = "runtime-user-audio:" ~ start.submissionId;
            auto reservation = conversations.reserveQueueItem(session, QueueReservation(
                start.submissionId,
                session.sessionId,
                "user",
                "audio_live",
                start.deviceId,
                endpointCommittedAt,
                "",
                start.model,
                reasoningModeText(start.reasoningMode),
                start.language,
                artifactKey,
                artifactKey,
                jsonObject([
                    jsonStringField("source", "audio_live"),
                    jsonStringField("model", start.model),
                    jsonStringField("reasoning_mode", reasoningModeText(start.reasoningMode)),
                    jsonStringField("language", start.language),
                ]),
                false,
                addSeconds(
                    endpointCommittedAt,
                    cast(long) ceil(settings.finalStt.requestTimeoutSeconds * 2),
                ),
                start.loadMemory,
            ));
            queueReserved = true;
            reservedQueueItemId = start.submissionId;
            projectQueueMutation(store, session, reservation);

            auto userAudio = persistAcceptedUserAudioPcmAsOpus(
                config,
                profileId,
                start.submissionId,
                nowIso(),
                pcm16RawBytes(finalSamples),
                settings.sampleRate,
                settings.channels,
                pcm16SampleDurationSeconds(finalSamples, settings.sampleRate, settings.channels),
                settings.finalStt.requestTimeoutSeconds,
            );

            lifecycle.beginFinalTranscription();
            conversations.touchQueuePreparation(
                session,
                reservedQueueItemId,
                nowIso(),
                addSeconds(
                    nowIso(),
                    cast(long) ceil(settings.finalStt.requestTimeoutSeconds),
                ),
            );
            auto transcription = transcribeFinalAudioTurnWavBytes(
                stt,
                settings.finalStt,
                start.language,
                finalWavBytes,
                start.text,
            );
            auto finalTranscriptText = transcription.transcriptText;
            conversations.touchQueuePreparation(session, reservedQueueItemId, nowIso());
            bool usedSpokenSubmitPreview;
            if (draftEndpointReason == DraftEndpointReason.spokenSubmit) {
                auto command = spokenSubmitCommand(speechTextFromTranscript(finalTranscriptText));
                if (command.found)
                    finalTranscriptText = command.promptText;
                if (!speechTextFromTranscript(finalTranscriptText).length) {
                    finalTranscriptText = acceptedPreviewText;
                    usedSpokenSubmitPreview = true;
                }
            }
            auto finalTranscript = selectFinalTranscript(
                finalTranscriptText,
                transcription.coveredAudioMs,
                acceptedPreviewText,
                start.text,
                state.voiceSeconds,
                finalAudioSeconds,
                settings.finalSelection,
            );
            if (finalTranscript.usedPreviewDraft) {
                sendLiveStatus(
                    socket,
                    config.resourcesRoot,
                    start.language,
                    VoiceEventKind.transcriptDraftSelected,
                    finalTranscript.incompleteFinal
                        ? "draftSelectedIncompleteFinal"
                        : "draftSelectedUnreliable",
                );
            }
            if (finalTranscript.ignore) {
                failPreparingVoiceQueueItem(
                    store,
                    session,
                    conversations,
                    queueReserved,
                    reservedQueueItemId,
                    "Voice candidate was rejected before transcription acceptance.",
                );
                queueReserved = false;
                reservedQueueItemId = "";
                sendLiveThinkingMusic(socket, "stop");
                sendLiveStatus(
                    socket,
                    config.resourcesRoot,
                    start.language,
                    VoiceEventKind.candidateRejected,
                    "listeningIgnored",
                );
                lifecycle.rejectCandidate();
                continue;
            }

            auto turnId = start.submissionId;
            auto endpointToFinalTranscriptMs = cast(long) (
                MonoTime.currTime - endpointCommittedMono
            ).total!"msecs";

            auto turnRequest = liveTextTurnRequest(
                start,
                finalTranscript.userText,
                transcription.language,
            );
            turnRequest.startedAtOverride = endpointCommittedAt;
            turnRequest.audioMetricsJson = liveAudioMetricsJson(
                transferStats,
                finalAudioSeconds,
                state.voiceSeconds,
                state.hasEndpointLag,
                endpointLagMs,
                endpointReason,
                start.audioInputSelector,
                start.audioInputLabel,
            );
            turnRequest.sttMetricsJson = liveSttMetricsJson(
                previewTranscriber.metricsJson,
                transcription,
                usedSpokenSubmitPreview
                    ? "accepted_draft_spoken_submit"
                    : finalTranscriptSource(finalTranscript),
                finalAudioSeconds,
                finalTranscript.transcriptText,
            );
            turnRequest.turnMetricsJson = jsonObject([
                jsonLongField("endpoint_to_final_transcript_ms", endpointToFinalTranscriptMs),
            ]);
            turnRequest.hasAcceptedTurnStartMono = true;
            turnRequest.acceptedTurnStartMono = endpointCommittedMono;
            turnRequest.submissionId = turnId;
            // The accepted prompt and its exact execution policy must survive a
            // disconnect after transcript_accepted but before the commit reaches
            // us. Persist those canonical facts before exposing acceptance.
            writeAcceptedVoiceManifest(
                profileId,
                start,
                finalTranscript.userText,
                transcription.language,
                userAudio,
                "audio_live",
                turnRequest.startedAtOverride,
                turnRequest.audioMetricsJson,
                turnRequest.sttMetricsJson,
                turnRequest.turnMetricsJson,
                start.reasoningMode,
                start.model,
            );
            lifecycle.acceptTranscript();
            sendLiveFinalTranscript(
                socket,
                finalTranscript.transcriptText,
                finalTranscript.userText,
                transcription.language,
                userAudio.artifactKey,
            );

            if (socket.connected) {
                try {
                    auto commit = readLiveAudioCommit(socket);
                    enforcePinnedLiveAudioCommit(start, commit);
                } catch (Exception error) {
                    // transcript_accepted is the ownership boundary. A client
                    // disappearing while the optional image/commit handshake
                    // is in flight must not cancel the accepted server turn.
                    if (socket.connected) throw error;
                }
            }
            turnRequest.userImage = loadStagedUserImage(config, profileId, turnId);
            turnRequest.hasUserImage = turnRequest.userImage.filename.length > 0;
            lifecycle.awaitResponse();
            if (reasoningEnabled(start.reasoningMode) && !thinkingMusicRequested) {
                sendLiveThinkingMusic(socket, "play");
                thinkingMusicRequested = true;
            }
            streamLiveTextTurn(
                socket,
                conversations,
                session,
                turnRequest,
                userAudio,
                promptPrewarm,
                thinkingMusicRequested,
                start.reasoningMode,
                settings.responseMusicDelayMs,
                lifecycle,
            );
            queueReserved = false;
            reservedQueueItemId = "";
            return;
        }
        } catch (Exception error) {
            failPreparingVoiceQueueItem(
                store,
                session,
                conversations,
                queueReserved,
                reservedQueueItemId,
                error.msg,
            );
            lifecycle.fail();
            if (socket.connected) {
                sendLiveError(socket, error.msg);
                socket.close(WebSocketCloseReason.internalError, "Live audio failed");
            }
        }
    }
}

private void failPreparingVoiceQueueItem(
    HistoryStore store,
    SessionKey session,
    ConversationPort conversations,
    bool queueReserved,
    string itemId,
    string failure,
)
{
    if (!queueReserved || !itemId.length) return;
    try {
        auto mutation = conversations.failQueuePreparation(
            session,
            itemId,
            failure.length ? failure : "Voice preparation failed.",
        );
        if (projectQueueMutation(store, session, mutation))
            conversations.compactQueue(session);
    } catch (Exception) {
        // Preserve the original voice failure if recovery races with another
        // queue transition or the storage lock is unavailable.
    }
}

private void enforcePinnedLiveAudioCommit(
    LiveAudioStartRequest start,
    LiveAudioCommit commit,
)
{
    enforce(
        commit.reasoningMode == start.reasoningMode,
        "Live audio commit reasoning mode changed after transcript acceptance",
    );
    enforce(
        commit.model == start.model,
        "Live audio commit model changed after transcript acceptance",
    );
}

unittest
{
    LiveAudioStartRequest start;
    start.reasoningMode = ReasoningMode.high;
    start.model = "pi:test/model";
    enforcePinnedLiveAudioCommit(start, LiveAudioCommit(start.reasoningMode, start.model));

    import std.exception : assertThrown;
    assertThrown!Exception(enforcePinnedLiveAudioCommit(
        start,
        LiveAudioCommit(ReasoningMode.off, start.model),
    ));
    assertThrown!Exception(enforcePinnedLiveAudioCommit(
        start,
        LiveAudioCommit(start.reasoningMode, "pi:other/model"),
    ));
}

private bool sendDetectedSessionResumeChoice(
    scope WebSocket socket,
    string resourcesRoot,
    string language,
    string transcript,
    ProfileSessionResumeAnswers answers,
    bool recognizingSessionResume,
    VoiceSessionCoordinator lifecycle,
)
{
    if (!recognizingSessionResume || !transcript.length) return false;
    auto choice = sessionResumeChoice(transcript, answers);
    if (choice == "unclear") return false;
    sendLiveEndpointDetected(
        socket,
        resourcesRoot,
        language,
        "sessionChoiceDetected",
    );
    lifecycle.reachEndpoint();
    sendLiveSessionResumeChoice(socket, choice, transcript);
    lifecycle.complete();
    return true;
}

private bool noSpeechWaitExpired(MonoTime startedAt, double maxWaitSeconds)
{
    if (maxWaitSeconds <= 0) return false;
    return MonoTime.currTime - startedAt >= dur!"msecs"(cast(long) (maxWaitSeconds * 1_000));
}

private bool shouldIgnoreAutomaticEndpoint(
    bool recognizingSessionResume,
    bool finishRequested,
    string latestDisplayedDraft,
)
{
    if (recognizingSessionResume || finishRequested) return false;
    return !normalizeLiveTranscript(speechTextFromTranscript(latestDisplayedDraft)).length;
}

unittest
{
    assert(shouldIgnoreAutomaticEndpoint(false, false, "(clicking) (clickng)"));
    assert(shouldIgnoreAutomaticEndpoint(false, false, "..."));
    assert(!shouldIgnoreAutomaticEndpoint(false, false, "Thank you."));
    assert(!shouldIgnoreAutomaticEndpoint(false, true, ""));
    assert(!shouldIgnoreAutomaticEndpoint(true, false, ""));
}

private enum DraftEndpointReason
{
    none,
    recognizedShortSpeech,
    spokenSubmit,
    stableDraft,
}

private struct SpokenSubmitDetector
{
    long requiredConfirmations;
    long confirmations;

    this(long requiredConfirmations)
    {
        this.requiredConfirmations = requiredConfirmations;
    }

    bool observe(bool previewObserved, string speechText)
    {
        if (!previewObserved)
            return false;
        auto command = spokenSubmitCommand(speechText);
        if (!command.found || !command.promptText.length) {
            confirmations = 0;
            return false;
        }
        confirmations += command.repetitions;
        return confirmations >= requiredConfirmations;
    }
}

private DraftEndpointReason draftEndpoint(
    string changedPreviewText,
    bool previewObserved,
    string observedSpeechText,
    LiveAudioTurnState state,
    ref SpokenSubmitDetector spokenSubmitDetector,
    ref bool hasDraftChange,
    ref MonoTime lastDraftChangeMono,
    ref bool hasStrongVoice,
    ref MonoTime lastStrongVoiceMono,
)
{
    if (spokenSubmitDetector.observe(previewObserved, observedSpeechText))
        return DraftEndpointReason.spokenSubmit;
    auto now = MonoTime.currTime;
    auto strongVoice = state.latestBlockRms >= state.startVoiceThreshold;
    if (strongVoice) {
        hasStrongVoice = true;
        lastStrongVoiceMono = now;
    }
    if (changedPreviewText.length) {
        hasDraftChange = true;
        lastDraftChangeMono = now;
    }
    if (!hasDraftChange || !hasStrongVoice || strongVoice) return DraftEndpointReason.none;
    return selectDraftEndpointReason(
        hasDraftChange,
        hasStrongVoice,
        strongVoice,
        state.hasMinimumSpeech,
        now - lastDraftChangeMono,
        now - lastStrongVoiceMono,
        state.endpointSilenceSeconds,
        state.draftEndpointStableMinSeconds,
    );
}

unittest
{
    auto detector = SpokenSubmitDetector(2);
    assert(!detector.observe(false, "Explain this. Submit."));
    assert(!detector.observe(true, "Explain this. Submit."));
    assert(detector.observe(true, "Explain this. Submit!"));

    detector = SpokenSubmitDetector(2);
    assert(!detector.observe(true, "Explain this. Submit."));
    assert(!detector.observe(true, "Explain this further."));
    assert(!detector.observe(true, "Explain this. Submit."));

    detector = SpokenSubmitDetector(2);
    assert(detector.observe(true, "Explain this. Submit. Submit."));
}

private DraftEndpointReason selectDraftEndpointReason(
    bool hasDraftChange,
    bool hasStrongVoice,
    bool strongVoice,
    bool hasMinimumSpeech,
    Duration timeSinceDraftChange,
    Duration timeSinceStrongVoice,
    double endpointSilenceSeconds,
    double draftEndpointStableMinSeconds,
)
{
    if (!hasDraftChange || !hasStrongVoice || strongVoice) return DraftEndpointReason.none;
    auto endpointSilence = dur!"msecs"(cast(long) (endpointSilenceSeconds * 1_000));
    if (!hasMinimumSpeech) {
        return timeSinceStrongVoice >= endpointSilence
            ? DraftEndpointReason.recognizedShortSpeech
            : DraftEndpointReason.none;
    }
    auto stableDuration = dur!"msecs"(cast(long) (
        max(draftEndpointStableMinSeconds, endpointSilenceSeconds) * 1_000
    ));
    return timeSinceDraftChange >= stableDuration && timeSinceStrongVoice >= stableDuration
        ? DraftEndpointReason.stableDraft
        : DraftEndpointReason.none;
}

unittest
{
    assert(selectDraftEndpointReason(
        true,
        true,
        false,
        false,
        dur!"msecs"(0),
        dur!"msecs"(1_000),
        1.0,
        4.0,
    ) == DraftEndpointReason.recognizedShortSpeech);
    assert(selectDraftEndpointReason(
        false,
        true,
        false,
        false,
        dur!"msecs"(0),
        dur!"msecs"(5_000),
        1.0,
        4.0,
    ) == DraftEndpointReason.none);
    assert(selectDraftEndpointReason(
        true,
        true,
        false,
        true,
        dur!"msecs"(3_999),
        dur!"msecs"(5_000),
        1.0,
        4.0,
    ) == DraftEndpointReason.none);
    assert(selectDraftEndpointReason(
        true,
        true,
        false,
        true,
        dur!"msecs"(4_000),
        dur!"msecs"(4_000),
        1.0,
        4.0,
    ) == DraftEndpointReason.stableDraft);
}

private void sendTypedTextTurn(
    scope WebSocket socket,
    ConversationPort conversations,
    SessionKey session,
    LiveAudioStartRequest start,
    long responseMusicDelayMs,
    ConversationPromptPrewarm promptPrewarm,
    string resourcesRoot,
    VoiceSessionCoordinator lifecycle,
)
{
    sendLiveEndpointDetected(
        socket,
        resourcesRoot,
        start.language,
        "listeningStoppedTyped",
    );
    bool thinkingMusicRequested;
    if (reasoningEnabled(start.reasoningMode)) {
        sendLiveThinkingMusic(socket, "play");
        thinkingMusicRequested = true;
    }
    sendLiveFinalTranscript(socket, "", start.text, start.language);
    lifecycle.awaitResponse();
    streamLiveTextTurn(
        socket,
        conversations,
        session,
        liveTextTurnRequest(start, start.text, start.language),
        UserAudioArtifactRecord(),
        promptPrewarm,
        thinkingMusicRequested,
        start.reasoningMode,
        responseMusicDelayMs,
        lifecycle,
    );
}

private void streamLiveTextTurn(
    scope WebSocket socket,
    ConversationPort conversations,
    SessionKey session,
    ConversationTurnRequest turnRequest,
    UserAudioArtifactRecord userAudio,
    ConversationPromptPrewarm promptPrewarm,
    bool thinkingMusicRequested,
    ReasoningMode reasoningMode,
    long responseMusicDelayMs,
    VoiceSessionCoordinator lifecycle,
)
{
    bool responseStarted;
    bool thinkingMusicStopped;
    auto emit = (ConversationEvent event) {
        lifecycle.observeConversation(event.kind);
        if (event.kind == ConversationEventKind.status && !responseStarted) {
            responseStarted = true;
            if (reasoningMode == ReasoningMode.off && !thinkingMusicRequested) {
                sendLiveThinkingMusic(socket, "play", responseMusicDelayMs);
                thinkingMusicRequested = true;
            }
        }
        if (
            thinkingMusicRequested
            && !thinkingMusicStopped
            && (
                event.kind == ConversationEventKind.assistantDelta
                || event.kind == ConversationEventKind.completed
                || event.kind == ConversationEventKind.failed
            )
        ) {
            sendLiveThinkingMusic(socket, "stop");
            thinkingMusicStopped = true;
        }
        sendTurnEvent(socket, event);
    };
    if (userAudio.artifactKey.length) {
        conversations.runWithUserAudio(
            session,
            turnRequest,
            userAudio,
            emit,
            "audio_live",
            promptPrewarm,
        );
        return;
    }
    conversations.run(session, turnRequest, emit, "audio_live", promptPrewarm);
}

private ConversationTurnRequest liveTextTurnRequest(
    LiveAudioStartRequest start,
    LiveAudioCommit commit,
    string userText,
    string language,
)
{
    return conversationTurnRequest(TextTurnRequest(
        start.sessionId,
        userText,
        start.submissionId,
        start.deviceId,
        language,
        "",
        start.loadMemory,
        commit.reasoningMode,
        commit.model,
    ));
}

private ConversationTurnRequest liveTextTurnRequest(
    LiveAudioStartRequest start,
    string userText,
    string language,
)
{
    return liveTextTurnRequest(
        start,
        LiveAudioCommit(start.reasoningMode, start.model),
        userText,
        language,
    );
}

private struct LiveAudioTransferStats
{
    string inputFormat;
    int sampleRate;
    int channels;
    int bitrate;
    int frameMs;
    ulong serverAudioBytes;
    ulong decodedPcmBytes;
    ulong wsBinaryFrames;
    long decodeMs;

    void acceptPayload(size_t byteCount)
    {
        serverAudioBytes += byteCount;
        wsBinaryFrames++;
    }

    void acceptDecodedPcm(size_t byteCount)
    {
        decodedPcmBytes += byteCount;
    }
}

private string liveAudioMetricsJson(
    LiveAudioTransferStats transferStats,
    double acceptedSeconds,
    double voiceSeconds,
    bool hasEndpointLag,
    long endpointLagMs,
    string endpointReason,
    string audioInputSelector,
    string audioInputLabel,
)
{
    return jsonObject([
        jsonStringField("input_format", transferStats.inputFormat),
        jsonLongField("sample_rate", transferStats.sampleRate),
        jsonLongField("channels", transferStats.channels),
        transferStats.bitrate > 0 ? jsonLongField("bitrate", transferStats.bitrate) : "",
        transferStats.frameMs > 0 ? jsonLongField("frame_ms", transferStats.frameMs) : "",
        jsonUlongField("server_audio_bytes", transferStats.serverAudioBytes),
        jsonUlongField("decoded_pcm_bytes", transferStats.decodedPcmBytes),
        jsonUlongField("ws_binary_frames", transferStats.wsBinaryFrames),
        transferStats.inputFormat != "pcm_s16le" ? jsonLongField("decode_ms", transferStats.decodeMs) : "",
        jsonRawField("accepted_seconds", format!"%.3f"(acceptedSeconds)),
        jsonRawField("voice_seconds", format!"%.3f"(voiceSeconds)),
        hasEndpointLag ? jsonLongField("endpoint_lag_ms", endpointLagMs) : "",
        jsonStringField("endpoint_reason", endpointReason),
        audioInputSelector.length || audioInputLabel.length ? jsonRawField("capture_device", jsonObject([
            jsonStringField("selector", audioInputSelector),
            jsonStringField("label", audioInputLabel),
        ])) : "",
    ]);
}

unittest
{
    import std.json : JSONType, parseJSON;
    import std.math : isClose;

    LiveAudioTransferStats stats;
    stats.inputFormat = "pcm_s16le";
    stats.sampleRate = 16_000;
    stats.channels = 1;
    stats.frameMs = 20;
    stats.acceptPayload(640);
    stats.acceptDecodedPcm(640);
    stats.acceptPayload(1_280);
    stats.acceptDecodedPcm(1_280);

    auto payload = parseJSON(liveAudioMetricsJson(
        stats,
        1.25,
        0.75,
        true,
        702,
        "draft_stable",
        ":0",
        "Yealink BH71",
    ));
    assert(payload.type == JSONType.object);
    assert(payload.object["input_format"].str == "pcm_s16le");
    assert(payload.object["sample_rate"].integer == 16_000);
    assert(payload.object["channels"].integer == 1);
    assert(payload.object["frame_ms"].integer == 20);
    assert(payload.object["server_audio_bytes"].integer == 1_920);
    assert(payload.object["decoded_pcm_bytes"].integer == 1_920);
    assert(payload.object["ws_binary_frames"].integer == 2);
    assert(payload.object["accepted_seconds"].floating.isClose(1.25));
    assert(payload.object["voice_seconds"].floating.isClose(0.75));
    assert(payload.object["endpoint_lag_ms"].integer == 702);
    assert(payload.object["endpoint_reason"].str == "draft_stable");
    assert(payload.object["capture_device"].object["selector"].str == ":0");
    assert(payload.object["capture_device"].object["label"].str == "Yealink BH71");
}

private struct DecodedAudioResult
{
    bool quietCandidateExpired;
    string speechText;
    bool previewObserved;
    string observedSpeechText;
}

private DecodedAudioResult acceptDecodedLiveAudio(
    scope WebSocket socket,
    string resourcesRoot,
    long candidateId,
    LiveAudioTurnState state,
    LivePreviewTranscriber previewTranscriber,
    LiveAudioStartRequest start,
    const(ubyte)[] decodedPcm,
    ref bool audioReceivedReported,
    ref bool speechDetectedReported,
    ref LiveAudioTransferStats transferStats,
)
{
    if (decodedPcm.length) {
        transferStats.acceptDecodedPcm(decodedPcm.length);
        state.acceptPcm16(decodedPcm);
        if (!audioReceivedReported) {
            audioReceivedReported = true;
            sendLiveStatus(
                socket,
                resourcesRoot,
                start.language,
                VoiceEventKind.audioReceiving,
                "audioReceiving",
            );
        }
        if (!speechDetectedReported && state.hasPreviewSamples) {
            speechDetectedReported = true;
            sendLiveStatus(
                socket,
                resourcesRoot,
                start.language,
                VoiceEventKind.speechDetected,
                "speechDetected",
            );
        }
        auto prompt = start.purpose == "session_resume" ? "" : start.text;
        previewTranscriber.submit(state, prompt);
    }
    auto preview = previewTranscriber.pollAcceptedText();
    sendLivePreviewTranscript(socket, preview.displayText, candidateId, preview.revision);
    if (decodedPcm.length && state.noSpeechWaitExceeded) {
        sendLiveStatus(
            socket,
            resourcesRoot,
            start.language,
            VoiceEventKind.listeningRetry,
            "listeningRetry",
        );
        return DecodedAudioResult(
            true,
            preview.speechText,
            preview.observed,
            preview.observedSpeechText,
        );
    }
    return DecodedAudioResult(
        false,
        preview.speechText,
        preview.observed,
        preview.observedSpeechText,
    );
}

private long charCount(string text)
{
    long count;
    foreach (dchar _; text) count++;
    return count;
}

private string liveSttMetricsJson(
    string draftMetricsJson,
    FinalAudioTurnTranscription transcription,
    string finalSource,
    double audioSeconds,
    string finalTranscriptText,
)
{
    auto finalMetrics = jsonObject([
        jsonStringField("model", transcription.modelName),
        jsonStringField("source", finalSource),
        jsonRawField("audio_seconds", format!"%.3f"(audioSeconds)),
        jsonLongField("duration_ms", transcription.durationMs),
        jsonBoolField("worker_started", transcription.execution.workerStarted),
        jsonBoolField("worker_restarted", transcription.execution.workerRestarted),
        transcription.execution.workerStarted
            ? jsonLongField("worker_startup_ms", transcription.execution.workerStartupMs)
            : "",
        jsonLongField("queue_ms", transcription.execution.queueMs),
        jsonLongField("inference_ms", transcription.execution.inferenceMs),
        transcription.coveredAudioMs > 0
            ? jsonLongField("covered_audio_ms", transcription.coveredAudioMs)
            : "",
        transcription.maxContextTokens >= 0
            ? jsonLongField("max_context_tokens", transcription.maxContextTokens)
            : "",
        jsonLongField("text_chars", charCount(finalTranscriptText)),
    ]);
    return jsonObject([
        draftMetricsJson.length ? jsonRawField("draft", jsonObjectRaw(draftMetricsJson)) : "",
        jsonRawField("final", finalMetrics),
    ]);
}
