module wheatley.server.turns.audio.live_preview_transcriber;

import core.sync.mutex : Mutex;
import core.time : MonoTime, dur;
import std.algorithm.comparison : max, min;
import std.array : appender, join;
import std.format : format;
import std.string : split, strip;
import vibe.core.core : Task, runTask, sleep;

import wheatley.common.json.object : jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.runtime.temp_files : removeQuietly;
import wheatley.server.stt.runtime_settings : sttRuntimeModelName;
import wheatley.server.stt.transcription : SttExecutionMetrics, SttTranscription;
import wheatley.server.stt.whisper_cpp : WhisperCppWorkers;
import wheatley.server.turns.audio.live_audio_settings : LiveAudioRuntimeSettings;
import wheatley.server.turns.audio.live_audio_state : LiveAudioTurnState;
import wheatley.server.turns.audio.live_preview_boundaries :
    agreeingStableBoundary,
    boundaryAgreements,
    previewWordCount,
    stablePreviewBoundaries;
import wheatley.server.turns.audio.pcm16_wav : temporarySttWavPath, writePcm16Wav;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.turns.audio.live_transcript_text :
    isKnownNormalizedNoSpeechTranscript,
    normalizeLiveTranscript,
    speechTextFromTranscript;

final class LivePreviewTranscriber
{
    private enum workerPollIntervalMillis = 50;

    private LiveAudioRuntimeSettings settings;
    private WhisperCppWorkers workers;
    private Mutex mutex;
    private Task workerTask;
    private bool active = true;
    private bool stopRequested;
    private bool workerStarted;
    private size_t generation = 1;
    private bool hasPendingJob;
    private LivePreviewJob pendingJob;
    private bool hasCompletedResult;
    private LivePreviewResult completedResult;
    private bool hasLastSubmitAt;
    private MonoTime lastSubmitAt;
    private size_t lastSubmittedEndSampleCount;
    private size_t stableEndSampleCount;
    private string stableDisplayedText;
    private string[] previousBoundaryAgreements;
    private long stableSplitCount;
    private string latestDisplayedText;
    private long displayRevision;
    private string latestNormalizedSpeechText;
    private string latestAcceptedSpeechText;
    private LivePreviewMetricRun[] metricRuns;

    this(LiveAudioRuntimeSettings settings, WhisperCppWorkers workers)
    {
        this.settings = settings;
        this.workers = workers;
        this.mutex = new Mutex;
    }

    void stop()
    {
        seal();
    }

