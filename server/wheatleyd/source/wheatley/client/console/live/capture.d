module wheatley.client.console.live.capture;

import core.time : MonoTime, dur;
import std.algorithm.comparison : max;
import std.conv : to;
import std.exception : enforce;
import std.path : absolutePath, buildNormalizedPath;
import std.string : startsWith, strip;

import vibe.core.core : Task, runTask, sleep;
import vibe.core.path : NativePath;
import vibe.core.process : Config, Redirect, pipeProcess;
import vibe.core.stream : IOMode;
import vibe.http.websockets : WebSocket, WebSocketCloseReason;

import wheatley.client.console.audio.input : effectiveConsoleAudioInput;
import wheatley.client.console.audio.pcm_capture : ffmpegPcmCaptureCommand;
import wheatley.client.console.live.socket : closeSocketQuietly;
import wheatley.client.console.live.types :
    ConsoleLiveAudioClientMetrics,
    ConsoleLiveAudioRequest;

final class ConsoleAudioCapture
{
    private AudioCaptureState state;
    private Task task;
    private bool joined;

    this(ConsoleLiveAudioRequest request, WebSocket ws)
    {
        state = new AudioCaptureState;
        state.configure(request);
        task = runTask(() nothrow {
            try {
                streamFfmpegAudio(request, ws, state);
            } catch (Exception error) {
                state.markFailed(error.msg);
                closeSocketQuietly(ws, WebSocketCloseReason.internalError, "Audio capture failed");
            } catch (Throwable error) {
                state.markFailed(error.msg);
            }
        });
    }

    void stop()
    {
        state.stop = true;
    }

    void join()
    {
        if (joined) return;
        task.join();
        joined = true;
    }

    @property string error()
    {
        return state.error;
    }

    ConsoleLiveAudioClientMetrics metrics()
    {
        return state.metrics;
    }
}

private enum pcmBytesPerSecond = 32_000; // Mono 16 kHz PCM16.

private final class AudioCaptureState
{
    bool stop;
    string error;
    ulong sentBytes;
    ulong framesSent;
    bool hasFirstSend;
    MonoTime firstSendMono;
    MonoTime lastSendMono;
    long maxSendBacklogMs;
    string clientAudioFormat;
    ConsoleLiveAudioClientMetrics metrics()
    {
        auto sendMs = sendDurationMs();
        ConsoleLiveAudioClientMetrics result;
        result.clientAudioFormat = clientAudioFormat.length ? clientAudioFormat : "pcm_s16le";
        result.clientAudioBytes = result.clientAudioFormat == "pcm_s16le" ? sentBytes : 0;
        result.clientSentBytes = sentBytes;
        result.clientFramesSent = framesSent;
        result.clientEncodeMs = result.clientAudioFormat == "opus" ? sendMs : 0;
        result.clientMaxSendBacklogMs = maxSendBacklogMs;
        result.clientSendMs = sendMs;
        return result;
    }

    void configure(ConsoleLiveAudioRequest request)
    {
        clientAudioFormat = request.start.audio.format == "opus" ? "opus" : "pcm_s16le";
    }

    void recordSent(size_t byteCount)
    {
        auto now = MonoTime.currTime;
        if (!hasFirstSend) {
            firstSendMono = now;
            hasFirstSend = true;
        }
        lastSendMono = now;
        sentBytes += byteCount;
        framesSent++;
    }

    void markFailed(string message) nothrow
    {
        error = message;
    }

    void throttleUpload(int kbps)
    {
        if (kbps <= 0 || !hasFirstSend) return;
        auto now = MonoTime.currTime;
        auto actualMs = cast(long) (now - firstSendMono).total!"msecs";
        auto expectedMs = cast(long) ((cast(double) sentBytes * 8.0) / cast(double) kbps);
        if (expectedMs <= actualMs) {
            lastSendMono = now;
            return;
        }

        auto delayMs = expectedMs - actualMs;
        maxSendBacklogMs = max(maxSendBacklogMs, delayMs);
        sleep(dur!"msecs"(delayMs));
        lastSendMono = MonoTime.currTime;
    }

