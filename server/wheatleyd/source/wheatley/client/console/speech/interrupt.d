module wheatley.client.console.speech.interrupt;

import core.time : MonoTime, dur;
import std.algorithm.comparison : max;
import std.array : appender;
import std.math : isClose, sqrt;
import std.path : absolutePath, buildNormalizedPath;
import std.stdio : stderr;
import std.string : startsWith, strip, toLower;

import vibe.core.core : Task, runTask;
import vibe.core.path : NativePath;
import vibe.core.process : Config, Process, Redirect, pipeProcess;
import vibe.core.stream : IOMode;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.client.console.audio.pcm_capture : ffmpegPcmCaptureCommand;
import wheatley.client.console.config : ConsoleConfig;
import wheatley.common.runtime.temp_files : removeQuietly, temporaryRuntimeFile;
import wheatley.server.turns.audio.pcm16_wav : writePcm16Wav;

private enum sampleRate = 16_000;
private enum frameSamples = 320;
private enum preRollSamples = 3_200;
private enum maximumCandidateSamples = 64_000;
private enum calibrationMillis = 600;
private enum cooldownMillis = 1_000;
private enum minimumOnsetRms = 0.020;
private enum playbackOnsetMultiplier = 1.35;
private enum maximumPlaybackOnsetRms = 0.040;
private enum settleFrames = 5;
private enum persistenceFrames = 3;
private enum quickReleaseFrames = 4;
private enum endSilenceFrames = 12;

struct ConsoleSpeechInterruptSettings
{
    bool enabled;
    string apiBase;
    string appDataRoot;
    string profileId;
    string ffmpegPath;
    string audioInput;
    string[] phrases;
}

struct ConsoleSpeechInterruptPlayback
{
    bool delegate() active;
    long delegate() activeMillis;
    bool delegate() pause;
    void delegate() resume;
}

ConsoleSpeechInterruptSettings consoleSpeechInterruptSettings(
    ConsoleConfig config,
    string ffmpegPath,
)
{
    return ConsoleSpeechInterruptSettings(
        config.speak && config.speechInterrupt,
        config.apiBase,
        config.appDataRoot,
        config.profileId,
        ffmpegPath,
        config.audioInput,
        config.speechInterruptPhrases,
    );
}

final class ConsoleSpeechInterruptMonitor
{
    private ConsoleSpeechInterruptSettings settings;
    private ConsoleSpeechInterruptPlayback playback;
    private void delegate() onStopPhrase;
    private Task task;
    private Process captureProcess;
    private bool stopRequested;
    private bool joined;

    this(
        ConsoleSpeechInterruptSettings settings,
        ConsoleSpeechInterruptPlayback playback,
        void delegate() onStopPhrase,
    )
    {
        this.settings = settings;
        this.playback = playback;
        this.onStopPhrase = onStopPhrase;
        if (!settings.enabled) return;
        task = runTask(() nothrow {
            try {
                run();
            } catch (Throwable error) {
                if (!stopRequested) {
                    try {
                        stderr.writeln("error> speech interrupt monitor: ", error.msg);
                    } catch (Throwable) {
                    }
                }
                try {
                    playback.resume();
                } catch (Throwable) {
                }
            }
        });
    }

    void stop()
    {
        stopRequested = true;
        playback.resume();
        try {
            if (captureProcess && !captureProcess.exited) captureProcess.kill();
        } catch (Exception) {
        }
    }

    void join()
    {
        if (joined || !task) return;
        task.join();
        joined = true;
    }

