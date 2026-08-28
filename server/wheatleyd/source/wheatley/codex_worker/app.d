module wheatley.codex_worker.app;

import std.exception : enforce;
import std.file : exists, isDir, mkdirRecurse, remove;
import std.path : absolutePath, buildNormalizedPath, dirName;
import std.socket : AddressFamily, Socket, SocketType, UnixAddress;
import std.stdio : stderr, writeln;
import std.string : startsWith, toStringz;

version (Posix) import core.sys.posix.sys.stat : chmod;

import vibe.http.common : HTTPMethod;
import vibe.http.router : URLRouter;
import vibe.http.server :
    HTTPServerRequest,
    HTTPServerResponse,
    HTTPServerSettings,
    listenHTTP;
import vibe.vibe : runApplication;

import wheatley.common.api.session : SessionKey;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.run_profile : loadRunProfile, runProfilePath, runProfileValue;
import wheatley.server.api.http.json_response : handleJson;
import wheatley.server.codex.service :
    CodexSessionService,
    codexMessageResultJson,
    codexStatusResultJson;

int main(string[] args)
{
    try {
        auto config = parseWorkerArgs(args);
        enforce(config.codexWorkspaceRoot.length, "Codex workspace root is not configured");
        enforce(config.codexSocket.length, "Codex worker socket is not configured");
        mkdirRecurse(dirName(config.codexSocket));
        if (exists(config.codexSocket)) {
            enforce(!unixSocketAccepting(config.codexSocket),
                "Another Codex worker is already listening on " ~ config.codexSocket);
            remove(config.codexSocket);
        }

        auto service = new CodexSessionService(config.codexWorkspaceRoot);
        scope(exit) {
            service.shutdown();
            if (exists(config.codexSocket)) remove(config.codexSocket);
        }
        service.start();
        service.reconcileAssociations(config.profilesRoot);

        auto router = new URLRouter;
        router.get("/v1/health", (req, res) {
            res.writeBody(`{"ok":true}`, "application/json; charset=UTF-8");
        });
        router.match(HTTPMethod.POST, "/v1/message", route((req, res) {
            handleJson(res, "", {
                auto payload = Json.bodyObject(req);
                auto session = SessionKey(
                    payload.text("profile_id"),
                    payload.text("session_id"),
                );
                auto sessionRoot = checkedSessionRoot(
                    payload.text("session_root"),
                    config.profilesRoot,
                );
                return codexMessageResultJson(service.message(
                    session,
                    sessionRoot,
                    payload.text("pi_turn_id"),
                    payload.text("message"),
                ));
            });
        }));
        router.match(HTTPMethod.POST, "/v1/status", route((req, res) {
            handleJson(res, "", {
                auto payload = Json.bodyObject(req);
                auto session = SessionKey(
                    payload.text("profile_id"),
                    payload.text("session_id"),
                );
                auto sessionRoot = checkedSessionRoot(
                    payload.text("session_root"),
                    config.profilesRoot,
                );
                return codexStatusResultJson(service.status(session, sessionRoot));
            });
        }));

        auto settings = new HTTPServerSettings;
        settings.bindAddresses = [config.codexSocket];
        settings.maxRequestSize = 64 * 1024;
        listenHTTP(settings, router);
        version (Posix) enforce(
            chmod(config.codexSocket.toStringz(), 0x180) == 0,
            "Could not restrict Codex worker socket permissions",
        );
        string[] vibeArgs = [args.length ? args[0] : "wheatley-codexd"];
        return runApplication(&vibeArgs);
    } catch (Exception error) {
        stderr.writeln("wheatley-codexd: ", error.msg);
        return 1;
    }
}

private struct CodexWorkerConfig
{
    string profilesRoot;
    string codexWorkspaceRoot;
    string codexSocket;
}

private CodexWorkerConfig parseWorkerArgs(string[] args)
{
    enforce(args.length == 2, "wheatley-codexd requires one JSON run-profile path");
    auto profile = loadRunProfile(args[1]);
    auto server = Json.object(profile.section("server"), "server");
    auto profilesRoot = resolvedWorkerPath(server, "profiles_root", profile.directory);
    auto workspaceRoot = resolvedWorkerPath(
        server,
        "codex_workspace_root",
        profile.directory,
    );
    auto socketPath = resolvedWorkerPath(server, "codex_socket", profile.directory);
    enforce(profilesRoot.length && exists(profilesRoot) && isDir(profilesRoot),
        "Profiles root does not exist: " ~ profilesRoot);
    enforce(workspaceRoot.length && exists(workspaceRoot) && isDir(workspaceRoot),
        "Codex workspace root does not exist: " ~ workspaceRoot);
    enforce(socketPath.length, "Codex worker socket is not configured");
    return CodexWorkerConfig(profilesRoot, workspaceRoot, socketPath);
}

private string resolvedWorkerPath(Json section, string name, string directory)
{
    auto value = runProfileValue(section.text(name));
    return value.length ? runProfilePath(value, directory) : "";
}

private bool unixSocketAccepting(string path)
{
    auto socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    scope(exit) socket.close();
    try {
        socket.connect(new UnixAddress(path));
        return true;
    } catch (Exception) {
        return false;
    }
}

private auto route(void delegate(HTTPServerRequest req, HTTPServerResponse res) handler)
{
    import vibe.http.server : HTTPServerRequestDelegate;
    return cast(HTTPServerRequestDelegate) handler;
}

private string checkedSessionRoot(string value, string profilesRoot)
{
    auto root = absolutePath(buildNormalizedPath(value));
    auto profiles = absolutePath(buildNormalizedPath(profilesRoot));
    enforce(root.startsWith(profiles ~ "/"), "Codex session root is outside profiles root");
    enforce(exists(root), "Wheatley session not found");
    return root;
}
