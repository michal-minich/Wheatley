module wheatley.client.console.audio.runtime;

import std.uuid : randomUUID;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.client.console.audio.chimes :
    ConsoleListeningChimes,
    playListeningStartChime,
    playListeningStopChime;
import wheatley.client.console.audio.output_state : ConsoleOutputState;
import wheatley.client.console.audio.playback_reporter : ConsoleAudioPlaybackReporter;
import wheatley.client.console.audio.thinking_music : ConsoleThinkingMusic;
import wheatley.client.console.config : ConsoleConfig;
import wheatley.client.console.speech.interrupt :
    ConsoleSpeechInterruptMonitor,
    ConsoleSpeechInterruptPlayback,
    consoleSpeechInterruptSettings;
import wheatley.client.console.speech.streaming :
    ConsoleStreamingSpeaker,
    ConsoleStreamingSpeechMetrics;
import wheatley.client.console.speech.streaming_settings :
    ConsoleSpeechPlaybackIdentity,
    ConsoleStreamingSpeechSettings;
import wheatley.client.console.speech.playback : playSpeechFile, prepareSpeechFile;
import wheatley.common.api.audio_playback :
    AudioPlaybackEvent,
    AudioPlaybackEventKind,
    AudioPlaybackSource;
import wheatley.common.api.session : SessionKey;
import wheatley.common.runtime.temp_files : removeQuietly;

/// Device-local owner of console cues, music, synthesized speech, playback
/// interruption, and their capture/output exclusion rules.
final class ConsoleAudioRuntime
{
    private ConsoleListeningChimes chimes;
    private ConsoleThinkingMusic thinkingMusic;
    private ConsoleStreamingSpeaker speaker;
    private ConsoleSpeechInterruptMonitor interruptMonitor;
    private ConsoleOutputState state;
    private ConsoleApiClient client;
    private ConsoleAudioPlaybackReporter playbackReporter;

    this(ConsoleConfig config, ConsoleApiClient client)
    {
        this.client = client;
        chimes = ConsoleListeningChimes(
            config.appDataRoot,
            config.resourcesRoot,
            config.ttsPlaybackCommand,
        );
        thinkingMusic = new ConsoleThinkingMusic(
            config.appDataRoot,
            config.profileId,
            client,
        );
    }

    void beginTurn(ConsoleStreamingSpeechSettings settings, string sessionId, string turnId)
    {
        cancelTurn();
        auto identity = ConsoleSpeechPlaybackIdentity(
            SessionKey(settings.profileId, sessionId),
            turnId,
            "console-speech-" ~ randomUUID().toString(),
        );
        settings.playbackIdentity = identity;
        auto reporter = new ConsoleAudioPlaybackReporter(client);
        settings.onPlaybackEvent = (AudioPlaybackEventKind kind, string errorMessage) nothrow {
            reporter.submit(AudioPlaybackEvent(
                identity.session,
                identity.turnId,
                identity.outputId,
                AudioPlaybackSource.answer,
                kind,
                "native_process",
                errorMessage,
            ));
        };
        playbackReporter = reporter;
        speaker = new ConsoleStreamingSpeaker(settings);
        state.finish();
    }

    void beginCapture() nothrow
    {
        auto cancelSpeech = state.speaking;
        stopThinkingMusic();
        try {
            if (cancelSpeech && speaker !is null) speaker.cancel();
        } catch (Throwable) {
        }
        if (cancelSpeech) closePlaybackReporter();
        state.beginCapture();
    }

    void releaseCapture()
    {
        if (state.capturing)
            state.releaseCapture();
    }

    void playListeningStart()
    {
        playListeningStartChime(chimes);
    }

    void playListeningStop()
    {
        playListeningStopChime(chimes);
    }

    void applyThinkingMusic(string action, long delayMs) nothrow
    {
        if (action == "stop") {
            stopThinkingMusic();
            return;
        }
        if (!state.beginThinking()) return;
        if (delayMs > 0)
            thinkingMusic.playAfter(delayMs);
        else
            thinkingMusic.play();
    }

    void stopThinkingMusic() nothrow
    {
        thinkingMusic.stop();
        state.stopThinking();
    }

    void speakSystem(ConsoleConfig config, string message)
    {
        if (!config.speak || !message.length) return;
        string speechPath;
        scope(exit) removeQuietly(speechPath);
        speechPath = prepareSpeechFile(
            client,
            config.profileId,
            message,
            config.language,
            config.appDataRoot,
        );
        playSpeechFile(config.ttsPlaybackCommand, speechPath);
    }

    void setSpeechLanguage(string language)
    {
        requireSpeaker.setLanguage(language);
    }

    void feedSpeech(string text)
    {
        beginSpeaking();
        requireSpeaker.feed(text);
    }

    void feedSpeechImmediate(string text)
    {
        beginSpeaking();
        requireSpeaker.feedImmediate(text, false);
    }

    void finishSpeech()
    {
        requireSpeaker.finish();
        closePlaybackReporter();
        state.finish();
    }

    void stopSpeech()
    {
        requireSpeaker.stop();
        closePlaybackReporter();
        state.finish();
    }

    void cancelSpeech()
    {
        requireSpeaker.cancel();
        closePlaybackReporter();
        state.finish();
    }

    void startSpeechInterrupt(ConsoleConfig config, string ffmpegPath, void delegate() onStop)
    {
        if (interruptMonitor !is null) return;
        interruptMonitor = new ConsoleSpeechInterruptMonitor(
            consoleSpeechInterruptSettings(config, ffmpegPath),
            ConsoleSpeechInterruptPlayback(
                () => requireSpeaker.playbackActive(),
                () => requireSpeaker.playbackAgeMillis(),
                () => requireSpeaker.pausePlayback(),
                () => requireSpeaker.resumePlayback(),
            ),
            onStop,
        );
    }

    void stopSpeechInterrupt()
    {
        if (interruptMonitor is null) return;
        interruptMonitor.stop();
        interruptMonitor.join();
        interruptMonitor = null;
    }

    ConsoleStreamingSpeechMetrics speechMetrics()
    {
        return requireSpeaker.currentMetrics;
    }

    void cancelTurn() nothrow
    {
        try stopSpeechInterrupt(); catch (Throwable) {}
        stopThinkingMusic();
        try {
            if (speaker !is null) speaker.stop();
        } catch (Throwable) {
        }
        closePlaybackReporter();
        speaker = null;
        state.finish();
    }

    private void beginSpeaking()
    {
        state.beginSpeaking();
    }

    private void closePlaybackReporter() nothrow
    {
        auto reporter = playbackReporter;
        playbackReporter = null;
        if (reporter is null) return;
        reporter.close();
    }

    private ConsoleStreamingSpeaker requireSpeaker()
    {
        if (speaker is null) throw new Exception("Console audio turn has not started");
        return speaker;
    }
}
