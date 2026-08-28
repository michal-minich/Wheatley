module wheatley.server.turns.audio.live_audio_decoder;

import core.time : MonoTime, dur;

import std.exception : enforce;
import std.path : absolutePath, buildNormalizedPath;

import vibe.core.core : Task, runTask, sleep;
import vibe.core.path : NativePath;
import vibe.core.process : Config, Redirect;
import vibe.core.stream : IOMode;

import wheatley.server.api.core.config : ServerConfig;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.process_runner : LocalProcessPipes, pipeLocalProcess;
import wheatley.common.runtime.temp_files : runtimeOwnerRoot;
import wheatley.common.api.live_audio : LiveAudioFormat;

struct LiveAudioDecodeStats
{
    long decodeMs;
}

interface LiveAudioDecoder
{
    ubyte[] accept(const(ubyte)[] payload);
    ubyte[] drain();
    ubyte[] finish();
    LiveAudioDecodeStats stats();
    void close();
}

LiveAudioDecoder createLiveAudioDecoder(ServerConfig config, LiveAudioFormat format)
{
    if (format.format == "pcm_s16le") {
        return new PcmS16LiveAudioDecoder;
    }

    if (format.format == "opus") {
        enforce(
            format.container == "ogg-opus",
            "Live Opus currently supports container ogg-opus only",
        );
        return new FfmpegOggOpusLiveAudioDecoder(
            resolveBundledExecutable("ffmpeg", "ffmpeg binary", config.appDataRoot),
            runtimeOwnerRoot(config.appDataRoot, "wheatleyd"),
        );
    }

    throw new Exception("Unsupported live audio format: " ~ format.format);
}

private final class PcmS16LiveAudioDecoder : LiveAudioDecoder
{
    ubyte[] accept(const(ubyte)[] payload)
    {
        return payload.dup;
    }

    ubyte[] drain()
    {
        return [];
    }

    ubyte[] finish()
    {
        return [];
    }

    LiveAudioDecodeStats stats()
    {
        return LiveAudioDecodeStats.init;
    }

    void close()
    {
    }
}

private final class FfmpegOggOpusLiveAudioDecoder : LiveAudioDecoder
{
    private LocalProcessPipes pipes;
    private Task stderrTask;
    private bool stdinClosed;
    private bool closed;
    private long decodeMs;
    private string stderrText;

    this(string ffmpegPath, string workingRoot)
    {
        pipes = pipeLocalProcess(
            ffmpegDecodeCommand(ffmpegPath),
            Redirect.stdin | Redirect.stdout | Redirect.stderr,
            null,
            Config.none,
            NativePath(absolutePath(buildNormalizedPath(workingRoot))),
        );
        stderrTask = runTask(() nothrow {
            try {
                drainStderr();
            } catch (Throwable) {
            }
        });
    }

    ubyte[] accept(const(ubyte)[] payload)
    {
        enforce(!closed, "Live audio decoder is closed");
        auto started = MonoTime.currTime;
        if (payload.length) {
            pipes.stdin.write(payload);
        }
        auto output = drainDecodedImmediate();
        decodeMs += elapsedMs(started);
        return output;
    }

    ubyte[] drain()
    {
        if (closed) return [];
        auto started = MonoTime.currTime;
        auto output = drainDecodedImmediate();
        decodeMs += elapsedMs(started);
        return output;
    }

    ubyte[] finish()
    {
        if (closed) return [];
        auto started = MonoTime.currTime;
        closeStdin();

        ubyte[] output;
        auto waitStarted = MonoTime.currTime;
        while (pipes.process && !pipes.process.exited) {
            output ~= drainDecodedImmediate();
            if (MonoTime.currTime - waitStarted >= dur!"msecs"(500)) break;
            sleep(dur!"msecs"(10));
        }
        output ~= drainDecodedImmediate();
        decodeMs += elapsedMs(started);
        return output;
    }

    LiveAudioDecodeStats stats()
    {
        return LiveAudioDecodeStats(decodeMs);
    }

    void close()
    {
        if (closed) return;
        closed = true;
        closeStdin();
        if (pipes.process && !pipes.process.exited) {
            pipes.process.kill();
            if (pipes.process.wait(dur!"msecs"(500)).isNull) {
                pipes.process.forceKill();
                pipes.process.wait();
            }
        }
        if (stderrTask.running) stderrTask.join();
    }

    private void closeStdin()
    {
        if (stdinClosed) return;
        try {
            pipes.stdin.close();
        } catch (Exception) {
        }
        stdinClosed = true;
    }

    private ubyte[] drainDecodedImmediate()
    {
        ubyte[] output;
        ubyte[4096] buffer;
        while (pipes.stdout.dataAvailableForRead) {
            size_t chunk;
            try {
                chunk = pipes.stdout.read(buffer[], IOMode.once);
            } catch (Exception error) {
                if (stderrText.length) {
                    throw new Exception("Live Opus decode failed: " ~ stderrText);
                }
                throw error;
            }
            if (!chunk) break;
            output ~= buffer[0 .. chunk];
        }
        return output;
    }

    private void drainStderr()
    {
        ubyte[1024] buffer;
        while (true) {
            size_t chunk;
            try {
                chunk = pipes.stderr.read(buffer[], IOMode.once);
            } catch (Exception) {
                break;
            }
            if (!chunk) break;
            if (stderrText.length < 4096) {
                auto remaining = 4096 - stderrText.length;
                auto take = chunk < remaining ? chunk : remaining;
                stderrText ~= cast(string) buffer[0 .. take].dup;
            }
        }
    }
}

private string[] ffmpegDecodeCommand(string ffmpegPath)
{
    return [
        ffmpegPath,
        "-hide_banner",
        "-loglevel", "error",
        "-f", "ogg",
        "-i", "pipe:0",
        "-ac", "1",
        "-ar", "16000",
        "-f", "s16le",
        "pipe:1",
    ];
}

private long elapsedMs(MonoTime started)
{
    return cast(long) (MonoTime.currTime - started).total!"msecs";
}