    private void run()
    {
        auto pipes = pipeProcess(
            ffmpegPcmCaptureCommand(settings.ffmpegPath, settings.audioInput, true),
            Redirect.stdout,
            null,
            Config.none,
            NativePath(absolutePath(buildNormalizedPath("."))),
        );
        captureProcess = pipes.process;
        scope(exit) {
            stopCaptureProcess(pipes.process);
            captureProcess = Process.init;
        }

        auto client = new ConsoleApiClient(settings.apiBase);
        ubyte[] pendingBytes;
        short[] preRoll;
        double ambientRms = 0.004;
        double playbackReference = 0.0;
        int onsetFrames;
        bool calibrated;
        bool hasCooldown;
        MonoTime cooldownStartedAt;

        while (!stopRequested) {
            auto frame = readPcmFrame(pipes.stdout, pendingBytes);
            if (!frame.length) {
                if (!stopRequested) {
                    throw new Exception("microphone capture ended unexpectedly");
                }
                break;
            }
            auto rms = frameRms(frame);
            appendTail(preRoll, frame, preRollSamples);

            if (!playback.active()) {
                onsetFrames = 0;
                if (!calibrated) ambientRms = movingAverage(ambientRms, rms, 0.04);
                continue;
            }

            if (!calibrated) {
                playbackReference = max(playbackReference * 0.985, rms);
                if (playback.activeMillis() < calibrationMillis) continue;
                calibrated = true;
            }

            if (hasCooldown && MonoTime.currTime - cooldownStartedAt < dur!"msecs"(cooldownMillis)) {
                playbackReference = max(playbackReference * 0.985, rms);
                continue;
            }
            hasCooldown = false;

            auto onsetThreshold = speechOnsetThreshold(ambientRms, playbackReference);
            if (rms >= onsetThreshold) {
                onsetFrames++;
            } else {
                onsetFrames = 0;
                playbackReference = max(playbackReference * 0.985, rms);
            }

            if (onsetFrames < 1 || !playback.pause()) continue;
            auto outcome = inspectPausedSound(client, pipes.stdout, pendingBytes, preRoll, ambientRms);
            if (outcome == PausedSoundOutcome.stop) return;

            onsetFrames = 0;
            playbackReference = max(playbackReference, rms);
            preRoll.length = 0;
            hasCooldown = true;
            cooldownStartedAt = MonoTime.currTime;
        }
    }

    private PausedSoundOutcome inspectPausedSound(Stream)(
        ConsoleApiClient client,
        Stream stream,
        ref ubyte[] pendingBytes,
        const(short)[] preRoll,
        double ambientRms,
    )
    {
        auto candidate = preRoll.dup;
        auto persistenceFloor = max(0.015, ambientRms * 2.5);
        int framesAfterPause;
        int highFrames;
        int lowFrames;
        int silenceFrames;
        bool persistent;

        while (!stopRequested && playback.active()) {
            auto frame = readPcmFrame(stream, pendingBytes);
            if (!frame.length) break;
            if (candidate.length < maximumCandidateSamples) {
                auto available = maximumCandidateSamples - candidate.length;
                candidate ~= frame[0 .. minSize(frame.length, available)];
            }

            framesAfterPause++;
            if (framesAfterPause <= settleFrames) continue;

            auto soundPresent = frameRms(frame) >= persistenceFloor;
            if (!persistent) {
                if (soundPresent) {
                    highFrames++;
                    lowFrames = 0;
                } else {
                    lowFrames++;
                    highFrames = 0;
                }
                if (highFrames >= persistenceFrames) {
                    persistent = true;
                } else if (lowFrames >= quickReleaseFrames) {
                    playback.resume();
                    return PausedSoundOutcome.resume;
                }
                continue;
            }

            if (soundPresent) {
                silenceFrames = 0;
            } else {
                silenceFrames++;
                if (silenceFrames >= endSilenceFrames) break;
            }
        }

        if (stopRequested || !playback.active()) return PausedSoundOutcome.resume;
        if (!persistent) {
            playback.resume();
            return PausedSoundOutcome.resume;
        }

        auto path = temporaryRuntimeFile(
            settings.appDataRoot,
            "console-client",
            "speech-interrupt",
            "candidate",
            ".wav",
        );
        scope(exit) removeQuietly(path);

        try {
            writePcm16Wav(path, candidate, sampleRate, 1);
            auto result = client.transcribeSpeechInterrupt(settings.profileId, path, "en");
            if (stopRequested) {
                playback.resume();
                return PausedSoundOutcome.resume;
            }
            if (matchesStopCommand(result.text, settings.phrases)) {
                if (onStopPhrase !is null) onStopPhrase();
                return PausedSoundOutcome.stop;
            }
        } catch (Exception) {
        }

        playback.resume();
        return PausedSoundOutcome.resume;
    }
}

private enum PausedSoundOutcome
{
    resume,
    stop,
}