    long sendDurationMs()
    {
        if (!hasFirstSend) return 0;
        return cast(long) (lastSendMono - firstSendMono).total!"msecs";
    }
}

private void streamFfmpegAudio(
    ConsoleLiveAudioRequest request,
    WebSocket ws,
    AudioCaptureState state,
)
{
    auto command = ffmpegCaptureCommand(request);
    auto pipes = pipeProcess(
        command,
        Redirect.stdout,
        null,
        Config.none,
        NativePath(absolutePath(buildNormalizedPath("."))),
    );
    scope(exit) {
        state.stop = true;
        if (pipes.process && !pipes.process.exited) {
            pipes.process.kill();
            if (pipes.process.wait(dur!"msecs"(500)).isNull) {
                pipes.process.forceKill();
                pipes.process.wait();
            }
        }
    }

    auto buffer = new ubyte[](captureChunkBytes(request));
    while (!state.stop && ws.connected) {
        size_t chunk;
        try {
            chunk = pipes.stdout.read(buffer[], IOMode.once);
        } catch (Exception) {
            break;
        }
        if (!chunk) break;
        if (!state.stop && ws.connected) {
            ws.send(buffer[0 .. chunk].dup);
            state.recordSent(chunk);
            state.throttleUpload(request.simulateUploadKbps);
        }
    }
}

private size_t pcmChunkBytes(int frameMs)
{
    enforce(frameMs > 0, "PCM frame duration must be positive");
    return cast(size_t) ((cast(long) pcmBytesPerSecond * frameMs) / 1_000);
}

private size_t captureChunkBytes(ConsoleLiveAudioRequest request)
{
    if (request.start.audio.format == "opus") return 512;
    return pcmChunkBytes(request.start.audio.frameMs);
}

private string[] ffmpegCaptureCommand(ConsoleLiveAudioRequest request)
{
    if (request.start.audio.format == "opus") return ffmpegOpusCaptureCommand(request);
    enforce(request.start.audio.format == "pcm_s16le", "audio format must be pcm_s16le or opus");
    return ffmpegPcmCaptureCommand(request.ffmpegPath, request.ffmpegAudioInput);
}

private string[] ffmpegOpusCaptureCommand(ConsoleLiveAudioRequest request)
{
    enforce(request.start.audio.container == "ogg-opus", "Console live Opus currently supports ogg-opus only");
    auto selectedInput = effectiveConsoleAudioInput(request.ffmpegAudioInput);
    auto outputArgs = [
        "-ac", "1",
        "-ar", "16000",
        "-c:a", "libopus",
        "-b:a", request.start.audio.bitrate.to!string,
        "-application", request.start.audio.application,
        "-compression_level", request.start.audio.complexity.to!string,
        "-frame_duration", request.start.audio.frameMs.to!string,
        "-f", "ogg",
        "-page_duration", (request.start.audio.frameMs * 1_000).to!string,
        "-flush_packets", "1",
        "-",
    ];

    if (selectedInput.startsWith("file:")) {
        auto input = selectedInput["file:".length .. $];
        enforce(input.strip.length > 0, "file: audio input requires a path");
        return [
            request.ffmpegPath,
            "-hide_banner",
            "-loglevel", "error",
            "-re",
            "-i", input,
        ] ~ outputArgs;
    }

    version (OSX) {
        return [
            request.ffmpegPath,
            "-hide_banner",
            "-loglevel", "error",
            "-f", "avfoundation",
            "-i", selectedInput,
        ] ~ outputArgs;
    } else version (linux) {
        return [
            request.ffmpegPath,
            "-hide_banner",
            "-loglevel", "error",
            "-f", "pulse",
            "-i", selectedInput,
        ] ~ outputArgs;
    } else version (Windows) {
        return [
            request.ffmpegPath,
            "-hide_banner",
            "-loglevel", "error",
            "-f", "dshow",
            "-i", selectedInput,
        ] ~ outputArgs;
    } else {
        static assert(false, "Unsupported console voice capture platform");
    }
}
