module wheatley.server.turns.text.pi_runtime;

import std.array : appender;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.file : exists, isFile;
import std.path : absolutePath, buildNormalizedPath;
import std.string : strip;
import std.utf : stride;

import wheatley.common.runtime.process_runner : findExecutableOnPath, runLocalProcess;

struct PiAvailability
{
    bool available;
    string command;
    string resolvedPath;
    string detail;
    string output;
    int exitStatus = -1;
    bool timedOut;
    bool outputTruncated;
}

struct PiExecutable
{
    string command;
    string path;
    string detail;
}

PiAvailability checkPiAvailability(string command)
{
    PiAvailability result;
    auto executable = resolvePiExecutable(command);
    result.command = executable.command;
    result.resolvedPath = executable.path;
    if (!executable.path.length) {
        result.detail = executable.detail;
        return result;
    }

    try
    {
        auto process = runLocalProcess(
            [executable.path, "--version"],
            "",
            "",
            5.0,
            4 * 1024,
        );
        result.exitStatus = process.status;
        result.timedOut = process.timedOut;
        result.outputTruncated = process.outputTruncated;
        result.output = process.output.strip;

        if (!process.timedOut && process.status == 0)
        {
            result.available = true;
            result.detail = result.output.length ? result.output : "Pi launch check passed.";
            return result;
        }

        if (process.timedOut)
        {
            result.detail = "Pi launch check timed out.";
        }
        else if (result.output.length)
        {
            result.detail = result.output;
        }
        else
        {
            result.detail = "Pi launch check failed with status " ~ process.status.to!string ~ ".";
        }
    }
    catch (Exception error)
    {
        result.detail = error.msg;
    }

    return result;
}

PiExecutable resolvePiExecutable(string command)
{
    if (isPathLikeCommand(command)) {
        auto path = absolutePath(buildNormalizedPath(command));
        if (!exists(path)) {
            return PiExecutable(command, "", "Pi command does not exist: " ~ path);
        }
        if (!isFile(path)) {
            return PiExecutable(command, "", "Pi command is not a file: " ~ path);
        }
        return PiExecutable(command, path, "");
    }

    auto path = findExecutableOnPath(command);
    if (!path.length) {
        return PiExecutable(command, "", "Pi command not found on PATH: " ~ command);
    }
    return PiExecutable(command, path, "");
}

string piRuntimeModelName(string provider, string model)
{
    return "pi:" ~ provider ~ "/" ~ model;
}

string piSessionId(string profileId, string sessionDate, string sessionFolder)
{
    return safeId("wheatley-" ~ profileId ~ "-" ~ sessionDate ~ "-" ~ sessionFolder);
}

string safeId(string value)
{
    auto output = appender!string;
    foreach (ch; value) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            output.put(ch);
        } else {
            output.put("-");
        }
    }
    return output.data;
}

private bool isPathLikeCommand(string command)
{
    return command.canFind("/") || command.canFind("\\");
}

string limitPiText(string text, size_t maxBytes)
{
    if (text.length <= maxBytes) return text;
    size_t index;
    while (index < text.length) {
        auto next = index + stride(text, index);
        if (next > maxBytes) break;
        index = next;
    }
    if (!index) index = maxBytes;
    return text[0 .. index] ~ "\n[truncated]";
}
