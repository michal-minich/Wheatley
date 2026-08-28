module wheatley.server.turns.text.pi_worker;

import core.sync.mutex : Mutex;
import core.time : MonoTime;

import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

import vibe.core.path : NativePath;
import vibe.core.process : Config, Redirect;
import vibe.stream.operations : readLine;

import wheatley.common.api.session : SessionKey;
import wheatley.common.json.object : jsonObject, jsonRawField, jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.process_runner : LocalProcessPipes, pipeLocalProcess;
import wheatley.server.turns.text.pi_events : PiEventCollector;
import wheatley.server.turns.text.pi_event_sink : PiWorkerEventSink;

private enum maxPiRpcLineBytes = 64UL * 1024 * 1024;

struct PiWorkerTurnResult
{
    bool workerStarted;
    MonoTime workerStartedMono;
    MonoTime workerReadyMono;
}

final class PiWorkerProcessFailure : Exception
{
    bool hasExitStatus;
    int exitStatus;

    this(string message, bool hasExitStatus = false, int exitStatus = -1)
    {
        super(message);
        this.hasExitStatus = hasExitStatus;
        this.exitStatus = exitStatus;
    }
}

final class PiWorkerRegistry
{
    private enum maxWorkers = 4;
    private Mutex mutex;
    private PiWorker[string] workers;

    this()
    {
        mutex = new Mutex;
    }

    PiWorker workerFor(
        SessionKey session,
        string fingerprint,
        string[] command,
        string[string] environment,
        string workingRoot,
    )
    {
        synchronized (mutex) {
            auto key = session.value;
            auto existing = key in workers;
            if (existing !is null && existing.fingerprint == fingerprint) return *existing;
            if (existing !is null) existing.shutdown();
            if (existing is null && workers.length >= maxWorkers) {
                foreach (victimKey, victim; workers) {
                    workers.remove(victimKey);
                    victim.shutdown();
                    break;
                }
            }
            auto worker = new PiWorker(fingerprint, command, environment, workingRoot);
            workers[key] = worker;
            return worker;
        }
    }

    void stop(SessionKey session, string turnId)
    {
        PiWorker worker;
        synchronized (mutex) {
            if (auto existing = session.value in workers) worker = *existing;
        }
        if (worker !is null) worker.abort(turnId);
    }

    void recycle(SessionKey session)
    {
        PiWorker worker;
        synchronized (mutex) {
            auto key = session.value;
            if (auto existing = key in workers) {
                worker = *existing;
                workers.remove(key);
            }
        }
        if (worker !is null) worker.shutdown();
    }

    void discard(SessionKey session, PiWorker worker)
    {
        bool removed;
        synchronized (mutex) {
            auto key = session.value;
            auto existing = key in workers;
            if (existing !is null && *existing is worker) {
                workers.remove(key);
                removed = true;
            }
        }
        if (removed) worker.shutdown();
    }

    void shutdown()
    {
        PiWorker[] active;
        synchronized (mutex) {
            foreach (worker; workers) active ~= worker;
            workers = null;
        }
        foreach (worker; active) worker.shutdown();
    }
}

final class PiWorker
{
    immutable string fingerprint;

    private string[] command;
    private string[string] environment;
    private string workingRoot;
    private LocalProcessPipes pipes;
    private bool started;
    private Mutex stateMutex;
    private Mutex writeMutex;
    private string activeTurnId;

    this(
        string fingerprint,
        string[] command,
        string[string] environment,
        string workingRoot,
    )
    {
        this.fingerprint = fingerprint;
        this.command = command;
        this.environment = environment;
        this.workingRoot = workingRoot;
        this.stateMutex = new Mutex;
        this.writeMutex = new Mutex;
    }

    PiWorkerTurnResult run(
        string turnId,
        string prompt,
        string thinkingLevel,
        PiWorkerEventSink events,
        bool delegate() stopped,
        string imagesJson = "",
    )
    {
        synchronized (stateMutex) {
            enforce(!activeTurnId.length, "Pi worker is already running a turn");
            activeTurnId = turnId;
        }
        scope(exit) synchronized (stateMutex) {
            if (activeTurnId == turnId) activeTurnId = "";
        }

        auto result = ensureStarted();
        if (isStopped(stopped)) return result;

        auto thinkingRequestId = turnId ~ "-thinking";
        writeRpc(jsonObject([
            jsonStringField("id", thinkingRequestId),
            jsonStringField("type", "set_thinking_level"),
            jsonStringField("level", thinkingLevel),
        ]));
        waitForResponse(thinkingRequestId, events);
        if (isStopped(stopped)) return result;

        auto steeringRequestId = turnId ~ "-steering-mode";
        writeRpc(jsonObject([
            jsonStringField("id", steeringRequestId),
            jsonStringField("type", "set_steering_mode"),
            jsonStringField("mode", "all"),
        ]));
        waitForResponse(steeringRequestId, events);
        if (isStopped(stopped)) return result;

        auto promptRequestId = turnId ~ "-prompt";
        writeRpc(jsonObject([
            jsonStringField("id", promptRequestId),
            jsonStringField("type", "prompt"),
            jsonStringField("message", prompt),
            imagesJson.length ? jsonRawField("images", imagesJson) : "",
        ]));

        bool promptAccepted;
        bool settled;
        while (!promptAccepted || !settled) {
            auto line = readRpcLine();
            events.handleLine(line);
            JSONValue event;
            if (!parseRpcObject(line, event)) continue;
            if (rpcResponseMatches(event, promptRequestId)) {
                enforceRpcSuccess(event, promptRequestId);
                promptAccepted = true;
            }
            auto eventType = Json.object(event).opt.text("type");
            if (!eventType.isNull && eventType.get == "agent_settled") settled = true;
        }
        return result;
    }

