module wheatley.client.console.speech.streaming;

import core.time : MonoTime, dur;
import core.sync.mutex : Mutex;
import std.string : strip;

import vibe.core.core : Task, runTask, sleep;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.client.console.util.closeable_queue : CloseableQueue;
import wheatley.client.console.ui.output : writeError;
import wheatley.client.console.speech.playback :
    ConsoleSpeechPlayback,
    PreparedSpeechFile,
    prepareSpeechFileWithMetrics,
    speechFileDurationSeconds;
import wheatley.client.console.speech.playback_events : ConsolePlaybackEventState;
import wheatley.client.console.speech.streaming_settings :
    ConsoleStreamingSpeechSettings,
    resolvedSettings;
import wheatley.common.api.audio_playback : AudioPlaybackEventKind;
import wheatley.server.tts.segment_buffer : TtsSegmentBuffer;
import wheatley.common.runtime.temp_files : removeQuietly;

enum waitPollMillis = 80;

final class ConsoleStreamingSpeaker
{
    private ConsoleStreamingSpeechSettings settings;
    private TtsSegmentBuffer buffer;
    private CloseableQueue!string textQueue;
    private CloseableQueue!PreparedSpeechFile preparedQueue;
    private Task prepareTask;
    private Task playbackTask;
    private ConsoleSpeechPlayback playback;
    private bool inputClosed;
    private bool stopped;
    private bool finished;
    private string errorMessage;
    private Mutex metricsLock;
    private ConsoleStreamingSpeechMetrics metrics;
    private Mutex playbackEventLock;
    private ConsolePlaybackEventState playbackEvents;

    this(ConsoleStreamingSpeechSettings settings)
    {
        this.settings = resolvedSettings(settings);
        this.buffer = TtsSegmentBuffer();
        this.textQueue = new CloseableQueue!string;
        this.preparedQueue = new CloseableQueue!PreparedSpeechFile;
        this.metricsLock = new Mutex();
        this.playbackEventLock = new Mutex();
        this.playback = new ConsoleSpeechPlayback;
        if (this.settings.enabled) startTasks();
    }

    void setLanguage(string language)
    {
        if (language.length) settings.language = language;
    }

    void feed(string text)
    {
        if (!settings.enabled || stopped || inputClosed || !text.length) return;
        reportQueued();
        markTextReceived();
        enqueueSegments(buffer.feed(text));
    }

    void feedImmediate(string text, bool reportPlayback = true)
    {
        auto clean = text.strip;
        if (!settings.enabled || stopped || inputClosed || !clean.length) return;
        if (reportPlayback) reportQueued();
        markTextReceived();
        textQueue.push(clean);
    }

    void finish()
    {
        if (!settings.enabled || finished) return;
        finished = true;
        if (!stopped) {
            enqueueSegments(buffer.finish());
        }
        inputClosed = true;
        textQueue.close();
        joinTasks();
        reportFinished();
        reportError();
    }

    void stop()
    {
        if (!settings.enabled) return;
        cancel();
        finished = true;
        joinTasks();
    }

    void cancel()
    {
        if (!settings.enabled || stopped) return;
        stopped = true;
        inputClosed = true;
        buffer.clear();
        textQueue.close();
        preparedQueue.close();
        playback.stop();
        reportCancelled();
    }

    bool playbackActive()
    {
        return settings.enabled && playback.active();
    }

    long playbackAgeMillis()
    {
        return settings.enabled ? playback.activeMillis() : 0;
    }

    bool pausePlayback()
    {
        return settings.enabled && !stopped && playback.pause();
    }

    void resumePlayback()
    {
        if (settings.enabled && !stopped) playback.resume();
    }

    private void startTasks()
    {
        prepareTask = runTask(() nothrow {
            try {
                runPrepareLoop();
            } catch (Throwable error) {
                recordError(error);
            }
        });
        playbackTask = runTask(() nothrow {
            try {
                runPlaybackLoop();
            } catch (Throwable error) {
                recordError(error);
            }
        });
    }

    private void runPrepareLoop()
    {
        auto client = new ConsoleApiClient(settings.apiBase);
        while (!stopped) {
            auto next = textQueue.pop();
            if (!next.found) {
                if (textQueue.closedAndEmpty) break;
                sleepPoll();
                continue;
            }

            auto prepared = prepareSpeechFileWithMetrics(
                client,
                settings.profileId,
                next.value,
                settings.language,
                settings.appDataRoot,
            );
            {
                metricsLock.lock();
                scope(exit) metricsLock.unlock();
                metrics.addPrepared(prepared);
            }
            preparedQueue.push(prepared);
        }
        preparedQueue.close();
    }

    private void runPlaybackLoop()
    {
        PreparedSpeechFile[] buffered;
        bool streamDone;

        while (!stopped && (!streamDone || buffered.length)) {
            if (!buffered.length) {
                auto next = preparedQueue.pop();
                if (!next.found) {
                    if (preparedQueue.closedAndEmpty) break;
                    sleepPoll();
                    continue;
                }
                buffered ~= next.value;
                prebuffer(buffered, streamDone);
            }

            auto current = buffered[0];
            buffered = buffered[1 .. $];
            scope(exit) removeQuietly(current.audioPath);
            auto audioSeconds = current.audioSeconds > 0.0
                ? current.audioSeconds
                : speechFileDurationSeconds(current.audioPath);
            {
                metricsLock.lock();
                scope(exit) metricsLock.unlock();
                metrics.markPlaybackStart();
                metrics.addSpokenAudioSeconds(audioSeconds);
            }
            playback.play(settings.playbackCommand, current.audioPath, () nothrow {
                reportStarted();
            });

            auto next = preparedQueue.pop();
            if (next.found) {
                buffered ~= next.value;
            } else if (preparedQueue.closedAndEmpty) {
                streamDone = true;
            }
        }
    }

