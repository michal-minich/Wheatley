module wheatley.server.turns.audio.live_audio_state;

import core.time : MonoTime;
import std.algorithm.comparison : max, min;
import std.math : sqrt;

import wheatley.server.turns.audio.live_audio_settings :
    LiveAudioRuntimeSettings,
    LiveFinalSelectionSettings,
    LivePreviewBoundarySettings,
    LiveSessionResumeAudioSettings,
    LiveVadAdaptiveSettings;

struct LiveAudioPreviewWindow
{
    short[] samples;
    size_t endSampleCount;
}

final class LiveAudioTurnState
{
    private LiveAudioRuntimeSettings settings;
    private short[] frames;
    private short[] preRollFrames;
    private ulong capturedSampleCount;
    private ulong voiceSampleCount;
    private ulong speechStartedSampleCount;
    private ulong lastVoiceSampleCount;
    private size_t lastVoiceFrameSampleCount;
    private double latestRms;
    private double latestThreshold;
    private double noiseFloorRms;
    private bool started;
    private bool hasLastVoice;
    private bool latestHasVoice;
    private bool hasNoiseFloor;
    private MonoTime lastVoiceMono;

    this(LiveAudioRuntimeSettings settings)
    {
        this.settings = settings;
    }

    void setSilenceSeconds(double seconds)
    {
        settings.silenceSeconds = seconds;
    }

    @property double endpointSilenceSeconds() const
    {
        return settings.silenceSeconds;
    }

    @property double draftEndpointStableMinSeconds() const
    {
        return settings.draftEndpointStableMinSeconds;
    }

    @property bool endpointReached() const
    {
        if (!started || !hasLastVoice) return false;
        if (maximumDurationReached) return true;
        auto silenceSeconds = currentSilenceSeconds;
        auto enoughSilence = silenceSeconds >= settings.silenceSeconds;
        return hasMinimumSpeech && enoughSilence;
    }

    @property bool maximumDurationReached() const
    {
        return started
            && settings.maxUtteranceSeconds > 0.0
            && utteranceSeconds >= settings.maxUtteranceSeconds;
    }

    @property bool hasFinalSamples() const
    {
        return frames.length > 0;
    }

    @property bool hasPreviewSamples() const
    {
        return started && frames.length > 0;
    }

    @property bool latestBlockHasVoice() const
    {
        return latestHasVoice;
    }

    @property double latestBlockRms() const
    {
        return latestRms;
    }

    @property double latestBlockVoiceThreshold() const
    {
        return latestThreshold;
    }

    @property double startVoiceThreshold() const
    {
        return currentStartVoiceThreshold();
    }

    @property double continueVoiceThreshold() const
    {
        return currentContinueVoiceThreshold();
    }

    @property double currentSilenceSeconds() const
    {
        if (!started || !hasLastVoice) return 0.0;
        return cast(double) (capturedSampleCount - lastVoiceSampleCount)
            / cast(double) settings.sampleRate;
    }

    @property bool hasEndpointLag() const
    {
        return started && hasLastVoice;
    }

    long endpointLagMs() const
    {
        if (!hasEndpointLag) return 0;
        return cast(long) (MonoTime.currTime - lastVoiceMono).total!"msecs";
    }

    @property double voiceSeconds() const
    {
        return cast(double) voiceSampleCount / cast(double) settings.sampleRate;
    }

    @property bool hasMinimumSpeech() const
    {
        return voiceSeconds >= max(0.0, settings.minSpeechSeconds);
    }

    @property double previewSeconds() const
    {
        return cast(double) previewSampleCount / cast(double) settings.sampleRate;
    }

    @property bool noSpeechWaitExceeded() const
    {
        return !started
            && settings.maxWaitSeconds > 0
            && capturedSeconds >= settings.maxWaitSeconds;
    }

    @property short[] finalSamples() const
    {
        if (!frames.length) return null;
        if (!lastVoiceFrameSampleCount) return frames.dup;
        auto keepSamples = trailingSilenceKeepSamples();
        auto end = min(frames.length, lastVoiceFrameSampleCount + keepSamples);
        return frames[0 .. end].dup;
    }

    LiveAudioPreviewWindow previewSamples() const
    {
        auto end = previewSampleCount;
        if (!end) return LiveAudioPreviewWindow.init;
        return LiveAudioPreviewWindow(frames[0 .. end].dup, end);
    }

