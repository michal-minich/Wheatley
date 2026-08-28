module wheatley.server.tts.piper;

import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.path : absolutePath, buildNormalizedPath;
import std.regex : regex, replaceAll;
import std.string : strip;

import wheatley.common.runtime.process_runner : enforceProcessOk, runLocalProcess;
public import wheatley.server.tts.piper_types : PiperSynthesisSettings;

string applyPiperPronunciationReplacements(string text, PiperSynthesisSettings settings)
{
    foreach (pattern, replacement; settings.pronunciationReplacements) {
        text = replaceAll(text, regex(pattern), replacement);
    }
    return text;
}

void runPiper(PiperSynthesisSettings settings, string text, string outputPath)
{
    string[] command = [
        settings.binary,
        "--model", settings.model,
        "--output_file", outputPath,
        "--length-scale", settings.lengthScale.to!string,
        "--noise-scale", settings.noiseScale.to!string,
        "--noise-w-scale", settings.noiseWScale.to!string,
        "--sentence-silence", settings.sentenceSilence.to!string,
        "--volume", settings.volume.to!string,
    ];
    if (settings.config.length) {
        command ~= ["--config", settings.config];
    }
    if (settings.hasSpeaker) {
        command ~= ["--speaker", settings.speaker.to!string];
    }

    auto result = runLocalProcess(
        command,
        text,
        absolutePath(buildNormalizedPath(".")),
        settings.requestTimeoutSeconds,
    );
    enforceProcessOk(result, "Piper");
    enforce(
        exists(outputPath),
        result.output.strip.length ? result.output.strip : "Piper did not create an audio file",
    );
}
