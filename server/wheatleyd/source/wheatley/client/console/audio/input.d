module wheatley.client.console.audio.input;

import std.algorithm.searching : canFind, countUntil, startsWith;
import std.conv : ConvException, to;
import std.string : splitLines, strip;

import wheatley.common.runtime.process_runner : runLocalProcess;

struct ConsoleAudioInputDescription
{
    string selector;
    string label;
    bool fileInput;
    bool resolved;
}

string effectiveConsoleAudioInput(string rawInput)
{
    if (rawInput.length) return rawInput;

    version (OSX) {
        return ":0";
    } else version (linux) {
        return "default";
    } else version (Windows) {
        throw new Exception(
            "Windows console voice requires --audio-input 'audio=DEVICE'. "
            ~ "List devices with: ffmpeg -list_devices true -f dshow -i dummy",
        );
    } else {
        static assert(false, "Unsupported console voice capture platform");
    }
}

ConsoleAudioInputDescription describeConsoleAudioInput(
    string ffmpegPath,
    string rawInput,
    string workDir,
)
{
    auto selector = effectiveConsoleAudioInput(rawInput);
    if (selector.startsWith("file:")) {
        return ConsoleAudioInputDescription(
            selector,
            selector["file:".length .. $].strip,
            true,
            true,
        );
    }

    version (OSX) {
        return describeAvfoundationAudioInput(ffmpegPath, selector, workDir);
    } else version (linux) {
        return ConsoleAudioInputDescription(selector, selector, false, selector.length > 0);
    } else version (Windows) {
        return ConsoleAudioInputDescription(selector, selector, false, selector.length > 0);
    } else {
        static assert(false, "Unsupported console voice capture platform");
    }
}

string audioInputNoticeText(ConsoleAudioInputDescription input)
{
    if (input.fileInput) {
        auto label = input.label.length ? input.label : input.selector;
        return label.length ? "audio input: " ~ label : "";
    }

    auto label = microphoneNoticeLabel(input);
    if (!label.length) return "";
    return "microphone: " ~ label;
}

private string microphoneNoticeLabel(ConsoleAudioInputDescription input)
{
    if (input.label.length) return input.label;

    version (OSX) {
        if (!input.selector.length || input.selector[0] == ':') {
            return "default input";
        }
    }

    return input.selector;
}

private ConsoleAudioInputDescription describeAvfoundationAudioInput(
    string ffmpegPath,
    string selector,
    string workDir,
)
{
    auto index = avfoundationAudioIndex(selector);
    if (index < 0) {
        return ConsoleAudioInputDescription(selector, selector, false, selector.length > 0);
    }

    auto result = runLocalProcess(
        [
            ffmpegPath,
            "-hide_banner",
            "-f", "avfoundation",
            "-list_devices", "true",
            "-i", "",
        ],
        "",
        workDir,
        5.0,
        32 * 1024,
    );
    auto label = avfoundationAudioDeviceLabel(result.output, index);
    return ConsoleAudioInputDescription(selector, label, false, label.length > 0);
}

private int avfoundationAudioIndex(string selector)
{
    auto token = avfoundationAudioSelectorToken(selector).strip;
    if (!token.length) return -1;
    try {
        auto index = token.to!int;
        return index >= 0 ? index : -1;
    } catch (ConvException) {
        return -1;
    }
}

private string avfoundationAudioSelectorToken(string selector)
{
    size_t colon = size_t.max;
    foreach (i, ch; selector) {
        if (ch == ':') colon = i;
    }
    return colon == size_t.max ? selector : selector[colon + 1 .. $];
}

private string avfoundationAudioDeviceLabel(string output, int index)
{
    auto token = "[" ~ index.to!string ~ "] ";
    bool inAudioDevices;
    foreach (line; output.splitLines) {
        auto text = line.strip;
        if (text.canFind("AVFoundation video devices:")) {
            inAudioDevices = false;
            continue;
        }
        if (text.canFind("AVFoundation audio devices:")) {
            inAudioDevices = true;
            continue;
        }
        if (!inAudioDevices) continue;

        auto position = text.countUntil(token);
        if (position >= 0) {
            return text[position + token.length .. $].strip;
        }
    }
    return "";
}
