module wheatley.client.console.audio.pcm_capture;

import std.exception : enforce;
import std.string : startsWith, strip;

import wheatley.client.console.audio.input : effectiveConsoleAudioInput;

string[] ffmpegPcmCaptureCommand(
    string ffmpegPath,
    string rawAudioInput,
    bool loopFile = false,
)
{
    auto selectedInput = effectiveConsoleAudioInput(rawAudioInput);
    if (selectedInput.startsWith("file:")) {
        auto input = selectedInput["file:".length .. $];
        enforce(input.strip.length > 0, "file: audio input requires a path");
        auto inputArguments = loopFile
            ? ["-stream_loop", "-1", "-re", "-i", input]
            : ["-re", "-i", input];
        return [
            ffmpegPath,
            "-hide_banner",
            "-loglevel", "error",
        ] ~ inputArguments ~ [
            "-ac", "1",
            "-ar", "16000",
            "-f", "s16le",
            "-",
        ];
    }

    version (OSX) {
        return [
            ffmpegPath,
            "-hide_banner",
            "-loglevel", "error",
            "-f", "avfoundation",
            "-i", selectedInput,
            "-ac", "1",
            "-ar", "16000",
            "-f", "s16le",
            "-",
        ];
    } else version (linux) {
        return [
            ffmpegPath,
            "-hide_banner",
            "-loglevel", "error",
            "-f", "pulse",
            "-i", selectedInput,
            "-ac", "1",
            "-ar", "16000",
            "-f", "s16le",
            "-",
        ];
    } else version (Windows) {
        return [
            ffmpegPath,
            "-hide_banner",
            "-loglevel", "error",
            "-f", "dshow",
            "-i", selectedInput,
            "-ac", "1",
            "-ar", "16000",
            "-f", "s16le",
            "-",
        ];
    } else {
        static assert(false, "Unsupported console voice capture platform");
    }
}