private short[] readPcmFrame(Stream)(Stream stream, ref ubyte[] pending)
{
    while (pending.length < frameSamples * 2) {
        ubyte[2_048] buffer;
        auto count = stream.read(buffer[], IOMode.once);
        if (!count) break;
        pending ~= buffer[0 .. count];
    }

    auto byteCount = minSize(pending.length, frameSamples * 2);
    byteCount -= byteCount % 2;
    if (!byteCount) return null;

    auto samples = new short[](byteCount / 2);
    foreach (index; 0 .. samples.length) {
        auto offset = index * 2;
        samples[index] = cast(short) (
            cast(ushort) pending[offset]
            | (cast(ushort) pending[offset + 1] << 8)
        );
    }
    pending = pending[byteCount .. $].dup;
    return samples;
}

private double frameRms(const(short)[] samples)
{
    if (!samples.length) return 0.0;
    double sumSquares = 0.0;
    foreach (sample; samples) {
        auto value = cast(double) sample / 32_768.0;
        sumSquares += value * value;
    }
    return sqrt(sumSquares / samples.length);
}

private double movingAverage(double current, double sample, double weight)
{
    return current * (1.0 - weight) + sample * weight;
}

private double speechOnsetThreshold(double ambientRms, double playbackReference)
{
    // Speaker bleed is useful as a relative baseline, but it must not make a
    // nearby voice impossible to detect. The cap is especially important for
    // Bluetooth headsets whose capture gain and playback leakage vary while a
    // device route settles.
    auto playbackThreshold = playbackReference * playbackOnsetMultiplier;
    if (playbackThreshold > maximumPlaybackOnsetRms) {
        playbackThreshold = maximumPlaybackOnsetRms;
    }
    return max(minimumOnsetRms, max(ambientRms * 2.5, playbackThreshold));
}

private void appendTail(ref short[] target, const(short)[] samples, size_t maximum)
{
    target ~= samples;
    if (target.length > maximum) target = target[$ - maximum .. $].dup;
}

private size_t minSize(size_t left, size_t right)
{
    return left < right ? left : right;
}

private string normalizeCommand(string text)
{
    auto output = appender!string;
    bool separator;
    foreach (ch; text.toLower) {
        auto wordCharacter = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
        if (wordCharacter) {
            if (separator && output.data.length) output.put(' ');
            output.put(ch);
            separator = false;
        } else {
            separator = true;
        }
    }
    return output.data.strip;
}

private bool matchesStopCommand(string text, string[] configuredPhrases)
{
    auto normalized = normalizeCommand(text);
    if (!normalized.length || !configuredPhrases.length) return false;
    while (normalized.length) {
        bool matched;
        foreach (configuredPhrase; configuredPhrases) {
            auto phrase = normalizeCommand(configuredPhrase);
            if (!phrase.length) continue;
            if (normalized == phrase) return true;
            if (!normalized.startsWith(phrase ~ " ")) continue;
            normalized = normalized[phrase.length .. $].strip;
            matched = true;
            break;
        }
        if (!matched) return false;
    }
    return true;
}

unittest
{
    assert(speechOnsetThreshold(0.004, 0.010) == minimumOnsetRms);
    assert(speechOnsetThreshold(0.004, 0.020).isClose(0.027));
    assert(speechOnsetThreshold(0.004, 0.100) == maximumPlaybackOnsetRms);
    assert(speechOnsetThreshold(0.030, 0.020).isClose(0.075));
    auto phrases = ["stop speaking", "stop"];
    assert(matchesStopCommand("Stop.", phrases));
    assert(matchesStopCommand("stop speaking", phrases));
    assert(matchesStopCommand("Stop, stop!", phrases));
    assert(matchesStopCommand("stop speaking, stop speaking", phrases));
    assert(!matchesStopCommand("please stop", phrases));
    assert(!matchesStopCommand("stop after this paragraph", phrases));
    assert(matchesStopCommand("be quiet", ["be quiet"]));
    assert(!matchesStopCommand("stop", ["be quiet"]));
}

private void stopCaptureProcess(Process process)
{
    if (!process || process.exited) return;
    process.kill();
    if (process.wait(dur!"msecs"(500)).isNull) {
        process.forceKill();
        process.wait();
    }
}