    private void prebuffer(ref PreparedSpeechFile[] buffered, ref bool streamDone)
    {
        if (
            inputClosed
            || settings.playbackPrebufferChunks <= 1
            || buffered.length >= settings.playbackPrebufferChunks
        ) {
            return;
        }

        auto startedAt = MonoTime.currTime;
        while (
            !stopped
            && !inputClosed
            && buffered.length < settings.playbackPrebufferChunks
            && !preparedQueue.closedAndEmpty
            && elapsedSeconds(startedAt) < settings.playbackPrebufferMaxWaitSeconds
        ) {
            auto next = preparedQueue.pop();
            if (next.found) {
                buffered ~= next.value;
                continue;
            }
            sleepPoll();
        }
        if (preparedQueue.closedAndEmpty) streamDone = true;
    }

    private void enqueueSegments(string[] segments)
    {
        foreach (segment; segments) {
            if (segment.strip.length) textQueue.push(segment);
        }
    }

    private void markTextReceived()
    {
        metricsLock.lock();
        scope(exit) metricsLock.unlock();
        metrics.markTextReceived();
    }

    private void joinTasks()
    {
        if (prepareTask) prepareTask.join();
        if (playbackTask) playbackTask.join();
    }

    private void recordError(Throwable error) nothrow
    {
        try {
            if (!errorMessage.length) {
                errorMessage = error.msg.length ? error.msg : "Streaming speech failed";
            }
            stopped = true;
            inputClosed = true;
            textQueue.close();
            preparedQueue.close();
            playback.stop();
            reportFailed(error.msg.length ? error.msg : "Streaming speech failed");
        } catch (Throwable) {
        }
    }

    private void reportError()
    {
        if (errorMessage.length) writeError("speech: " ~ errorMessage);
    }

    private void reportQueued() nothrow
    {
        try {
            playbackEventLock.lock();
            scope(exit) playbackEventLock.unlock();
            if (settings.onPlaybackEvent is null || !playbackEvents.observe(AudioPlaybackEventKind.queued)) return;
            settings.onPlaybackEvent(AudioPlaybackEventKind.queued, "");
        } catch (Throwable) {
        }
    }

    private void reportStarted() nothrow
    {
        try {
            playbackEventLock.lock();
            scope(exit) playbackEventLock.unlock();
            if (settings.onPlaybackEvent is null || !playbackEvents.observe(AudioPlaybackEventKind.started)) return;
            settings.onPlaybackEvent(AudioPlaybackEventKind.started, "");
        } catch (Throwable) {
        }
    }

    private void reportFinished() nothrow
    {
        reportTerminal(AudioPlaybackEventKind.finished, "");
    }

    private void reportCancelled() nothrow
    {
        reportTerminal(AudioPlaybackEventKind.cancelled, "");
    }

    private void reportFailed(string message) nothrow
    {
        reportTerminal(AudioPlaybackEventKind.failed, message);
    }

    private void reportTerminal(AudioPlaybackEventKind kind, string message) nothrow
    {
        try {
            playbackEventLock.lock();
            scope(exit) playbackEventLock.unlock();
            if (settings.onPlaybackEvent is null || !playbackEvents.observe(kind)) return;
            settings.onPlaybackEvent(kind, message);
        } catch (Throwable) {
        }
    }

    ConsoleStreamingSpeechMetrics currentMetrics()
    {
        metricsLock.lock();
        scope(exit) metricsLock.unlock();
        return metrics;
    }
}

struct ConsoleStreamingSpeechMetrics
{
    string model;
    long firstAudioMs;
    long synthesisMs;
    long chunks;
    double spokenAudioSeconds = 0.0;
    bool hasFirstText;
    bool hasFirstPlayback;
    MonoTime firstTextMono;
    MonoTime firstPlaybackMono;

    void markTextReceived()
    {
        if (hasFirstText) return;
        firstTextMono = MonoTime.currTime;
        hasFirstText = true;
    }

    void addPrepared(PreparedSpeechFile prepared)
    {
        if (!model.length && prepared.model.length) model = prepared.model;
        synthesisMs += prepared.prepareMs;
        chunks++;
    }

    void addSpokenAudioSeconds(double audioSeconds)
    {
        if (audioSeconds > 0.0) spokenAudioSeconds += audioSeconds;
    }

    void markPlaybackStart()
    {
        if (hasFirstPlayback) return;
        firstPlaybackMono = MonoTime.currTime;
        hasFirstPlayback = true;
        if (hasFirstText) {
            firstAudioMs = cast(long) (firstPlaybackMono - firstTextMono).total!"msecs";
        }
    }

    bool hasTtsMetrics() const
    {
        return chunks > 0;
    }
}

private void sleepPoll()
{
    sleep(dur!"msecs"(waitPollMillis));
}

private double elapsedSeconds(MonoTime startedAt)
{
    auto elapsed = MonoTime.currTime - startedAt;
    return elapsed.total!"msecs" / 1000.0;
}
