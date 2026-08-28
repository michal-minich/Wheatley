module wheatley.server.codex.client;

import core.time : dur;

import std.exception : enforce;
import std.array : appender;
import std.json : parseJSON;
import std.socket :
    AddressFamily,
    Socket,
    SocketOption,
    SocketOptionLevel,
    SocketType,
    UnixAddress;
import std.string : indexOf;

import vibe.core.concurrency : performInWorker;

import wheatley.common.api.session : SessionKey;
import wheatley.common.json.object : jsonObject, jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.codex.port : CodexSessionPort;
import wheatley.server.codex.service : projectedCodexStatus;
import wheatley.server.codex.store : CodexSessionStore;
import wheatley.server.codex.types :
    CodexLiveEvent,
    CodexMessageResult,
    CodexStatusResult;

class CodexWorkerIoException : Exception
{
    this(string message)
    {
        super(message);
    }
}

/** Thin wheatleyd-side adapter for the independently supervised Codex worker. */
final class CodexWorkerClient : CodexSessionPort
{
    private string socketPath;
    private CodexSessionStore localStore;

    this(string socketPath)
    {
        enforce(socketPath.length, "Codex worker socket is required");
        this.socketPath = socketPath;
        localStore = new CodexSessionStore;
    }

    CodexMessageResult message(
        SessionKey session,
        string sessionRoot,
        string piTurnId,
        string value,
    )
    {
        auto json = Json.parse(post("/message", jsonObject([
            jsonStringField("profile_id", session.profileId),
            jsonStringField("session_id", session.sessionId),
            jsonStringField("session_root", sessionRoot),
            jsonStringField("pi_turn_id", piTurnId),
            jsonStringField("message", value),
        ])));
        return CodexMessageResult(
            json.boolean("accepted"),
            json.text("message"),
            json.text("dispatch_id"),
        );
    }

    CodexStatusResult status(SessionKey session, string sessionRoot)
    {
        try {
            auto json = Json.parse(post("/status", jsonObject([
                jsonStringField("profile_id", session.profileId),
                jsonStringField("session_id", session.sessionId),
                jsonStringField("session_root", sessionRoot),
            ])));
            return CodexStatusResult(
                json.text("status"),
                json.boolean("fresh"),
                json.text("updated_at"),
                json.text("content_kind"),
                json.text("content"),
                json.boolean("truncated"),
            );
        } catch (CodexWorkerIoException) {
            return projectedCodexStatus(localStore.load(session, sessionRoot), false);
        }
    }

    CodexLiveEvent[] eventsAfter(
        SessionKey session,
        string sessionRoot,
        long afterSequence,
        long limit = 200,
    )
    {
        return localStore.eventsAfter(session, sessionRoot, afterSequence, limit);
    }

    void shutdown()
    {
    }

    private string post(string path, string body)
    {
        auto result = performInWorker(&postUnixHttp,
            WorkerRequest(socketPath, "/v1" ~ path, body));
        if (result.error.length) throw new CodexWorkerIoException(
            "Codex worker request failed via " ~ socketPath ~ ": " ~ result.error,
        );
        enforce(result.status == 200, workerError(result.body, result.status));
        return result.body;
    }
}

private struct WorkerRequest
{
    string socketPath;
    string path;
    string body;
}

private struct WorkerResponse
{
    int status;
    string body;
    string error;
}

private WorkerResponse postUnixHttp(WorkerRequest request) nothrow
{
    try {
        auto socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        scope(exit) socket.close();
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, dur!"seconds"(2));
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(20));
        socket.connect(new UnixAddress(request.socketPath));

        import std.conv : to;
        auto wire = "POST " ~ request.path ~ " HTTP/1.1\r\n"
            ~ "Host: localhost\r\n"
            ~ "Content-Type: application/json; charset=UTF-8\r\n"
            ~ "Content-Length: " ~ request.body.length.to!string ~ "\r\n"
            ~ "Connection: close\r\n\r\n"
            ~ request.body;
        sendAll(socket, cast(const(ubyte)[]) wire);

        auto raw = appender!(ubyte[]);
        ubyte[8192] buffer;
        while (true) {
            auto received = socket.receive(buffer[]);
            if (received <= 0) break;
            enforce(raw.data.length + received <= 4 * 1024 * 1024,
                "Codex worker response exceeded 4 MiB");
            raw.put(buffer[0 .. received]);
        }
        return parseHttpResponse(cast(string) raw.data);
    } catch (Exception error) {
        return WorkerResponse(0, null, error.msg);
    }
}

private void sendAll(Socket socket, const(ubyte)[] bytes)
{
    size_t offset;
    while (offset < bytes.length) {
        auto sent = socket.send(bytes[offset .. $]);
        enforce(sent > 0, "Codex worker socket closed while sending request");
        offset += sent;
    }
}

private WorkerResponse parseHttpResponse(string raw)
{
    auto separator = raw.indexOf("\r\n\r\n");
    enforce(separator >= 0, "Codex worker returned an invalid HTTP response");
    auto headers = raw[0 .. separator];
    auto lineEnd = headers.indexOf("\r\n");
    auto statusLine = lineEnd >= 0 ? headers[0 .. lineEnd] : headers;
    import std.algorithm : splitter;
    import std.algorithm.searching : startsWith;
    import std.conv : to;
    auto pieces = statusLine.splitter(' ');
    enforce(!pieces.empty && pieces.front.startsWith("HTTP/"),
        "Codex worker returned an invalid HTTP status line");
    pieces.popFront();
    enforce(!pieces.empty, "Codex worker omitted the HTTP status");
    auto status = pieces.front.to!int;
    auto body = raw[separator + 4 .. $];
    return WorkerResponse(status, body, null);
}

private string workerError(string body, int status)
{
    try {
        auto error = Json.parse(body).object("error");
        auto message = error.opt.textOrEmpty("message");
        if (message.length) return message;
    } catch (Exception) {
    }
    import std.conv : to;
    return "Codex worker request failed with HTTP " ~ status.to!string;
}
