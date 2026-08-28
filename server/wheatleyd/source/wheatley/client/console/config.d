module wheatley.client.console.config;

import std.exception : enforce;
import std.conv : to;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : strip;

import wheatley.common.api.live_audio : LiveAudioFormat, validateLiveAudioFormat;
import wheatley.common.api.reasoning : ReasoningMode;
import wheatley.common.choice : requireChoice;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.run_profile : loadRunProfile, runProfilePath, runProfileValue;
import wheatley.common.safe_token : enforceSafeToken;

enum ConsoleCommand
{
    help,
    chat,
    voice,
    clientTools,
}

struct ConsoleConfig
{
    string apiBase;
    string appDataRoot;
    string resourcesRoot;
    string profileId;
    string sessionId;
    string deviceId;
    string language;
    string model;
    string audioInput;
    LiveAudioFormat audio;
    int simulateUploadKbps;
    string ttsPlaybackCommand;
    ConsoleCommand command;
    bool loadMemory = true;
    bool stream = true;
    bool speak;
    bool playMusic;
    ReasoningMode reasoningMode;
    int speechCommitDelaySeconds;
    bool speechInterrupt;
    string[] speechInterruptPhrases;
    bool clientToolsOnce;
    bool clientToolsDryRun;
    int turns;
    int clientToolsPollMs = 500;
    int clientToolsIdleTimeoutSeconds;
    int helpExitCode;
}

ConsoleConfig parseConsoleArgs(string[] args)
{
    ConsoleConfig config;
    if (args.length == 2 && (args[1] == "--help" || args[1] == "-h")) {
        config.command = ConsoleCommand.help;
        return config;
    }
    enforce(args.length == 2, "wheatley console requires exactly one JSON run-profile path");

    auto profile = loadRunProfile(args[1]);
    auto sharedSection = Json.object(profile.section("shared"), "shared");
    auto consoleJson = Json.object(profile.section("console"), "console");
    auto api = sharedSection.object("api");
    auto clientHost = runProfileValue(api.text("client_host"));
    auto apiPort = api.positiveInt("port");
    config.apiBase = "http://" ~ clientHost ~ ":" ~ apiPort.to!string ~ "/api";
    config.appDataRoot = runProfilePath(
        sharedSection.text("app_data_root"),
        profile.directory,
    );
    config.resourcesRoot = buildPath(config.appDataRoot, "resources");
    config.profileId = consoleJson.text("profile");
    config.deviceId = consoleJson.text("device_id");
    config.language = consoleJson.text("language");
    config.loadMemory = consoleJson.boolean("load_memory");
    config.speechInterrupt = consoleJson.boolean("speech_interrupt");
    config.speechInterruptPhrases = consoleJson.nonEmptyTexts("speech_interrupt_phrases");
    config.turns = consoleJson.nonNegativeInt("turns");
    config.audioInput = runProfileValue(consoleJson.text("audio_input"));
    config.ttsPlaybackCommand = runProfileValue(consoleJson.text("tts_playback_command"));
    config.command = parseCommand(consoleJson.text("command"));

    auto audio = consoleJson.object("audio");
    config.audio.format = audio.choice!("pcm_s16le", "opus")("format");
    config.audio.sampleRate = 16_000;
    config.audio.channels = 1;
    config.audio.frameMs = audio.positiveInt("frame_ms");
    config.audio.bitrate = audio.nonNegativeInt("bitrate");
    config.audio.application = audio.text("application");
    config.audio.complexity = audio.intRange("complexity", 0, 10);
    config.audio.container = audio.text("container");
    validateLiveAudioFormat(config.audio);
    config.simulateUploadKbps = audio.nonNegativeInt("simulate_upload_kbps");

    auto tools = consoleJson.object("client_tools");
    config.clientToolsOnce = tools.boolean("once");
    config.clientToolsDryRun = tools.boolean("dry_run");
    config.clientToolsPollMs = tools.positiveInt("poll_ms");
    config.clientToolsIdleTimeoutSeconds = tools.nonNegativeInt("idle_timeout_seconds");

    enforce(config.apiBase.strip.length > 0, "shared.api_base cannot be empty");
    enforceSafeToken(config.profileId, "console.profile");
    enforceSafeToken(config.deviceId, "console.device_id");
    enforceSafeToken(config.language, "console.language");
    if (!config.ttsPlaybackCommand.length)
        config.ttsPlaybackCommand = defaultTtsPlaybackCommand(config.appDataRoot);
    return config;
}

void printConsoleHelp()
{
    writeln("Usage: wheatley RUN_PROFILE.json");
    writeln("The console section selects voice, chat, or client-tools mode.");
}

private ConsoleCommand parseCommand(string value)
{
    switch (requireChoice!("chat", "voice", "client-tools")(value, "console.command")) {
        case "chat": return ConsoleCommand.chat;
        case "voice": return ConsoleCommand.voice;
        case "client-tools": return ConsoleCommand.clientTools;
        default: assert(false);
    }
}

private string defaultTtsPlaybackCommand(string appDataRoot)
{
    return resolveBundledExecutable(
        "wheatley-audio-player",
        "audio player",
        appDataRoot,
    );
}
