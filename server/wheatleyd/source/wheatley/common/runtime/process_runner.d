module wheatley.common.runtime.process_runner;

import core.time : Duration, dur;
import std.algorithm : min;
import std.array : appender, split;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, isFile;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.process : environment;
import std.string : endsWith, strip, toLower;

import vibe.core.core : runTask;
import vibe.core.path : NativePath;
import vibe.core.process : Config, Redirect;
import vibe.core.stream : blocking;

version (Windows) {
    import wheatley.common.runtime.windows_process :
        WindowsProcess,
        WindowsProcessPipes,
        pipeWindowsProcess;

    alias LocalProcess = WindowsProcess;
    alias LocalProcessPipes = WindowsProcessPipes;
} else {
    import vibe.core.process : Process, ProcessPipes, pipeProcess;

    alias LocalProcess = Process;
    alias LocalProcessPipes = ProcessPipes;
}

struct LocalProcessResult
{
    int status;
    string output;
    bool timedOut;
    bool outputTruncated;
}

string findExecutableOnPath(string name)
{
    auto executable = name.strip;
    enforce(executable.length > 0, "Executable name is empty");

    foreach (dir; environment.get("PATH", "").split(pathListSeparator())) {
        if (!dir.length) continue;
        foreach (fileName; executableFileNames(executable)) {
            auto path = buildPath(dir, fileName);
            if (exists(path) && isFile(path)) {
                return absolutePath(buildNormalizedPath(path));
            }
        }
    }
    return "";
}

LocalProcessPipes pipeLocalProcess(
    string[] command,
    Redirect redirect,
    const string[string] env,
    Config config,
    NativePath workDir,
)
{
    version (Windows) {
        auto mergeStderr = (redirect & Redirect.stderrToStdout) == Redirect.stderrToStdout;
        return pipeWindowsProcess(
            command,
            env,
            config == Config.newEnv,
            workDir.toString(),
            isWindowsCommandScript(command[0]),
            mergeStderr,
        );
    } else {
        return pipeProcess(command, redirect, env, config, workDir);
    }
}

LocalProcessResult runLocalProcess(
    string[] command,
    string input = "",
    string workDir = "",
    double timeoutSeconds = 120.0,
    size_t maxOutputBytes = 128 * 1024,
)
{
    return runLocalProcessBytes(
        command,
        cast(const(ubyte)[]) input,
        workDir,
        timeoutSeconds,
        maxOutputBytes,
    );
}

LocalProcessResult runLocalProcessBytes(
    string[] command,
    const(ubyte)[] input,
    string workDir = "",
    double timeoutSeconds = 120.0,
    size_t maxOutputBytes = 128 * 1024,
)
{
    enforce(command.length > 0, "Process command is empty");

    auto nativeWorkDir = NativePath(workDir.length ? workDir : absolutePath(buildNormalizedPath(".")));
    auto pipes = pipeLocalProcess(
        command,
        Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout,
        null,
        Config.none,
        nativeWorkDir,
    );

    BoundedProcessOutput output;
    Exception outputError;
    auto outputTask = runTask({
        try {
            output = collectBoundedOutput(pipes.stdout, maxOutputBytes);
        } catch (Exception error) {
            outputError = error;
        }
    });

    if (input.length) pipes.stdin.write(input);
    pipes.stdin.close();

    bool timedOut;
    int status;
    if (timeoutSeconds > 0) {
        auto maybeStatus = pipes.process.wait(timeoutDuration(timeoutSeconds));
        if (maybeStatus.isNull) {
            timedOut = true;
            pipes.process.forceKill();
            status = pipes.process.wait();
        } else {
            status = maybeStatus.get;
        }
    } else {
        status = pipes.process.wait();
    }

    outputTask.join();
    if (outputError !is null) throw outputError;
    return LocalProcessResult(status, output.text, timedOut, output.truncated);
}

void enforceProcessOk(LocalProcessResult result, string label)
{
    auto output = processOutputMessage(result);
    enforce(!result.timedOut, output.length ? label ~ " timed out: " ~ output : label ~ " timed out");
    enforce(
        result.status == 0,
        output.length
            ? label ~ " failed: " ~ output
            : label ~ " failed with status " ~ statusText(result.status),
    );
}

private struct BoundedProcessOutput
{
    string text;
    bool truncated;
}

private BoundedProcessOutput collectBoundedOutput(InputStream)(InputStream stream, size_t maxBytes)
@blocking @trusted
{
    auto output = appender!string();
    if (maxBytes != size_t.max) {
        output.reserve(maxBytes);
    }

    ubyte[64 * 1024] buffer;
    bool truncated;
    size_t retainedBytes;

    while (!stream.empty) {
        auto chunk = cast(size_t) min(stream.leastSize, buffer.length);
        assert(chunk > 0, "leastSize returned zero for non-empty stream.");

        stream.read(buffer[0 .. chunk]);
        if (retainedBytes < maxBytes) {
            auto retainedChunk = min(chunk, maxBytes - retainedBytes);
            output.put(cast(const(char)[]) buffer[0 .. retainedChunk]);
            retainedBytes += retainedChunk;
            truncated = truncated || retainedChunk < chunk;
        } else {
            truncated = true;
        }
    }

    return BoundedProcessOutput(output.data, truncated);
}

private string processOutputMessage(LocalProcessResult result)
{
    auto output = result.output.strip;
    if (result.outputTruncated) {
        output ~= output.length ? "\n[output truncated]" : "[output truncated]";
    }
    return output;
}

private Duration timeoutDuration(double seconds)
{
    auto msecs = cast(long) (seconds * 1_000);
    return dur!"msecs"(msecs > 0 ? msecs : 1);
}

private string statusText(int status)
{
    return status.to!string;
}

private string pathListSeparator()
{
    version (Windows) {
        return ";";
    } else {
        return ":";
    }
}

private string[] executableFileNames(string name)
{
    version (Windows) {
        auto lower = name.toLower;
        if (
            lower.endsWith(".com")
            || lower.endsWith(".exe")
            || lower.endsWith(".bat")
            || lower.endsWith(".cmd")
        ) {
            return [name];
        }
        return [name ~ ".com", name ~ ".exe", name ~ ".bat", name ~ ".cmd"];
    } else {
        return [name];
    }
}

private bool isWindowsCommandScript(string path)
{
    auto lower = path.toLower;
    return lower.endsWith(".bat") || lower.endsWith(".cmd");
}

unittest
{
    version (Posix) {
        auto input = cast(ubyte[]) [0, 1, 2, 65, 255];
        auto result = runLocalProcessBytes(["/bin/cat"], input, "", 5.0, 32);
        enforceProcessOk(result, "cat");
        assert(result.output.length == input.length);
        foreach (index, value; input) {
            assert(cast(ubyte) result.output[index] == value);
        }
    }
}