    void seal()
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        active = false;
        stopRequested = true;
        generation++;
        hasPendingJob = false;
        hasCompletedResult = false;
    }

    @property string acceptedText()
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        return latestAcceptedSpeechText;
    }

    string metricsJson()
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        if (!metricRuns.length)
            return "";

        auto runs = appender!string;
        runs.put("[");
        long totalMs;
        double totalWindowAudioSeconds = 0.0;
        double maximumWindowAudioSeconds = 0.0;
        foreach (index, run; metricRuns)
        {
            if (index)
                runs.put(",");
            totalMs += run.durationMs;
            totalWindowAudioSeconds += run.windowAudioSeconds;
            maximumWindowAudioSeconds = max(maximumWindowAudioSeconds, run.windowAudioSeconds);
            runs.put(jsonObject([
                    jsonLongField("index", cast(long) index),
                    jsonStringField("started_at", run.startedAt),
                    jsonRawField("audio_seconds", format!"%.3f"(run.sourceAudioSeconds)),
                    jsonRawField("window_start_seconds", format!"%.3f"(run.windowStartSeconds)),
                    jsonRawField("window_audio_seconds", format!"%.3f"(run.windowAudioSeconds)),
                    jsonLongField("duration_ms", run.durationMs),
                    jsonBoolField("worker_started", run.execution.workerStarted),
                    jsonBoolField("worker_restarted", run.execution.workerRestarted),
                    run.execution.workerStarted
                    ? jsonLongField("worker_startup_ms", run.execution.workerStartupMs): "",
                    jsonLongField("queue_ms", run.execution.queueMs),
                    jsonLongField("inference_ms", run.execution.inferenceMs),
                    jsonLongField("text_chars", run.textChars),
                    jsonLongField("stable_prefix_words", run.stablePrefixWords),
                    jsonBoolField("applied", run.applied),
                    jsonBoolField("stabilized", run.stabilized),
                    run.boundaryKind.length
                        ? jsonStringField("boundary_kind", run.boundaryKind)
                        : "",
                ]));
        }
        runs.put("]");

        return jsonObject([
            jsonStringField("model", sttRuntimeModelName(settings.previewStt)),
            jsonRawField("runs", runs.data),
            jsonLongField("total_ms", totalMs),
            jsonRawField("total_window_audio_seconds", format!"%.3f"(totalWindowAudioSeconds)),
            jsonRawField("maximum_window_audio_seconds", format!"%.3f"(maximumWindowAudioSeconds)),
            jsonLongField("split_count", stableSplitCount),
            jsonLongField("stable_prefix_words", previewWordCount(stableDisplayedText)),
        ]);
    }

    void submit(
        LiveAudioTurnState state,
        string prompt,
    )
    {
        if (!active || !state.hasPreviewSamples)
            return;
        if (state.currentSilenceSeconds > previewVoiceGraceSeconds())
            return;
        auto preview = state.previewSamples();
        if (!preview.samples.length || preview.endSampleCount == lastSubmittedEndSampleCount)
            return;
        auto windowSamples = preview.samples[stableEndSampleCount .. $];
        auto windowAudioSeconds = sampleDurationSeconds(
            windowSamples.length,
            settings.sampleRate,
            settings.channels,
        );
        if (windowAudioSeconds < previewMinAudioSeconds())
            return;

        auto now = MonoTime.currTime;
        if (
            hasLastSubmitAt &&
            now - lastSubmitAt < dur!"msecs"(cast(long)(previewIntervalSeconds() * 1_000))
            )
        {
            return;
        }

        hasLastSubmitAt = true;
        lastSubmitAt = now;
        lastSubmittedEndSampleCount = preview.endSampleCount;

        queuePreview(
            windowSamples,
            stableEndSampleCount,
            preview.endSampleCount,
            sampleDurationSeconds(preview.endSampleCount, settings.sampleRate, settings.channels),
            windowAudioSeconds,
            previewPrompt(prompt, stableDisplayedText, settings.previewStablePromptWords),
            previewWordCount(stableDisplayedText),
        );
    }

    LivePreviewTranscript pollAcceptedText()
    {
        auto result = takeCompletedResult();
        if (!result.found)
            return LivePreviewTranscript.init;
        if (result.generation != currentGeneration())
            return LivePreviewTranscript.init;
        if (result.startSampleCount != stableEndSampleCount)
            return LivePreviewTranscript.init;

        auto accepted = acceptPreviewTranscription(result);
        markRunResult(
            result.metricIndex,
            accepted.displayText.length > 0,
            accepted.stabilized,
            accepted.boundaryKind,
        );
        return accepted;
    }

    private void queuePreview(
        short[] samples,
        size_t startSampleCount,
        size_t endSampleCount,
        double sourceAudioSeconds,
        double windowAudioSeconds,
        string prompt,
        long stablePrefixWords,
    )
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        if (!active || stopRequested)
            return;
        pendingJob = LivePreviewJob(
            true,
            generation,
            startSampleCount,
            endSampleCount,
            samples,
            sourceAudioSeconds,
            windowAudioSeconds,
            prompt,
            stablePrefixWords,
        );
        hasPendingJob = true;
        startWorkerLocked();
    }

    private void startWorkerLocked()
    {
        if (workerStarted)
            return;
        workerStarted = true;
        workerTask = runTask(() nothrow{
            try
            {
                runWorkerLoop();
            }
            catch (Throwable)
            {
                requestStop();
            }
        });
    }

    private void runWorkerLoop()
    {
        while (true)
        {
            auto job = takePendingJob();
            if (job.found)
            {
                runPreviewJob(job);
                continue;
            }
            if (shouldStopWorker())
                break;
            sleep(dur!"msecs"(workerPollIntervalMillis));
        }
    }

    private LivePreviewJob takePendingJob()
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        if (!hasPendingJob)
            return LivePreviewJob.init;
        auto job = pendingJob;
        pendingJob = LivePreviewJob.init;
        hasPendingJob = false;
        return job;
    }

    private void runPreviewJob(LivePreviewJob job)
    {
        try
        {
            auto startedAt = nowIso();
            auto started = MonoTime.currTime;
            auto transcription = transcribeLiveAudioDraft(workers, job.samples, settings, job.prompt);
            auto text = transcription.text.strip;
            auto durationMs = cast(long)(MonoTime.currTime - started).total!"msecs";
            auto metricIndex = rememberRun(
                startedAt,
                job.sourceAudioSeconds,
                sampleDurationSeconds(job.startSampleCount, settings.sampleRate, settings.channels),
                job.windowAudioSeconds,
                durationMs,
                charCount(text),
                job.stablePrefixWords,
                transcription.execution,
            );
            storeCompletedResult(LivePreviewResult(
                    true,
                    job.generation,
                    job.startSampleCount,
                    job.endSampleCount,
                    job.windowAudioSeconds,
                    metricIndex,
                    transcription,
            ));
        }
        catch (Exception)
        {
        }
    }

    private size_t rememberRun(
        string startedAt,
        double sourceAudioSeconds,
        double windowStartSeconds,
        double windowAudioSeconds,
        long durationMs,
        long textChars,
        long stablePrefixWords,
        SttExecutionMetrics execution,
    )
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        auto index = metricRuns.length;
        metricRuns ~= LivePreviewMetricRun(
            startedAt,
            sourceAudioSeconds,
            windowStartSeconds,
            windowAudioSeconds,
            durationMs,
            textChars,
            stablePrefixWords,
            false,
            false,
            "",
            execution,
        );
        return index;
    }

    private void markRunResult(
        size_t index,
        bool applied,
        bool stabilized,
        string boundaryKind,
    )
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        if (index >= metricRuns.length)
            return;
        metricRuns[index].applied = applied;
        metricRuns[index].stabilized = stabilized;
        metricRuns[index].boundaryKind = boundaryKind;
    }

    private void storeCompletedResult(LivePreviewResult result)
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        if (stopRequested || result.generation != generation)
            return;
        completedResult = result;
        hasCompletedResult = true;
    }

    private LivePreviewResult takeCompletedResult()
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        if (!hasCompletedResult)
            return LivePreviewResult.init;
        auto result = completedResult;
        completedResult = LivePreviewResult.init;
        hasCompletedResult = false;
        return result;
    }

    private size_t currentGeneration()
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        return generation;
    }

    private bool shouldStopWorker()
    {
        mutex.lock();
        scope (exit)
            mutex.unlock();
        return stopRequested && !hasPendingJob;
    }

    private void requestStop() nothrow
    {
        try
        {
            mutex.lock();
            scope (exit)
                mutex.unlock();
            stopRequested = true;
            active = false;
            hasPendingJob = false;
            hasCompletedResult = false;
        }
        catch (Throwable)
        {
        }
    }

    private double previewIntervalSeconds() const
    {
        return settings.partialTranscriptIntervalSeconds;
    }

    private double previewMinAudioSeconds() const
    {
        return settings.partialTranscriptMinAudioSeconds;
    }

    private double previewVoiceGraceSeconds() const
    {
        return settings.previewVoiceGraceSeconds;
    }

    private LivePreviewTranscript acceptPreviewTranscription(LivePreviewResult result)
    {
        LivePreviewTranscript accepted;
        accepted.observed = true;
        auto displayTail = speechTextFromTranscript(result.transcription.text);
        auto boundaries = stablePreviewBoundaries(
            result.transcription,
            result.windowAudioSeconds,
            settings.previewBoundaries,
        );
        auto stableBoundary = agreeingStableBoundary(boundaries, previousBoundaryAgreements);
        if (stableBoundary.found)
        {
            stableDisplayedText = joinPreviewText(
                stableDisplayedText,
                stableBoundary.prefixText,
            );
            auto relativeEndSamples = samplesForMilliseconds(stableBoundary.endMs);
            stableEndSampleCount = min(
                result.endSampleCount,
                result.startSampleCount + relativeEndSamples,
            );
            displayTail = stableBoundary.tailText;
            previousBoundaryAgreements = null;
            stableSplitCount++;
            accepted.stabilized = true;
            accepted.boundaryKind = stableBoundary.kind;
        }
        else
        {
            previousBoundaryAgreements = boundaryAgreements(boundaries);
        }

        auto displayText = joinPreviewText(stableDisplayedText, displayTail);
        if (displayText.length && displayText != latestDisplayedText)
        {
            latestDisplayedText = displayText;
            accepted.displayText = displayText;
            accepted.revision = ++displayRevision;
        }

        auto speechText = speechTextFromTranscript(displayText);
        accepted.observedSpeechText = speechText;
        auto normalizedSpeechText = normalizeLiveTranscript(speechText);
        if (isKnownNormalizedNoSpeechTranscript(normalizedSpeechText))
            return accepted;
        if (normalizedSpeechText == latestNormalizedSpeechText)
            return accepted;
        latestNormalizedSpeechText = normalizedSpeechText;
        latestAcceptedSpeechText = speechText;
        accepted.speechText = speechText;
        return accepted;
    }

    private size_t samplesForMilliseconds(long milliseconds) const
    {
        return cast(size_t) (
            cast(double) milliseconds * settings.sampleRate * settings.channels / 1_000.0
        );
    }
}

