module wheatley.client.console.audio.chimes;

import std.exception : enforce;
import std.file : exists, read;
import std.path : baseName, buildPath;
import std.string : strip;

import wheatley.client.console.speech.playback : playAudioFile;
import wheatley.common.runtime.temp_files : removeQuietly, temporaryRuntimeFile;
import wheatley.server.turns.audio.pcm16_wav : writePcm16Wav;

struct ConsoleListeningChimes
{
    string appDataRoot;
    string resourcesRoot;
    string playbackCommand;
}

void playListeningStartChime(ConsoleListeningChimes chimes)
{
    playListeningChime(chimes, "listening-start.wav");
}

void playListeningStopChime(ConsoleListeningChimes chimes)
{
    playListeningChime(chimes, "listening-stop.wav");
}

void playCaptureChime(ConsoleListeningChimes chimes) nothrow
{
    playListeningChime(chimes, "capture.wav");
}

private void playListeningChime(ConsoleListeningChimes chimes, string fileName) nothrow
{
    try {
        if (!chimes.resourcesRoot.length || !chimes.playbackCommand.strip.length) return;
        auto path = buildPath(
            chimes.resourcesRoot,
            "assets",
            "audio",
            "chimes",
            fileName,
        );
        if (!exists(path)) return;
        auto playbackPath = paddedChimePlaybackPath(
            chimes.appDataRoot,
            path,
            leadingSilenceSeconds(fileName),
        );
        scope(exit) {
            if (playbackPath != path) removeQuietly(playbackPath);
        }
        playAudioFile(chimes.playbackCommand, playbackPath, "listening chime playback");
    } catch (Throwable) {
    }
}

private double leadingSilenceSeconds(string fileName)
{
    if (fileName == "capture.wav") return 0.0;
    return fileName == "listening-start.wav" ? 0.5 : 0.12;
}

private string paddedChimePlaybackPath(string appDataRoot, string path, double leadingSeconds)
{
    try {
        auto chime = readPcm16Wav(path);
        auto leadingSamples = silenceSampleCount(chime, leadingSeconds);
        auto trailingSamples = silenceSampleCount(
            chime,
            fileNameTrailingSilenceSeconds(baseName(path)),
        );
        auto samples = new short[](leadingSamples + chime.samples.length + trailingSamples);
        samples[leadingSamples .. leadingSamples + chime.samples.length] = chime.samples[];

        auto outputPath = temporaryRuntimeFile(appDataRoot, "console-client", "chimes", baseName(path), ".wav");
        writePcm16Wav(outputPath, samples, chime.sampleRate, chime.channels);
        return outputPath;
    } catch (Exception) {
        return path;
    }
}

private double fileNameTrailingSilenceSeconds(string fileName)
{
    if (fileName == "capture.wav") return 0.0;
    return fileName == "listening-start.wav" ? 0.0 : 0.24;
}

private struct Pcm16Wav
{
    int sampleRate;
    ushort channels;
    short[] samples;
}

private Pcm16Wav readPcm16Wav(string path)
{
    auto bytes = cast(ubyte[]) read(path);
    enforce(bytes.length >= 12, "WAV is too small");
    enforce(asciiAt(bytes, 0, "RIFF") && asciiAt(bytes, 8, "WAVE"), "Unsupported WAV container");

    bool foundFormat;
    bool foundData;
    ushort audioFormat;
    ushort channels;
    uint sampleRate;
    ushort bitsPerSample;
    size_t dataOffset;
    size_t dataSize;

    size_t offset = 12;
    while (offset + 8 <= bytes.length) {
        auto chunkSize = cast(size_t) readLe32(bytes, offset + 4);
        auto chunkStart = offset + 8;
        auto chunkEnd = chunkStart + chunkSize;
        enforce(chunkEnd <= bytes.length, "WAV chunk extends beyond file");

        if (asciiAt(bytes, offset, "fmt ")) {
            enforce(chunkSize >= 16, "WAV fmt chunk is too small");
            audioFormat = readLe16(bytes, chunkStart);
            channels = readLe16(bytes, chunkStart + 2);
            sampleRate = readLe32(bytes, chunkStart + 4);
            bitsPerSample = readLe16(bytes, chunkStart + 14);
            foundFormat = true;
        } else if (asciiAt(bytes, offset, "data")) {
            dataOffset = chunkStart;
            dataSize = chunkSize;
            foundData = true;
        }

        offset = chunkEnd + (chunkSize & 1);
    }

    enforce(foundFormat && foundData, "WAV is missing fmt or data chunk");
    enforce(audioFormat == 1 && bitsPerSample == 16, "Only PCM16 WAV chimes are supported");
    enforce(channels > 0 && sampleRate > 0, "WAV sample format is invalid");
    enforce((dataSize % 2) == 0, "WAV data is not 16-bit aligned");

    auto samples = new short[](dataSize / 2);
    foreach (i; 0 .. samples.length) {
        samples[i] = cast(short) readLe16(bytes, dataOffset + i * 2);
    }
    return Pcm16Wav(cast(int) sampleRate, channels, samples);
}

private size_t silenceSampleCount(Pcm16Wav chime, double seconds)
{
    return cast(size_t) (seconds * chime.sampleRate * chime.channels);
}

private bool asciiAt(const(ubyte)[] bytes, size_t offset, string text)
{
    if (offset + text.length > bytes.length) return false;
    foreach (i, ch; text) {
        if (bytes[offset + i] != cast(ubyte) ch) return false;
    }
    return true;
}

private ushort readLe16(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 2 <= bytes.length, "WAV ended while reading uint16");
    return cast(ushort) (bytes[offset] | (bytes[offset + 1] << 8));
}

private uint readLe32(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 4 <= bytes.length, "WAV ended while reading uint32");
    return cast(uint) (
        bytes[offset]
        | (bytes[offset + 1] << 8)
        | (bytes[offset + 2] << 16)
        | (bytes[offset + 3] << 24)
    );
}
