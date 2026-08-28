module wheatley.client.console.ui.startup_status;

import vibe.core.core : runTask;
import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.client.console.audio.runtime : ConsoleAudioRuntime;
import wheatley.client.console.config : ConsoleConfig;
import wheatley.client.console.ui.output : writeTurn;
import wheatley.client.console.ui.system_announcement :
    sayConsoleSystem,
    writeConsoleSystem;
import wheatley.common.api.profile_startup : ProfileStartupResult;

struct ConsoleStartupOptions
{
    bool speakMemoryStart;
    string resumeSessionId;
}

ProfileStartupResult announceConsoleStartup(
    ConsoleApiClient client,
    ConsoleAudioRuntime audio,
    ConsoleConfig config,
    string mode,
    ConsoleStartupOptions options = ConsoleStartupOptions(),
)
{
    auto result = client.streamStartup(
        config.profileId,
        config.language,
        mode,
        options.resumeSessionId,
        config.model,
        (kind, message) {
            if (kind == "memory_update_start") {
                writeTurn(config.profileId, message, "orange");
                if (options.speakMemoryStart) sayConsoleSystemAsync(audio, config, message);
                return;
            }
            if (kind == "memory_update_done") {
                writeTurn(config.profileId, message, "orange");
                return;
            }
            writeConsoleSystem(message);
        },
    );
    if (!result.ok) throw new Exception("Profile startup did not complete");
    return result;
}

private void sayConsoleSystemAsync(
    ConsoleAudioRuntime audio,
    ConsoleConfig config,
    string message,
)
{
    if (!config.speak) return;
    runTask(() nothrow {
        try {
            sayConsoleSystem(audio, config, message);
        } catch (Throwable) {
        }
    });
}