struct LivePreviewTranscript
{
    bool observed;
    string displayText;
    string speechText;
    string observedSpeechText;
    bool stabilized;
    string boundaryKind;
    long revision;
}

private struct LivePreviewJob
{
    bool found;
    size_t generation;
    size_t startSampleCount;
    size_t endSampleCount;
    short[] samples;
    double sourceAudioSeconds;
    double windowAudioSeconds;
    string prompt;
    long stablePrefixWords;
}

private struct LivePreviewResult
{
    bool found;
    size_t generation;
    size_t startSampleCount;
    size_t endSampleCount;
    double windowAudioSeconds;
    size_t metricIndex;
    SttTranscription transcription;
}

private struct LivePreviewMetricRun
{
    string startedAt;
    double sourceAudioSeconds;
    double windowStartSeconds;
    double windowAudioSeconds;
    long durationMs;
    long textChars;
    long stablePrefixWords;
    bool applied;
    bool stabilized;
    string boundaryKind;
    SttExecutionMetrics execution;
}

private string joinPreviewText(string prefix, string tail)
{
    auto left = prefix.strip;
    auto right = tail.strip;
    if (!left.length) return right;
    if (!right.length) return left;
    return left ~ " " ~ right;
}

private string previewPrompt(string original, string stableText, long stablePromptWords)
{
    auto words = stableText.split;
    auto context = words.length > stablePromptWords
        ? words[$ - cast(size_t) stablePromptWords .. $].join(" ")
        : words.join(" ");
    return joinPreviewText(original, context);
}

