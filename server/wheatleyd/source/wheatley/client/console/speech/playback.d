module wheatley.client.console.speech.playback;

import core.sync.mutex : Mutex;
import core.time : MonoTime, dur;
import std.conv : to;
import std.exception : enforce;
import std.file : read;
import std.path : baseName, buildPath;
import std.string : strip, toLower;
import std.uuid : randomUUID;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.common.api.tts : TtsResponse;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.process_runner : enforceProcessOk, runLocalProcess;
import wheatley.common.runtime.temp_files : removeQuietly, temporaryRuntimeFile;

import vibe.core.process : Process, spawnProcess;

struct PreparedSpeechFile
{
    string audioPath;
    string model;
    long prepareMs;
    double audioSeconds;
}

final class ConsoleSpeechPlayback
{
    private Mutex lock;
    private Process activeProcess;
    private MonoTime activeStartedAt;
    private bool paused;
    private bool shutdown;

    this()
    {
        lock = new Mutex();
    }

    void play(
        string playbackCommand,
        string audioPath,
        void delegate() nothrow onStarted = null,
    )
    {
        enforce(playbackCommand.strip.length > 0, "Streaming playback command is not configured");

        lock.lock();
        auto alreadyShutdown = shutdown;
        lock.unlock();
        enforce(!alreadyShutdown, "Streaming playback was stopped before audio could start");

        auto process = spawnProcess(playbackArguments(playbackCommand, audioPath));
        lock.lock();
        if (shutdown) {
            lock.unlock();
            requestStop(process);
            waitForPlaybackProcess(process);
            throw new Exception("Streaming playback was stopped while audio was starting");
        }
        activeProcess = process;
        activeStartedAt = MonoTime.currTime;
        paused = false;
        lock.unlock();
        if (onStarted !is null) onStarted();

        auto exitCode = waitForPlaybackProcess(process);
        lock.lock();
        if (activeProcess && activeProcess.pid == process.pid) {
            activeProcess = Process.init;
            paused = false;
        }
        auto stopped = shutdown;
        lock.unlock();

        enforce(stopped || exitCode == 0, "TTS playback exited with status " ~ exitCode.to!string);
    }

    bool active()
    {
        lock.lock();
        scope(exit) lock.unlock();
        return activeProcess && !activeProcess.exited;
    }

    long activeMillis()
    {
        lock.lock();
        scope(exit) lock.unlock();
        if (!activeProcess || activeProcess.exited) return 0;
        return cast(long) (MonoTime.currTime - activeStartedAt).total!"msecs";
    }

    bool pause()
    {
        lock.lock();
        scope(exit) lock.unlock();
        if (!activeProcess || activeProcess.exited || paused) return false;
        version (Posix) {
            import core.sys.posix.signal : SIGURG;
            activeProcess.kill(SIGURG);
            paused = true;
            return true;
        } else {
            return false;
        }
    }

    void resume()
    {
        lock.lock();
        scope(exit) lock.unlock();
        if (!activeProcess || activeProcess.exited || !paused) return;
        version (Posix) {
            import core.sys.posix.signal : SIGCONT;
            activeProcess.kill(SIGCONT);
            paused = false;
        }
    }

    void stop()
    {
        lock.lock();
        shutdown = true;
        auto process = activeProcess;
        activeProcess = Process.init;
        paused = false;
        lock.unlock();
        requestStop(process);
    }
}


unittest
{
    import std.file : exists, tempDir;
    import std.path : buildPath;

    auto marker = buildPath(tempDir(), "wheatley-playback-launch-" ~ randomUUID().toString());
    scope(exit) removeQuietly(marker);
    auto playback = new ConsoleSpeechPlayback;
    bool started;
    playback.play("/usr/bin/touch", marker, () nothrow { started = true; });
    assert(started);
    assert(exists(marker));
}

string prepareSpeechFile(
    ConsoleApiClient client,
    string profileId,
    string text,
    string language,
    string appDataRoot,
)
{
    return prepareSpeechFileWithMetrics(client, profileId, text, language, appDataRoot).audioPath;
}