    void acceptPcm16(const(ubyte)[] bytes)
    {
        auto block = pcm16LeSamples(bytes);
        if (!block.length) return;

        auto audioPositionSamples = capturedSampleCount + block.length;
        auto blockRms = rms(block);
        latestRms = blockRms;
        latestThreshold = currentVoiceThreshold(started);
        latestHasVoice = blockRms >= latestThreshold;
        if (latestHasVoice) {
            voiceSampleCount += block.length;
            if (!started) {
                started = true;
                speechStartedSampleCount = capturedSampleCount;
                frames ~= preRollFrames;
                preRollFrames = null;
            }
            lastVoiceSampleCount = audioPositionSamples;
            lastVoiceMono = MonoTime.currTime;
            hasLastVoice = true;
        } else if (!started) {
            rememberNoiseFloor(blockRms);
            appendPreRoll(block);
        } else {
            rememberNoiseFloor(blockRms);
        }

        if (started) {
            frames ~= block;
            if (latestHasVoice) {
                lastVoiceFrameSampleCount = frames.length;
            }
        }

        capturedSampleCount = audioPositionSamples;
    }

    private double currentVoiceThreshold(bool continuing) const
    {
        return continuing ? currentContinueVoiceThreshold() : currentStartVoiceThreshold();
    }

    private double currentStartVoiceThreshold() const
    {
        auto adaptive = settings.vadAdaptive;
        auto configured = max(0.001, settings.vadThreshold);
        auto threshold = max(configured, adaptive.startThreshold);
        if (hasNoiseFloor) {
            threshold = max(threshold, noiseFloorRms * adaptive.noiseFloorStartMultiplier);
        }
        return threshold;
    }

    private double currentContinueVoiceThreshold() const
    {
        // Immediate speech leaves no pre-speech noise-floor sample. Until the
        // first quiet block establishes one, avoid the permissive hysteresis
        // so steady HFP background cannot keep the endpoint open forever.
        auto adaptive = settings.vadAdaptive;
        if (!hasNoiseFloor) return max(0.001, settings.vadThreshold);
        auto configured = max(0.001, settings.vadThreshold * adaptive.continueThresholdScale);
        auto threshold = max(configured, adaptive.continueThreshold);
        if (hasNoiseFloor) {
            threshold = max(threshold, noiseFloorRms * adaptive.noiseFloorContinueMultiplier);
        }
        return threshold;
    }

    private void rememberNoiseFloor(double blockRms)
    {
        if (!hasNoiseFloor) {
            noiseFloorRms = blockRms;
            hasNoiseFloor = true;
            return;
        }
        noiseFloorRms = noiseFloorRms * (1.0 - settings.vadAdaptive.noiseFloorAlpha)
            + blockRms * settings.vadAdaptive.noiseFloorAlpha;
    }

    private size_t trailingSilenceKeepSamples() const
    {
        auto keepSeconds = max(
            0.0,
            settings.trailingSilenceKeepSeconds,
            min(max(0.0, settings.silenceSeconds), settings.trailingSilenceKeepCapSeconds),
        );
        return cast(size_t) (keepSeconds * settings.sampleRate);
    }

    private size_t previewSampleCount() const
    {
        if (!frames.length) return 0;
        if (!lastVoiceFrameSampleCount) return frames.length;
        auto keepSamples = trailingSilenceKeepSamples();
        return min(frames.length, lastVoiceFrameSampleCount + keepSamples);
    }

    private double capturedSeconds() const
    {
        return cast(double) capturedSampleCount / cast(double) settings.sampleRate;
    }

    private double utteranceSeconds() const
    {
        return cast(double) (capturedSampleCount - speechStartedSampleCount)
            / cast(double) (settings.sampleRate * settings.channels);
    }

    private void appendPreRoll(short[] block)
    {
        auto limit = cast(size_t) max(0.0, settings.preRollSeconds * settings.sampleRate);
        if (!limit) {
            preRollFrames = null;
            return;
        }
        preRollFrames ~= block;
        if (preRollFrames.length > limit) {
            preRollFrames = preRollFrames[$ - limit .. $].dup;
        }
    }
}

private short[] pcm16LeSamples(const(ubyte)[] bytes)
{
    auto count = bytes.length / 2;
    auto samples = new short[](count);
    foreach (i; 0 .. count) {
        auto lo = cast(ushort) bytes[i * 2];
        auto hi = cast(ushort) bytes[i * 2 + 1];
        samples[i] = cast(short) ((hi << 8) | lo);
    }
    return samples;
}

