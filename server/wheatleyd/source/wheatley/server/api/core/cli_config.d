module wheatley.server.api.core.cli_config;

import std.exception : enforce;
import std.file : exists, isDir, isFile, mkdirRecurse;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;

import wheatley.common.json.read : Json;
import wheatley.common.runtime.run_profile : loadRunProfile, runProfilePath, runProfileValue;
import wheatley.common.runtime.deployment :
    parseDeploymentComposition,
    validateDeploymentComposition;
import wheatley.common.runtime.conversation_placement :
    parseConversationPlacement,
    validateConversationPlacement;
import wheatley.server.api.core.config : ServerConfig;

ServerConfig parseArgs(string[] args)
{
    if (args.length == 2 && (args[1] == "--help" || args[1] == "-h")) {
        printHelp();
        throw new Exception("help requested");
    }
    enforce(args.length == 2, "wheatleyd requires exactly one JSON run-profile path");

    auto profile = loadRunProfile(args[1]);
    auto sharedSection = Json.object(profile.section("shared"), "shared");
    auto server = Json.object(profile.section("server"), "server");
    auto api = sharedSection.object("api");
    auto appDataRoot = runProfilePath(
        sharedSection.text("app_data_root"),
        profile.directory,
    );
    auto resourcesRoot = buildPath(appDataRoot, "resources");
    auto configPath = runProfilePath(server.text("config"), profile.directory);
    auto profilesRoot = runProfilePath(server.text("profiles_root"), profile.directory);
    auto codexWorkspaceRoot = resolvedPath(server, "codex_workspace_root", profile.directory);
    auto codexSocket = resolvedPath(server, "codex_socket", profile.directory);
    auto listenHost = runProfileValue(api.text("listen_host"));
    auto port = cast(ushort) api.integer("port", 1, ushort.max);
    auto corsOrigin = runProfileValue(server.text("cors_origin"));
    auto deployment = server.object("deployment");
    auto deploymentComposition = parseDeploymentComposition(
        deployment.text("composition"),
    );
    auto conversation = server.object("conversation");
    auto conversationPlacement = parseConversationPlacement(
        conversation.text("placement"),
    );
    auto conversationRemoteApiBase = runProfileValue(conversation.text("remote_api_base"));
    auto sync = server.object("sync");
    auto syncUpstreamApiBase = runProfileValue(sync.text("upstream_api_base"));
    auto syncIntervalSeconds = sync.positiveInt("interval_seconds");
    validateDeploymentComposition(deploymentComposition, syncUpstreamApiBase);
    validateConversationPlacement(
        conversationPlacement,
        deploymentComposition,
        conversationRemoteApiBase,
        syncUpstreamApiBase,
    );

    mkdirRecurse(appDataRoot);
    enforce(exists(resourcesRoot) && isDir(resourcesRoot),
        "Resources root does not exist: " ~ resourcesRoot);
    enforce(exists(configPath) && isFile(configPath),
        "Config file does not exist: " ~ configPath);
    enforce(exists(profilesRoot) && isDir(profilesRoot),
        "Profiles root does not exist: " ~ profilesRoot);
    if (codexWorkspaceRoot.length) {
        enforce(exists(codexWorkspaceRoot) && isDir(codexWorkspaceRoot),
            "Codex workspace root does not exist: " ~ codexWorkspaceRoot);
    }
    enforce(!codexWorkspaceRoot.length || codexSocket.length,
        "Codex socket is required when Codex is enabled");
    return ServerConfig(
        appDataRoot,
        resourcesRoot,
        configPath,
        profilesRoot,
        codexWorkspaceRoot,
        codexSocket,
        listenHost,
        port,
        corsOrigin,
        deploymentComposition,
        conversationPlacement,
        conversationRemoteApiBase,
        syncUpstreamApiBase,
        syncIntervalSeconds,
    );
}

private string resolvedPath(
    Json section,
    string name,
    string directory,
)
{
    auto value = runProfileValue(section.text(name));
    return value.length ? runProfilePath(value, directory) : "";
}

private void printHelp()
{
    writeln("Usage: wheatleyd RUN_PROFILE.json");
}
