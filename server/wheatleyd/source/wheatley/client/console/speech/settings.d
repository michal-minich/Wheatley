module wheatley.client.console.speech.settings;

import wheatley.client.console.config : ConsoleConfig;
import wheatley.client.console.speech.streaming_settings : ConsoleStreamingSpeechSettings;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;

ConsoleStreamingSpeechSettings consoleStreamingSpeechSettings(ConsoleConfig config, string language)
{
    auto settings = ConsoleStreamingSpeechSettings();
    settings.enabled = config.speak;
    settings.appDataRoot = config.appDataRoot;
    settings.apiBase = config.apiBase;
    settings.profileId = config.profileId;
    settings.language = language;
    if (config.speak) {
        version (Windows) {
            settings.playbackCommand = config.ttsPlaybackCommand;
        } else {
            settings.playbackCommand = resolveBundledExecutable(
                "wheatley-audio-player",
                "streaming audio player",
                config.appDataRoot,
            );
        }
    }
    return settings;
}
