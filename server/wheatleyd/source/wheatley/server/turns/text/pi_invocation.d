module wheatley.server.turns.text.pi_invocation;

import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, isDir, isFile, readText;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.string : strip;

import wheatley.server.api.core.config : ServerConfig;
import wheatley.common.api.reasoning : ReasoningMode, piThinkingLevel, reasoningModeText;
import wheatley.common.api.session : SessionKey;
import wheatley.common.json.object : jsonLongField, jsonObject, jsonRawField, jsonStringField;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.json : writeJsonFile, writeTextFile;
import wheatley.server.turns.text.pi_runtime : piSessionId, resolvePiExecutable;
import wheatley.server.turns.text.profile_runtime_settings :
    ProfileRuntimeSettings,
    enabledPiToolNames;
import wheatley.common.runtime.now_iso : nowIso;

struct PiInvocationRuntime
{
    string workingRoot;
    string workspaceFile;
    string sessionDate;
    string sessionFolder;
    string sessionDir;
    string extensionPath;
    string webExtensionPath;
    string sessionId;
    string turnContextPath;
}

PiInvocationRuntime preparePiInvocationRuntime(
    ServerConfig config,
    HistoryStore store,
    SessionKey session,
)
{
    auto workingRoot = store.sessionPiWorkingRoot(session);
    if (!workingRoot.length) workingRoot = store.profileWorkspaceRoot(session.profileId);
    workingRoot = absolutePath(buildNormalizedPath(workingRoot));
    enforce(exists(workingRoot) && isDir(workingRoot),
        "Pi working root does not exist: " ~ workingRoot);
    auto workspaceFile = loadWorkspaceFile(workingRoot);

    auto sessionFolder = store.sessionFolder(session);
    auto sessionDate = store.sessionDate(session);
    auto sessionDir = store.sessionRuntimeRoot(session);
    auto extensionPath = requiredFile(buildPath(
        config.resourcesRoot,
        "pi",
        "extensions",
        "wheatley-tools.ts",
    ));
    auto webExtensionPath = requiredFile(buildPath(
        config.resourcesRoot,
        "pi",
        "node_modules",
        "pi-web-access",
        "index.ts",
    ));

    return PiInvocationRuntime(
        workingRoot,
        workspaceFile,
        sessionDate,
        sessionFolder,
        sessionDir,
        extensionPath,
        webExtensionPath,
        piSessionId(session.profileId, sessionDate, sessionFolder),
        buildPath(sessionDir, ".wheatley-pi-turn.json"),
    );
}

void recordPiInvocationSession(
    HistoryStore store,
    SessionKey session,
    PiInvocationRuntime runtime,
    ProfileRuntimeSettings settings,
)
{
    store.recordPiSession(
        session,
        settings.piModel,
        settings.assistantModel,
        runtime.sessionId,
        runtime.sessionDir,
        runtime.workingRoot,
        runtime.workingRoot,
        runtime.extensionPath,
        nowIso(),
    );
}

string[] piInvocationCommand(
    PiInvocationRuntime runtime,
    ProfileRuntimeSettings settings,
    ReasoningMode reasoningMode,
)
{
    auto executable = resolvePiExecutable(settings.piCommand);
    if (!executable.path.length) throw new Exception(executable.detail);

    auto tools = enabledPiToolNames(settings.tools);
    enforce(tools.length, "Pi tool allowlist is empty");

    auto sessionPath = buildPath(runtime.sessionDir, "pi_session.jsonl");
    auto sessionArguments = exists(sessionPath) && isFile(sessionPath)
        ? ["--session", sessionPath]
        : ["--session-id", runtime.sessionId];

    return [
        executable.path,
        "--mode", "json",
        "--print",
        "--provider", settings.piProvider,
        "--model", settings.piModel,
        "--thinking", piThinkingLevel(reasoningMode),
    ] ~ sessionArguments ~ [
        "--no-context-files",
        "--session-dir", runtime.sessionDir,
        "--name", "wheatley " ~ runtime.sessionDate ~ " " ~ runtime.sessionFolder,
        "--no-extensions",
        "--extension", runtime.extensionPath,
        "--extension", runtime.webExtensionPath,
        "--tools", tools.join(","),
        "--approve",
    ];
}

