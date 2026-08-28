module wheatley.client.console.app;

import core.thread : Thread;
import core.time : dur;

import wheatley.client.console.api.client :
    ConsoleApiClient,
    ConsoleProfilePreferences;
import wheatley.client.console.audio.runtime : ConsoleAudioRuntime;
import wheatley.client.console.background_worker : ConsoleBackgroundWorker;
import wheatley.client.console.text.runner :
    runConsoleTextChat;
import wheatley.client.console.config :
    ConsoleCommand,
    ConsoleConfig,
    parseConsoleArgs,
    printConsoleHelp;
import wheatley.client.console.tools.runner : runConsoleClientTools;
import wheatley.client.console.voice.runner : runConsoleVoice;
import wheatley.client.console.ui.output :
    writeError;

int main(string[] args)
{
    try {
        auto config = parseConsoleArgs(args);
        if (config.command == ConsoleCommand.help) {
            printConsoleHelp();
            return config.helpExitCode;
        }

        auto client = new ConsoleApiClient(config.apiBase);
        if (config.command == ConsoleCommand.chat) {
            config = applyProfilePreferences(config, client.profilePreferences(config.profileId));
            auto clientTools = startClientTools(config);
            scope(exit) stopWorker(clientTools);
            auto audio = new ConsoleAudioRuntime(config, client);
            scope(exit) audio.cancelTurn();
            return runConsoleTextChat(client, audio, config);
        }
        if (config.command == ConsoleCommand.voice) {
            config = applyProfilePreferences(config, client.profilePreferences(config.profileId));
            auto clientTools = startClientTools(config);
            scope(exit) stopWorker(clientTools);
            auto audio = new ConsoleAudioRuntime(config, client);
            scope(exit) audio.cancelTurn();
            return runConsoleVoice(client, audio, config);
        }
        if (config.command == ConsoleCommand.clientTools) {
            return runConsoleClientTools(client, config);
        }

        printConsoleHelp();
        return 2;
    } catch (Exception error) {
        writeError(error.msg);
        return 1;
    }
}

private ConsoleConfig applyProfilePreferences(
    ConsoleConfig config,
    ConsoleProfilePreferences preferences,
)
{
    config.model = preferences.model;
    config.reasoningMode = preferences.reasoningMode;
    config.speak = preferences.autoSpeak;
    config.playMusic = preferences.playMusic;
    config.speechCommitDelaySeconds = preferences.speechCommitDelaySeconds;
    return config;
}

unittest
{
    import wheatley.common.api.reasoning : ReasoningMode;

    auto config = applyProfilePreferences(
        ConsoleConfig(),
        ConsoleProfilePreferences(
            "lmstudio/unsloth/qwen3.8-27b",
            ReasoningMode.low,
            true,
            true,
            false,
            6,
        ),
    );
    assert(config.model == "lmstudio/unsloth/qwen3.8-27b");
    assert(config.reasoningMode == ReasoningMode.low);
    assert(config.speak);
    assert(config.playMusic);
    assert(config.speechCommitDelaySeconds == 6);
}

private ConsoleBackgroundWorker startClientTools(ConsoleConfig config)
{
    return new ConsoleBackgroundWorker("wheatley-client-tools", (stop) {
        while (!stop.stopping()) {
            try {
                runConsoleClientTools(
                    new ConsoleApiClient(config.apiBase),
                    config,
                    () => !stop.stopping(),
                );
                return;
            } catch (Throwable error) {
                if (stop.stopping()) return;
                writeError("client-tools: " ~ error.msg);
                Thread.sleep(dur!"msecs"(1_000));
            }
        }
    });
}

private void stopWorker(ConsoleBackgroundWorker worker)
{
    worker.requestStop();
    worker.join();
}