    PiWorkerTurnResult compact(string commandId, PiEventCollector events)
    {
        synchronized (stateMutex) {
            enforce(!activeTurnId.length, "Pi worker is already running a turn");
            activeTurnId = commandId;
        }
        scope(exit) synchronized (stateMutex) {
            if (activeTurnId == commandId) activeTurnId = "";
        }

        auto result = ensureStarted();
        auto requestId = commandId ~ "-compact";
        writeRpc(jsonObject([
            jsonStringField("id", requestId),
            jsonStringField("type", "compact"),
        ]));
        waitForResponse(requestId, events);
        return result;
    }

    void abort(string turnId)
    {
        synchronized (stateMutex) {
            if (!started || activeTurnId != turnId) return;
        }
        try {
            writeRpc(jsonObject([
                jsonStringField("id", turnId ~ "-abort"),
                jsonStringField("type", "abort"),
            ]));
        } catch (Exception) {
        }
    }

    bool steer(
        string turnId,
        string commandId,
        string message,
        void delegate() admitted,
        string imagesJson = "",
    )
    {
        synchronized (stateMutex) {
            if (!started || activeTurnId != turnId || pipes.process.exited) return false;
            if (admitted !is null) admitted();
        }
        writeRpc(jsonObject([
            jsonStringField("id", commandId),
            jsonStringField("type", "steer"),
            jsonStringField("message", message),
            imagesJson.length ? jsonRawField("images", imagesJson) : "",
        ]));
        return true;
    }

    void shutdown()
    {
        bool shouldStop;
        synchronized (stateMutex) {
            shouldStop = started;
            started = false;
            activeTurnId = "";
        }
        if (!shouldStop) return;
        try {
            pipes.stdin.close();
        } catch (Exception) {
        }
        try {
            if (!pipes.process.exited) pipes.process.forceKill();
            pipes.process.wait();
        } catch (Exception) {
        }
        pipes = LocalProcessPipes.init;
    }

    private PiWorkerTurnResult ensureStarted()
    {
        synchronized (stateMutex) {
            if (started && !pipes.process.exited) return PiWorkerTurnResult();
            started = false;
        }
        synchronized (stateMutex) {
            auto startedMono = MonoTime.currTime;
            pipes = pipeLocalProcess(
                command,
                Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout,
                environment,
                Config.none,
                NativePath(workingRoot),
            );
            started = true;
            auto requestId = "wheatley-worker-ready";
            writeRpc(jsonObject([
                jsonStringField("id", requestId),
                jsonStringField("type", "get_state"),
            ]));
            waitForResponse(requestId, null);
            return PiWorkerTurnResult(true, startedMono, MonoTime.currTime);
        }
    }

    private void waitForResponse(string requestId, PiWorkerEventSink events)
    {
        while (true) {
            auto line = readRpcLine();
            if (events !is null) events.handleLine(line);
            JSONValue event;
            if (!parseRpcObject(line, event) || !rpcResponseMatches(event, requestId)) continue;
            enforceRpcSuccess(event, requestId);
            return;
        }
    }

    private string readRpcLine()
    {
        if (pipes.stdout.empty) {
            int status = pipes.process.wait();
            started = false;
            throw new PiWorkerProcessFailure(
                "Pi RPC worker exited with status " ~ status.to!string,
                true,
                status,
            );
        }
        return readPiRpcLine(pipes.stdout);
    }

    private void writeRpc(string json)
    {
        synchronized (writeMutex) {
            enforce(started, "Pi RPC worker is not running");
            pipes.stdin.write(json);
            pipes.stdin.write("\n");
        }
    }
}

private string readPiRpcLine(InputStream)(InputStream stream)
{
    auto line = cast(string) stream.readLine(maxPiRpcLineBytes, "\n");
    if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
    return line.strip;
}

private bool isStopped(bool delegate() stopped)
{
    return stopped !is null && stopped();
}

private bool parseRpcObject(string line, ref JSONValue event)
{
    try {
        event = parseJSON(line);
        return event.type == JSONType.object;
    } catch (Exception) {
        return false;
    }
}

private bool rpcResponseMatches(JSONValue event, string requestId)
{
    auto json = Json.object(event);
    auto type = json.opt.text("type");
    auto id = json.opt.text("id");
    return !type.isNull && type.get == "response"
        && !id.isNull && id.get == requestId;
}

private void enforceRpcSuccess(JSONValue event, string requestId)
{
    auto json = Json.object(event);
    auto success = json.opt.boolean("success");
    auto error = json.opt.text("error");
    enforce(
        !success.isNull && success.get,
        !error.isNull && error.get.length
            ? "Pi RPC request " ~ requestId ~ " failed: " ~ error.get
            : "Pi RPC request " ~ requestId ~ " failed",
    );
}

unittest
{
    JSONValue event;
    assert(parseRpcObject(
        `{"id":"turn-prompt","type":"response","command":"prompt","success":true}`,
        event,
    ));
    assert(rpcResponseMatches(event, "turn-prompt"));
    enforceRpcSuccess(event, "turn-prompt");
    assert(!rpcResponseMatches(event, "other"));
}

unittest
{
    import std.array : replicate;
    import vibe.stream.memory : createMemoryStream;

    auto line = `{"type":"message","data":"`
        ~ replicate("x", 1024 * 1024 + 1)
        ~ `"}`;
    auto stream = createMemoryStream(cast(ubyte[]) (line ~ "\n").dup, false);
    assert(readPiRpcLine(stream) == line);
}
