module wheatley.server.app;

import std.stdio : stderr, writeln;

import wheatley.server.api.core.cli_config : parseArgs;
import wheatley.server.api.server : runApiServer;
import wheatley.server.config.app_config_store : AppConfigStore;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.history.store : HistoryStore;
import wheatley.common.runtime.temp_files : cleanupRuntimeTempFiles;

int main(string[] args)
{
    try {
        auto config = parseArgs(args);
        cleanupRuntimeTempFiles(config.appDataRoot, "wheatleyd", "audio-processing");
        auto appConfig = new AppConfigStore(config.configPath);
        auto store = new HistoryStore(
            config.profilesRoot,
            appConfig,
            config.appDataRoot,
            config.resourcesRoot,
        );
        auto files = new RuntimeFiles(config.profilesRoot);
        files.cleanupGeneratedTts();
        string[] vibeArgs = [args.length ? args[0] : "wheatleyd"];
        return runApiServer(config, appConfig, store, files, vibeArgs);
    } catch (Exception error) {
        stderr.writeln("wheatleyd: ", error.toString());
        return 1;
    }
}
