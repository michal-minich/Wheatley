module wheatley.client.console.ui.system_announcement;

import std.string : strip;

import wheatley.client.console.audio.runtime : ConsoleAudioRuntime;
import wheatley.client.console.config : ConsoleConfig;
import wheatley.client.console.ui.output : writeSystemTurn;

void announceConsoleSystem(ConsoleAudioRuntime audio, ConsoleConfig config, string message)
{
    auto text = message.strip;
    if (!text.length) return;

    writeConsoleSystem(text);
    sayConsoleSystem(audio, config, text);
}

void writeConsoleSystem(string message)
{
    writeSystemTurn(message);
}

void sayConsoleSystem(ConsoleAudioRuntime audio, ConsoleConfig config, string message)
{
    if (!config.speak) return;
    try {
        audio.speakSystem(config, message);
    } catch (Exception) {
    }
}
