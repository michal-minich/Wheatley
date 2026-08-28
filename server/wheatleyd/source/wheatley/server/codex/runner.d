module wheatley.server.codex.runner;

import core.time : dur;

import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildNormalizedPath;
import std.process : environment;
import std.string : strip;
import std.uuid : randomUUID;

import vibe.core.channel : Channel, createChannel;
import vibe.core.core : runTask;
import vibe.core.path : NativePath;
import vibe.core.process : Config, Redirect;
import vibe.core.sync : TaskMutex, scopedMutexLock;
import vibe.stream.operations : readLine;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.process_runner :
    LocalProcessPipes,
    findExecutableOnPath,
    pipeLocalProcess;

alias CodexNotificationSink = void delegate(JSONValue notification);

/** Owns one continuously connected Codex App Server child. */
final class CodexAppServerGateway
{
    private string workspaceRoot;
    private CodexNotificationSink notificationSink;
    private TaskMutex mutex;
    private LocalProcessPipes pipes;
    private Channel!(string, 1)[string] pending;
    private bool running;
    private bool shuttingDown;
    private string processError;

    this(string workspaceRoot, CodexNotificationSink notificationSink)
    {
        this.workspaceRoot = absolutePath(buildNormalizedPath(workspaceRoot));
        enforce(notificationSink !is null, "Codex notification sink is required");
        this.notificationSink = notificationSink;
        this.mutex = new TaskMutex;
    }

    void start()
    {
        {
            auto guard = scopedMutexLock(mutex);
            if (running) return;
            auto codex = findExecutableOnPath("codex");
            enforce(codex.length, "Codex command not found on PATH: codex");
            pipes = pipeLocalProcess(
                [codex, "app-server", "--stdio"],
                Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout,
                codexEnvironment(),
                Config.newEnv,
                NativePath(workspaceRoot),
            );
            running = true;
            shuttingDown = false;
            processError = "";
        }
        runTask(() nothrow {
            try readerLoop();
            catch (Throwable error) failProcess(error.msg);
        });
        request("initialize", jsonObject([
            jsonRawField("clientInfo", jsonObject([
                jsonStringField("name", "wheatley_codex_worker"),
                jsonStringField("title", "Wheatley Codex Worker"),
                jsonStringField("version", "0.3.0"),
            ])),
            jsonRawField("capabilities", jsonObject([
                jsonBoolField("experimentalApi", true),
                jsonBoolField("requestAttestation", false),
            ])),
        ]));
        notify("initialized", "{}");
    }

    JSONValue request(string method, string paramsJson)
    {
        enforce(method.length, "Codex request method is required");
        auto id = "wheatley-" ~ randomUUID().toString();
        auto response = createChannel!(string, 1)();
        {
            auto guard = scopedMutexLock(mutex);
            enforce(running, processError.length
                ? processError
                : "Codex App Server is not running");
            pending[id] = response;
            try {
                writeLocked(jsonObject([
                    jsonStringField("id", id),
                    jsonStringField("method", method),
                    jsonRawField("params", paramsJson),
                ]));
            } catch (Exception error) {
                pending.remove(id);
                throw error;
            }
        }
        string responseText;
        if (!response.tryConsumeOne(responseText, dur!"seconds"(30))) {
            auto guard = scopedMutexLock(mutex);
            pending.remove(id);
            throw new Exception("Codex App Server acknowledgement timed out");
        }
        auto envelope = parseJSON(responseText);
        auto error = field(envelope, "error");
        if (error !is null && error.type == JSONType.object) {
            auto message = Json.object(*error).opt.textOrEmpty("message");
            throw new Exception(message.length ? message : error.toString());
        }
        auto result = field(envelope, "result");
        enforce(result !is null, "Codex response has no result");
        return *result;
    }

    void notify(string method, string paramsJson)
    {
        auto guard = scopedMutexLock(mutex);
        enforce(running, processError.length
            ? processError
            : "Codex App Server is not running");
        writeLocked(jsonObject([
            jsonStringField("method", method),
            jsonRawField("params", paramsJson),
        ]));
    }