PreparedSpeechFile prepareSpeechFileWithMetrics(
    ConsoleApiClient client,
    string profileId,
    string text,
    string language,
    string appDataRoot,
)
{
    string compressedPath;
    string playbackPath;
    try {
        auto started = MonoTime.currTime;
        auto result = client.synthesizeSpeech(profileId, text, language);
        compressedPath = temporaryCompressedSpeechPath(appDataRoot, result.mediaType);
        playbackPath = temporaryPlaybackSpeechPath(appDataRoot);
        client.downloadGeneratedAudio(result, compressedPath);
        decodeSpeechForPlayback(appDataRoot, compressedPath, playbackPath);
        removeQuietly(compressedPath);
        return PreparedSpeechFile(
            playbackPath,
            ttsModelName(result),
            cast(long) (MonoTime.currTime - started).total!"msecs",
            speechFileDurationSeconds(playbackPath),
        );
    } catch (Exception error) {
        removeQuietly(compressedPath);
        removeQuietly(playbackPath);
        throw error;
    }
}

void playAudioFile(string playbackCommand, string audioPath, string label)
{
    enforce(playbackCommand.strip.length > 0, label ~ " command is not configured");
    auto playback = runLocalProcess(
        playbackArguments(playbackCommand, audioPath),
        "",
        "",
        180.0,
        16 * 1024,
    );
    enforceProcessOk(playback, label);
}

void playSpeechFile(string playbackCommand, string audioPath)
{
    playAudioFile(playbackCommand, audioPath, "TTS playback");
}

private void requestStop(Process process)
{
    if (process && !process.exited) process.kill();
}

private string[] playbackArguments(string command, string audioPath)
{
    auto name = baseName(command).toLower;
    if (name == "ffplay" || name == "ffplay.exe") {
        return [
            command,
            "-hide_banner",
            "-loglevel", "error",
            "-nodisp",
            "-autoexit",
            audioPath,
        ];
    }
    return [command, audioPath];
}

private int waitForPlaybackProcess(Process process)
{
    auto result = process.wait(dur!"seconds"(180));
    if (!result.isNull) return result.get;
    process.forceKill();
    process.wait();
    throw new Exception("TTS playback timed out");
}

private string temporaryCompressedSpeechPath(string appDataRoot, string mediaType)
{
    enforce(mediaType == "audio/ogg", "Unsupported generated speech media type: " ~ mediaType);
    return temporaryRuntimeFile(appDataRoot, "console-client", "tts-playback", "speech", ".opus");
}

private string temporaryPlaybackSpeechPath(string appDataRoot)
{
    return temporaryRuntimeFile(appDataRoot, "console-client", "tts-playback", "speech", ".wav");
}

private void decodeSpeechForPlayback(string appDataRoot, string inputPath, string outputPath)
{
    auto ffmpeg = resolveBundledExecutable("ffmpeg", "ffmpeg binary", appDataRoot);
    auto decoded = runLocalProcess(
        speechDecodeCommand(ffmpeg, inputPath, outputPath),
        "",
        "",
        120.0,
        16 * 1024,
    );
    enforceProcessOk(decoded, "Generated speech decode");
}

private string[] speechDecodeCommand(string ffmpeg, string inputPath, string outputPath)
{
    return [
        ffmpeg,
        "-hide_banner",
        "-loglevel", "error",
        "-nostdin",
        "-y",
        "-i", inputPath,
        "-map", "0:a:0",
        "-vn",
        "-ac", "1",
        "-c:a", "pcm_s16le",
        "-f", "wav",
        outputPath,
    ];
}

unittest
{
    assert(playbackArguments("afplay", "speech.wav") == ["afplay", "speech.wav"]);
    assert(playbackArguments("ffplay", "speech.wav") == [
        "ffplay", "-hide_banner", "-loglevel", "error", "-nodisp", "-autoexit", "speech.wav",
    ]);
    assert(speechDecodeCommand("ffmpeg", "speech.opus", "speech.wav") == [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-i", "speech.opus", "-map", "0:a:0", "-vn", "-ac", "1",
        "-c:a", "pcm_s16le", "-f", "wav", "speech.wav",
    ]);
}