string[] piWorkerCommand(
    PiInvocationRuntime runtime,
    ProfileRuntimeSettings settings,
    bool scheduledTaskRun = false,
)
{
    auto executable = resolvePiExecutable(settings.piCommand);
    if (!executable.path.length) throw new Exception(executable.detail);

    auto tools = enabledPiToolNames(settings.tools, scheduledTaskRun);
    enforce(tools.length, "Pi tool allowlist is empty");
    ensurePiWorkerSession(runtime);

    return [
        executable.path,
        "--mode", "rpc",
        "--provider", settings.piProvider,
        "--model", settings.piModel,
        "--thinking", "off",
        "--no-context-files",
        "--session", buildPath(runtime.sessionDir, "pi_session.jsonl"),
        "--session-dir", runtime.sessionDir,
        "--name", "wheatley " ~ runtime.sessionDate ~ " " ~ runtime.sessionFolder,
        "--no-extensions",
        "--extension", runtime.extensionPath,
        "--extension", runtime.webExtensionPath,
        "--tools", tools.join(","),
        "--approve",
    ];
}

string[string] piWorkerEnvironment(
    ServerConfig config,
    SessionKey session,
    PiInvocationRuntime runtime,
)
{
    return [
        "WHEATLEY_API_BASE": serverApiBaseUrl(config),
        "WHEATLEY_PROFILE_ID": session.profileId,
        "WHEATLEY_SESSION_ID": session.sessionId,
        "WHEATLEY_TURN_CONTEXT_PATH": runtime.turnContextPath,
    ];
}

string piWorkerFingerprint(
    PiInvocationRuntime runtime,
    ProfileRuntimeSettings settings,
    bool scheduledTaskRun = false,
)
{
    return piWorkerCommand(runtime, settings, scheduledTaskRun).join("\0")
        ~ "\0screen_capture_scope=" ~ settings.screenCaptureScope;
}

void writePiWorkerTurnContext(
    PiInvocationRuntime runtime,
    string turnId,
    ReasoningMode reasoningMode,
    string clientId,
    ProfileRuntimeSettings settings,
    string systemPrompt = "",
)
{
    writeJsonFile(runtime.turnContextPath, jsonObject([
        jsonStringField("turn_id", turnId),
        jsonStringField("model", settings.assistantModel),
        jsonStringField("reasoning_mode", reasoningModeText(reasoningMode)),
        jsonStringField("client_id", clientId),
        jsonStringField("system_prompt", systemPrompt),
        jsonRawField(
            "provider_request",
            settings.providerRequestOverridesJson.length
                ? settings.providerRequestOverridesJson
                : "{}",
        ),
        jsonStringField("screen_capture_scope", settings.screenCaptureScope),
        jsonLongField(
            "screen_capture_model_max_long_edge_px",
            settings.screenCaptureModelMaxLongEdgePx,
        ),
        `"screen_capture_model_pixels_per_logical_pixel":`
            ~ settings.screenCaptureModelPixelsPerLogicalPixel.to!string,
    ]));
}

string[string] piInvocationEnvironment(
    ServerConfig config,
    SessionKey session,
    string turnId,
    ReasoningMode reasoningMode,
    bool promptPrewarm = false,
)
{
    string[string] environment = [
        "WHEATLEY_API_BASE": serverApiBaseUrl(config),
        "WHEATLEY_PROFILE_ID": session.profileId,
        "WHEATLEY_SESSION_ID": session.sessionId,
        "WHEATLEY_TURN_ID": turnId,
        "WHEATLEY_REASONING_MODE": reasoningModeText(reasoningMode),
    ];
    if (promptPrewarm) environment["WHEATLEY_PROMPT_PREWARM"] = "1";
    return environment;
}

private void ensurePiWorkerSession(PiInvocationRuntime runtime)
{
    auto path = buildPath(runtime.sessionDir, "pi_session.jsonl");
    if (exists(path) && isFile(path)) return;
    writeTextFile(path, jsonObject([
        jsonStringField("type", "session"),
        jsonLongField("version", 3),
        jsonStringField("id", runtime.sessionId),
        jsonStringField("timestamp", nowIso()),
        jsonStringField("cwd", runtime.workingRoot),
    ]) ~ "\n");
}

private string loadWorkspaceFile(string workingRoot)
{
    auto path = buildPath(workingRoot, "WHEATLEY.md");
    if (!exists(path)) return "";
    enforce(isFile(path), "Workspace WHEATLEY.md is not a file: " ~ path);
    return readText(path).strip;
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-workspace-file-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);

    assert(loadWorkspaceFile(root).length == 0);
    write(buildPath(root, "WHEATLEY.md"), "\n# Workspace instructions\n");
    assert(loadWorkspaceFile(root) == "# Workspace instructions");
}

private string requiredFile(string path)
{
    enforce(exists(path) && isFile(path), "Required Pi file is missing: " ~ path);
    return path;
}

private string serverApiBaseUrl(ServerConfig config)
{
    auto host = config.host;
    if (host == "0.0.0.0" || host == "::") host = "127.0.0.1";
    return "http://" ~ host ~ ":" ~ config.port.to!string ~ "/api";
}