    void shutdown()
    {
        Channel!(string, 1)[] waiters;
        {
            auto guard = scopedMutexLock(mutex);
            if (!running) return;
            shuttingDown = true;
            running = false;
            foreach (id, channel; pending) waiters ~= channel;
            pending = null;
            try pipes.stdin.close(); catch (Exception) {}
        }
        auto stopped = jsonObject([
            jsonRawField("error", jsonObject([
                jsonStringField("message", "Codex App Server is shutting down"),
            ])),
        ]);
        foreach (waiter; waiters) waiter.put(stopped);
        if (pipes.process && !pipes.process.exited) {
            auto status = pipes.process.wait(dur!"msecs"(1_000));
            if (status.isNull) {
                pipes.process.kill();
                if (pipes.process.wait(dur!"msecs"(500)).isNull) {
                    pipes.process.forceKill();
                    pipes.process.wait();
                }
            }
        }
    }

    private void readerLoop()
    {
        while (true) {
            {
                auto guard = scopedMutexLock(mutex);
                if (!running) return;
            }
            string line;
            try line = cast(string) pipes.stdout.readLine(4 * 1024 * 1024, "\n");
            catch (Exception error) {
                failProcess(error.msg);
                return;
            }
            if (!line.length) {
                failProcess("Codex App Server ended");
                return;
            }
            if (line[$ - 1] == '\r') line = line[0 .. $ - 1];
            auto clean = line.strip;
            if (!clean.length) continue;
            JSONValue envelope;
            try {
                envelope = parseJSON(clean);
                enforce(envelope.type == JSONType.object, "Codex message is not an object");
            } catch (Exception) {
                continue;
            }
            auto idValue = field(envelope, "id");
            if (idValue !is null && idValue.type != JSONType.null_) {
                auto id = idValue.type == JSONType.string
                    ? idValue.str
                    : idValue.toString();
                Channel!(string, 1) response;
                bool matched;
                {
                    auto guard = scopedMutexLock(mutex);
                    auto found = id in pending;
                    if (found !is null) {
                        response = *found;
                        pending.remove(id);
                        matched = true;
                    }
                }
                if (matched) {
                    response.put(envelope.toString());
                    continue;
                }
                auto method = Json.object(envelope).opt.textOrEmpty("method");
                if (method.length) rejectServerRequest(*idValue, method);
                continue;
            }
            notificationSink(envelope);
        }
    }

    private void failProcess(string message) nothrow
    {
        try {
            Channel!(string, 1)[] waiters;
            {
                auto guard = scopedMutexLock(mutex);
                if (shuttingDown) return;
                if (!running && processError.length) return;
                running = false;
                processError = message.length ? message : "Codex App Server ended";
                foreach (id, channel; pending) waiters ~= channel;
                pending = null;
            }
            auto errorEnvelope = parseJSON(jsonObject([
                jsonRawField("error", jsonObject([
                    jsonStringField("message", processError),
                ])),
            ]));
            foreach (waiter; waiters) waiter.put(errorEnvelope.toString());
            notificationSink(parseJSON(jsonObject([
                jsonStringField("method", "wheatley/processFailed"),
                jsonRawField("params", jsonObject([
                    jsonStringField("message", processError),
                ])),
            ])));
        } catch (Throwable) {
        }
    }

    private void writeLocked(string message)
    {
        pipes.stdin.write(message);
        pipes.stdin.write("\n");
        pipes.stdin.flush();
    }

    private void rejectServerRequest(JSONValue id, string method)
    {
        auto guard = scopedMutexLock(mutex);
        if (!running) return;
        writeLocked(jsonObject([
            jsonRawField("id", id.toString()),
            jsonRawField("error", jsonObject([
                jsonLongField("code", -32_001),
                jsonStringField(
                    "message",
                    "Wheatley cannot answer interactive Codex request " ~ method,
                ),
            ])),
        ]));
    }
}

private JSONValue* field(ref JSONValue value, string name)
{
    if (value.type != JSONType.object) return null;
    auto object = value.objectNoRef;
    return name in object;
}

private string[string] codexEnvironment()
{
    string[string] env;
    foreach (key; [
        "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL",
        "LC_CTYPE", "TERM", "CODEX_HOME", "CODEX_SQLITE_HOME", "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR", "NIX_SSL_CERT_FILE",
        "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "__CF_USER_TEXT_ENCODING",
        "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "SYSTEMROOT",
        "COMSPEC", "PATHEXT",
    ]) {
        auto value = environment.get(key, "");
        if (value.length) env[key] = value;
    }
    if (("PATH" in env) is null) {
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    }
    if (("TERM" in env) is null) env["TERM"] = "dumb";
    return env;
}
