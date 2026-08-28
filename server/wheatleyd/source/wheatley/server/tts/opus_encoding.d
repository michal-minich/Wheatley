module wheatley.server.tts.opus_encoding;

import std.conv : to;
import std.exception : enforce;
import std.file : exists;

import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.process_runner : enforceProcessOk, runLocalProcess;
import wheatley.common.runtime.temp_files : runtimeOwnerRoot;
import wheatley.server.api.core.config : ServerConfig;

enum assistantSpeechMinimumOpusBitrateKbps = 16;
enum assistantSpeechMaximumOpusBitrateKbps = 32;

/// Encodes a synthesized temporary WAV as an Ogg/Opus response. This is output
/// transport only; accepted user audio remains on its independent 32 kbit/s
/// persistence path.
void encodeAssistantSpeechWavAsOpus(
    ServerConfig config,
    string wavPath,
    string opusPath,
    long bitrateKbps,
    double timeoutSeconds,
)
{
    enforce(wavPath.length > 0, "Assistant speech WAV path is required");
    enforce(opusPath.length > 0, "Assistant speech Opus path is required");
    enforceAssistantSpeechOpusBitrate(bitrateKbps);

    auto result = runLocalProcess(
        assistantSpeechOpusCommand(
            resolveBundledExecutable("ffmpeg", "ffmpeg binary", config.appDataRoot),
            wavPath,
            opusPath,
            bitrateKbps,
        ),
        "",
        runtimeOwnerRoot(config.appDataRoot, "wheatleyd"),
        timeoutSeconds,
    );
    enforceProcessOk(result, "assistant speech Opus encode");
    enforce(exists(opusPath), "ffmpeg did not create assistant speech Opus output");
}

string[] assistantSpeechOpusCommand(
    string ffmpeg,
    string wavPath,
    string opusPath,
    long bitrateKbps,
)
{
    enforce(ffmpeg.length > 0, "ffmpeg binary is required");
    enforceAssistantSpeechOpusBitrate(bitrateKbps);
    return [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-i", wavPath,
        "-map", "0:a:0",
        "-vn",
        "-ac", "1",
        "-c:a", "libopus",
        "-b:a", bitrateKbps.to!string ~ "k",
        "-vbr", "on",
        "-compression_level", "10",
        "-application", "audio",
        opusPath,
    ];
}

void enforceAssistantSpeechOpusBitrate(long bitrateKbps)
{
    enforce(
        bitrateKbps >= assistantSpeechMinimumOpusBitrateKbps
            && bitrateKbps <= assistantSpeechMaximumOpusBitrateKbps,
        "Assistant speech Opus bitrate must be between "
            ~ assistantSpeechMinimumOpusBitrateKbps.to!string
            ~ " and " ~ assistantSpeechMaximumOpusBitrateKbps.to!string ~ " kbit/s",
    );
}

unittest
{
    auto command = assistantSpeechOpusCommand("ffmpeg", "input.wav", "output.opus", 24);
    assert(command == [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", "input.wav", "-map", "0:a:0", "-vn", "-ac", "1",
        "-c:a", "libopus", "-b:a", "24k", "-vbr", "on",
        "-compression_level", "10", "-application", "audio", "output.opus",
    ]);
}

unittest
{
    import std.exception : assertThrown;

    assertThrown(assistantSpeechOpusCommand("ffmpeg", "input.wav", "output.opus", 15));
    assertThrown(assistantSpeechOpusCommand("ffmpeg", "input.wav", "output.opus", 33));
}