private double rms(const(short)[] samples)
{
    if (!samples.length) return 0.0;
    double sum = 0.0;
    foreach (sample; samples) {
        auto normalized = cast(double) sample / 32768.0;
        sum += normalized * normalized;
    }
    return sqrt(sum / samples.length);
}

unittest
{
    auto settings = testLiveAudioSettings();
    settings.silenceSeconds = 1.0;

    auto state = new LiveAudioTurnState(settings);
    state.acceptPcm16(testPcmBlock(settings, 0.025, 0.2));
    assert(state.hasPreviewSamples);

    foreach (_; 0 .. 6) {
        state.acceptPcm16(testPcmBlock(settings, 0.012, 0.2));
    }
    assert(!state.endpointReached);

    state.acceptPcm16(testPcmBlock(settings, 0.0, 1.1));
    assert(state.endpointReached);
}

unittest
{
    auto settings = testLiveAudioSettings();
    settings.silenceSeconds = 1.0;

    // Speech can begin with the first captured block, before an ambient-noise
    // baseline exists. HFP background above the permissive continuation floor
    // must still become silence and close the utterance.
    auto state = new LiveAudioTurnState(settings);
    state.acceptPcm16(testPcmBlock(settings, 0.025, 0.2));
    state.acceptPcm16(testPcmBlock(settings, 0.008, 1.1));
    assert(state.endpointReached);
}

unittest
{
    auto settings = testLiveAudioSettings();
    settings.silenceSeconds = 6.0;

    auto state = new LiveAudioTurnState(settings);
    state.acceptPcm16(testPcmBlock(settings, 0.025, 0.2));
    state.acceptPcm16(testPcmBlock(settings, 0.0, 2.1));
    assert(!state.endpointReached);

    state.setSilenceSeconds(2.0);
    assert(state.endpointReached);
}

unittest
{
    auto settings = testLiveAudioSettings();
    settings.silenceSeconds = 0.4;

    auto state = new LiveAudioTurnState(settings);
    state.acceptPcm16(testPcmBlock(settings, 0.025, 0.2));
    foreach (_; 0 .. 5) {
        state.acceptPcm16(testPcmBlock(settings, 0.012, 0.2));
    }
    assert(!state.endpointReached);
}

private LiveAudioRuntimeSettings testLiveAudioSettings()
{
    LiveAudioRuntimeSettings settings;
    settings.sampleRate = 16_000;
    settings.channels = 1;
    settings.vadThreshold = 0.010;
    settings.minSpeechSeconds = 0.1;
    settings.silenceSeconds = 1.0;
    settings.maxWaitSeconds = 30.0;
    settings.preRollSeconds = 0.25;
    settings.trailingSilenceKeepSeconds = 1.0;
    settings.trailingSilenceKeepCapSeconds = 2.0;
    settings.maxUtteranceSeconds = 600.0;
    settings.partialTranscriptIntervalSeconds = 0.5;
    settings.partialTranscriptMinAudioSeconds = 0.2;
    settings.previewVoiceGraceSeconds = 2.0;
    settings.previewStablePromptWords = 75;
    settings.draftEndpointStableMinSeconds = 4.0;
    settings.previewBoundaries = LivePreviewBoundarySettings(2.5, 20.0, 5, 35, 50.0, 70.0);
    settings.vadAdaptive = LiveVadAdaptiveSettings(0.02, 0.006, 2.5, 1.35, 0.08, 0.6);
    settings.sessionResume = LiveSessionResumeAudioSettings(0.15, 0.8, 10.0, 0.3, 5.0, 0.2, 0.15);
    settings.finalSelection = LiveFinalSelectionSettings(4, 3, 4, 30.0, 5_000, 0.8, 0.15);
    return settings;
}

private ubyte[] testPcmBlock(LiveAudioRuntimeSettings settings, double normalizedAmplitude, double seconds)
{
    auto sampleCount = cast(size_t) (settings.sampleRate * seconds);
    auto sample = cast(short) (normalizedAmplitude * 32767.0);
    auto bytes = new ubyte[](sampleCount * 2);
    foreach (index; 0 .. sampleCount) {
        auto value = cast(ushort) sample;
        bytes[index * 2] = cast(ubyte) (value & 0xff);
        bytes[index * 2 + 1] = cast(ubyte) ((value >> 8) & 0xff);
    }
    return bytes;
}
