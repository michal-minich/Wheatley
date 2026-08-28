module wheatley.server.tts.supertonic;

import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.string : strip;

import wheatley.common.runtime.process_runner : enforceProcessOk, runLocalProcess;

struct SupertonicSynthesisSettings
{
    string python;
    string voice;
    double speed;
    long steps;
    double requestTimeoutSeconds;
}

void runSupertonic(
    SupertonicSynthesisSettings settings,
    string text,
    string language,
    string outputPath,
)
{
    auto spokenText = text.strip;
    enforce(spokenText.length > 0, "Supertonic text is required");
    enforce(settings.python.length > 0, "Supertonic Python runtime is not configured");
    enforce(settings.voice.length > 0, "Supertonic voice is not configured");

    auto result = runLocalProcess(
        [
            settings.python,
            "-c", supertonicPythonScript(),
            outputPath,
            settings.voice,
            language.length ? language : "sk",
            settings.steps.to!string,
            settings.speed.to!string,
        ],
        spokenText,
        "",
        settings.requestTimeoutSeconds,
    );
    enforceProcessOk(result, "Supertonic");
    enforce(
        exists(outputPath),
        result.output.strip.length ? result.output.strip : "Supertonic did not create an audio file",
    );
}

private string supertonicPythonScript()
{
    return
        "import sys\n" ~
        "from supertonic import TTS\n" ~
        "output_path, voice, language, steps, speed = sys.argv[1:]\n" ~
        "text = sys.stdin.read().strip()\n" ~
        "tts = TTS(auto_download=False)\n" ~
        "style = tts.get_voice_style(voice_name=voice)\n" ~
        "wav, _duration = tts.synthesize(\n" ~
        "    text=text,\n" ~
        "    lang=language,\n" ~
        "    voice_style=style,\n" ~
        "    total_steps=int(steps),\n" ~
        "    speed=float(speed),\n" ~
        ")\n" ~
        "tts.save_audio(wav, output_path)\n";
}