SttTranscription transcribeLiveAudioDraft(
    WhisperCppWorkers workers,
    const(short)[] samples,
    LiveAudioRuntimeSettings settings,
    string prompt,
)
{
    auto path = temporarySttWavPath(settings.previewStt.appDataRoot, "preview");
    scope (exit)
        removeQuietly(path);
    writePcm16Wav(path, samples, settings.sampleRate, settings.channels);
    auto transcript = workers.transcribe(
        settings.previewStt,
        path,
        prompt,
        true,
        true,
    );
    transcript.text = transcript.text.strip;
    return transcript;
}

private double sampleDurationSeconds(size_t sampleCount, int sampleRate, ushort channels)
{
    if (sampleRate <= 0 || channels == 0)
        return 0.0;
    return cast(double) sampleCount / cast(double)(sampleRate * channels);
}

private long charCount(string text)
{
    long count;
    foreach (dchar _; text)
        count++;
    return count;
}

unittest
{
    import std.json : JSONType, parseJSON;

    LiveAudioRuntimeSettings settings;
    settings.sampleRate = 16_000;
    settings.channels = 1;
    auto preview = new LivePreviewTranscriber(settings, null);
    preview.stableSplitCount = 1;
    preview.stableDisplayedText = "one two three four five";
    preview.metricRuns ~= LivePreviewMetricRun(
        "2026-08-02T00:00:00Z",
        31.627,
        3.0,
        28.627,
        500,
        200,
        5,
        true,
        true,
        "sentence",
        SttExecutionMetrics.init,
    );
    auto payload = parseJSON(preview.metricsJson);
    assert(payload.type == JSONType.object);
    assert(payload.object["total_window_audio_seconds"].floating == 28.627);
    assert(payload.object["maximum_window_audio_seconds"].floating == 28.627);
    assert(payload.object["split_count"].integer == 1);
    assert(payload.object["stable_prefix_words"].integer == 5);
    preview.stop();
}
