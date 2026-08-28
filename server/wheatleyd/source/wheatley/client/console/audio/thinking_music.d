module wheatley.client.console.audio.thinking_music;

import core.time : dur;

import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.format : format;
import std.math : pow;

import vibe.core.process : Process, spawnProcess;
import vibe.core.core : runTask, sleep;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.temp_files : removeQuietly, temporaryRuntimeFile;

final class ConsoleThinkingMusic
{
    private string appDataRoot;
    private string profileId;
    private ConsoleApiClient client;
    private string playerPath;
    private size_t requestGeneration;
    private Process activeProcess;
    private string activeAudioPath;

    this(string appDataRoot, string profileId, ConsoleApiClient client)
    {
        this.appDataRoot = appDataRoot;
        this.profileId = profileId;
        this.client = client;
        try {
            version (Windows) {
                playerPath = resolveBundledExecutable(
                    "ffplay",
                    "thinking music player",
                    appDataRoot,
                );
            } else {
                playerPath = resolveBundledExecutable(
                    "wheatley-audio-player",
                    "thinking music player",
                    appDataRoot,
                );
            }
        } catch (Exception) {
            playerPath = "";
        }
    }

    void play() nothrow
    {
        try {
            stop();
            start(requestGeneration);
        } catch (Throwable) {
            activeProcess = Process.init;
        }
    }

    void playAfter(long delayMillis) nothrow
    {
        try {
            stop();
            auto generation = requestGeneration;
            runTask(() nothrow {
                try {
                    sleep(dur!"msecs"(delayMillis));
                    start(generation);
                } catch (Throwable) {
                }
            });
        } catch (Throwable) {
        }
    }

    void stop() nothrow
    {
        try {
            requestGeneration++;
            stopActiveProcess();
            clearActiveAudio();
        } catch (Throwable) {
        }
    }

    private void start(size_t generation)
    {
        if (generation != requestGeneration || !playerPath.length) return;
        auto path = temporaryRuntimeFile(
            appDataRoot,
            "console-client",
            "thinking-music",
            "track",
            ".mp3",
        );
        double gainDb;
        try {
            gainDb = client.downloadThinkingMusic(profileId, path);
        } catch (Exception) {
            removeQuietly(path);
            return;
        }
        if (generation != requestGeneration) {
            removeQuietly(path);
            return;
        }
        enforce(exists(path), "Thinking music track does not exist");
        activeAudioPath = path;
        activeProcess = spawnProcess(thinkingMusicArguments(
            playerPath,
            path,
            decibelsToLinear(gainDb),
        ));
    }

    private void stopActiveProcess()
    {
        auto process = activeProcess;
        activeProcess = Process.init;
        if (!process) return;
        if (!process.exited) process.kill();
        auto status = process.wait(dur!"msecs"(500));
        if (status.isNull) {
            process.forceKill();
            process.wait();
        }
    }

    private void clearActiveAudio()
    {
        auto path = activeAudioPath;
        activeAudioPath = "";
        removeQuietly(path);
    }
}

private string[] thinkingMusicArguments(string playerPath, string audioPath, double gain)
{
    version (Windows) {
        return [
            playerPath,
            "-hide_banner",
            "-loglevel", "error",
            "-nodisp",
            "-loop", "0",
            "-volume", (cast(int) (gain * 100.0)).to!string,
            audioPath,
        ];
    } else {
        return [
            playerPath,
            "--loop",
            "--gain",
            format!"%.6f"(gain),
            audioPath,
        ];
    }
}

private double decibelsToLinear(double decibels)
{
    return pow(10.0, decibels / 20.0);
}

unittest
{
    assert(decibelsToLinear(-20.0) > 0.099);
    assert(decibelsToLinear(-20.0) < 0.101);
}