private string ttsModelName(TtsResponse result)
{
    auto provider = result.provider.strip;
    auto voice = result.voice.strip;
    if (provider.length && voice.length) return provider ~ ":" ~ voice;
    if (provider.length) return provider;
    return "";
}

double speechFileDurationSeconds(string path)
{
    try {
        auto bytes = cast(ubyte[]) read(path);
        if (bytes.length < 44) return 0.0;
        if (!asciiAt(bytes, 0, "RIFF") || !asciiAt(bytes, 8, "WAVE")) return 0.0;

        size_t offset = 12;
        ushort channels;
        uint sampleRate;
        ushort bitsPerSample;
        uint dataBytes;
        while (offset + 8 <= bytes.length) {
            auto size = readLeUint(bytes[offset + 4 .. offset + 8]);
            auto payloadStart = offset + 8;
            auto payloadEnd = payloadStart + cast(size_t) size;
            if (payloadEnd > bytes.length) break;
            if (asciiAt(bytes, offset, "fmt ") && size >= 16) {
                channels = readLeUshort(bytes[payloadStart + 2 .. payloadStart + 4]);
                sampleRate = readLeUint(bytes[payloadStart + 4 .. payloadStart + 8]);
                bitsPerSample = readLeUshort(bytes[payloadStart + 14 .. payloadStart + 16]);
            } else if (asciiAt(bytes, offset, "data")) {
                dataBytes = size;
            }
            offset = payloadEnd + (size % 2);
        }

        auto bytesPerSample = bitsPerSample / 8;
        if (!channels || !sampleRate || !bytesPerSample || !dataBytes) return 0.0;
        return cast(double) dataBytes / cast(double) (sampleRate * channels * bytesPerSample);
    } catch (Exception) {
        return 0.0;
    }
}

unittest
{
    import std.file : tempDir, write;
    import std.math : isClose;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto path = buildPath(tempDir(), "wheatley-wav-duration-" ~ randomUUID().toString() ~ ".wav");
    scope(exit) removeQuietly(path);

    ubyte[] bytes;
    bytes ~= cast(ubyte[]) "RIFF";
    appendLeUint(bytes, 36 + 32);
    bytes ~= cast(ubyte[]) "WAVE";
    bytes ~= cast(ubyte[]) "fmt ";
    appendLeUint(bytes, 16);
    appendLeUshort(bytes, 1);
    appendLeUshort(bytes, 1);
    appendLeUint(bytes, 16_000);
    appendLeUint(bytes, 32_000);
    appendLeUshort(bytes, 2);
    appendLeUshort(bytes, 16);
    bytes ~= cast(ubyte[]) "data";
    appendLeUint(bytes, 32);
    bytes.length = bytes.length + 32;
    write(path, bytes);

    assert(speechFileDurationSeconds(path).isClose(0.001));
}

private bool asciiAt(const(ubyte)[] bytes, size_t offset, string value)
{
    if (offset + value.length > bytes.length) return false;
    foreach (index, ch; value) {
        if (bytes[offset + index] != cast(ubyte) ch) return false;
    }
    return true;
}

private void appendLeUshort(ref ubyte[] bytes, ushort value)
{
    bytes ~= cast(ubyte) (value & 0xff);
    bytes ~= cast(ubyte) ((value >> 8) & 0xff);
}

private void appendLeUint(ref ubyte[] bytes, uint value)
{
    bytes ~= cast(ubyte) (value & 0xff);
    bytes ~= cast(ubyte) ((value >> 8) & 0xff);
    bytes ~= cast(ubyte) ((value >> 16) & 0xff);
    bytes ~= cast(ubyte) ((value >> 24) & 0xff);
}

private ushort readLeUshort(const(ubyte)[] bytes)
{
    return cast(ushort) (
        cast(ushort) bytes[0]
        | (cast(ushort) bytes[1] << 8)
    );
}

private uint readLeUint(const(ubyte)[] bytes)
{
    return cast(uint) (
        cast(uint) bytes[0]
        | (cast(uint) bytes[1] << 8)
        | (cast(uint) bytes[2] << 16)
        | (cast(uint) bytes[3] << 24)
    );
}
