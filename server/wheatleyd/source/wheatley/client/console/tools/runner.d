module wheatley.client.console.tools.runner;

import core.time : MonoTime, dur;
import std.algorithm : canFind, max;
import std.array : Appender, appender;
import std.conv : to;
import std.exception : enforce;
import std.file : copy, exists, getSize, mkdirRecurse, read, write;
import std.json : JSONValue, parseJSON;
import std.math : round;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName;
import std.process : environment;
import std.string : replace, split, strip;
import std.uuid : randomUUID;

import vibe.core.core : sleep;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.client.console.audio.chimes :
    ConsoleListeningChimes,
    playCaptureChime;
import wheatley.client.console.config : ConsoleConfig;
import wheatley.client.console.ui.output : writeError, writeNotice, writeTurn;
import wheatley.common.json.object :
    json,
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.api.client_tools :
    ClientToolAdvertisement,
    ClientToolRequest,
    ClientToolResultCreate,
    clientToolRequestsFromJson,
    clientToolUploadedArtifactJson;
import wheatley.common.runtime.process_runner :
    LocalProcessResult,
    findExecutableOnPath,
    runLocalProcess;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.json.read : Json;

int runConsoleClientTools(
    ConsoleApiClient client,
    ConsoleConfig config,
    bool delegate() keepRunning = null,
)
{
    auto clientId = config.deviceId;
    advertise(client, config, clientId);
    writeTurn("client-tools", "advertised " ~ clientId ~ " for " ~ config.profileId, "green");

    auto idleStart = MonoTime.currTime;
    auto nextAdvertisement = MonoTime.currTime + dur!"seconds"(30);
    while (keepRunning is null || keepRunning()) {
        if (MonoTime.currTime >= nextAdvertisement) {
            advertise(client, config, clientId);
            nextAdvertisement = MonoTime.currTime + dur!"seconds"(30);
        }
        auto request = nextPendingRequest(client, config.profileId, clientId);
        if (request.requestId.length) {
            idleStart = MonoTime.currTime;
            handleRequest(client, config, clientId, request);
            if (config.clientToolsOnce) return 0;
        } else if (config.clientToolsOnce && idleTimedOut(idleStart, config.clientToolsIdleTimeoutSeconds)) {
            writeNotice("client-tools: no pending request", "yellow");
            return 0;
        }
        sleep(dur!"msecs"(config.clientToolsPollMs));
    }
    return 0;
}

private void advertise(ConsoleApiClient client, ConsoleConfig config, string clientId)
{
    client.advertiseClientTools(config.profileId, ClientToolAdvertisement(
        clientId,
        config.deviceId,
        "Wheatley console client",
        clientCapabilitiesJson(config.clientToolsDryRun),
        clientMetadataJson(config),
    ));
}

private ClientToolRequest nextPendingRequest(ConsoleApiClient client, string profileId, string clientId)
{
    auto requests = clientToolRequestsFromJson(parseJSON(client.pendingClientToolRequests(profileId, clientId)));
    return requests.length ? requests[0] : ClientToolRequest();
}

private void handleRequest(
    ConsoleApiClient client,
    ConsoleConfig config,
    string clientId,
    ClientToolRequest request,
)
{
    writeTurn("client-tools", "executing " ~ request.capability ~ " for " ~ request.requestId, "green");

    ClientToolExecution execution;
    try {
        execution = executeCapability(client, config, request);
    } catch (Exception error) {
        execution = ClientToolExecution(
            false,
            jsonTextContent("Client tool failed: " ~ error.msg),
            "[]",
            jsonObject([
                jsonStringField("code", "client_tool_failed"),
                jsonStringField("message", error.msg),
            ]),
        );
    }

    client.completeClientToolRequest(config.profileId, request.requestId, ClientToolResultCreate(
        clientId,
        execution.ok,
        execution.contentJson,
        execution.artifactsJson,
        execution.errorJson,
    ));
    writeTurn(
        "client-tools",
        execution.ok ? "completed " ~ request.requestId : "failed " ~ request.requestId,
        execution.ok ? "green" : "red",
    );
}

private struct ClientToolExecution
{
    bool ok;
    string contentJson;
    string artifactsJson;
    string errorJson;
}

private ClientToolExecution executeCapability(
    ConsoleApiClient client,
    ConsoleConfig config,
    ClientToolRequest request,
)
{
    if (request.capability == "capture_photo") {
        return capturePhoto(client, config, request);
    }
    if (request.capability == "capture_screen") {
        return captureScreen(client, config, request);
    }
    return ClientToolExecution(
        false,
        jsonTextContent("Unsupported client capability: " ~ request.capability),
        "[]",
        jsonObject([
            jsonStringField("code", "unsupported_capability"),
            jsonStringField("message", "Unsupported client capability: " ~ request.capability),
        ]),
    );
}

private ClientToolExecution capturePhoto(ConsoleApiClient client, ConsoleConfig config, ClientToolRequest request)
{
    auto artifactId = "client-photo-" ~ safeFileToken(request.requestId);
    auto targetPath = photoTargetPath(config, artifactId);
    auto mimeType = config.clientToolsDryRun ? "text/plain" : "image/jpeg";
    mkdirRecurse(dirName(targetPath));

    if (config.clientToolsDryRun) {
        write(targetPath, "dry-run capture_photo artifact for " ~ request.requestId ~ "\n");
    } else {
        auto attempts = appender!string;
        foreach (command; capturePhotoCommands(targetPath)) {
            auto result = runLocalProcess(command, "", "", capturePhotoTimeoutSeconds(), 64 * 1024);
            if (result.status == 0 && !result.timedOut && captureOutputReady(targetPath)) {
                attempts = appender!string;
                break;
            }
            appendCaptureAttempt(attempts, command, result, targetPath);
        }
        if (attempts.data.length) {
            auto message = "Photo capture failed after trying available client capture commands.";
            return ClientToolExecution(
                false,
                jsonTextContent(message),
                "[]",
                jsonObject([
                    jsonStringField("code", "capture_failed"),
                    jsonStringField("message", message),
                    jsonRawField("attempts", "[" ~ attempts.data ~ "]"),
                ]),
            );
        }
    }

    playClientCaptureChime(config);
    auto uploadResponse = parseJSON(client.uploadClientToolArtifact(
        config.profileId,
        request.requestId,
        targetPath,
        artifactId,
        "image",
        mimeType,
    ));
    auto artifactJson = clientToolUploadedArtifactJson(uploadResponse);

    return ClientToolExecution(
        true,
        jsonTextContent("Captured one client photo."),
        "[" ~ artifactJson ~ "]",
        "null",
    );
}

private ClientToolExecution captureScreen(
    ConsoleApiClient client,
    ConsoleConfig config,
    ClientToolRequest request,
)
{
    auto arguments = Json.parse(request.argumentsJson);
    auto captureScope = arguments.choice!("active_window", "active_display")("scope");
    auto maxLongEdge = arguments.positiveInt("model_max_long_edge_px");
    auto modelPixelsPerLogicalPixel = arguments.number(
        "model_pixels_per_logical_pixel",
        0.01,
        4,
    );
    auto artifactId = "screen-capture-" ~ safeFileToken(request.requestId);
    auto fullPath = screenTargetPath(config, artifactId, "full");
    mkdirRecurse(dirName(fullPath));

    captureScreenPng(config, captureScope, fullPath);
    auto size = pngSize(fullPath);
    auto uiScale = screenUiScale(config, captureScope);
    auto modelLongEdge = cast(long) (
        cast(double) max(size.width, size.height)
        * modelPixelsPerLogicalPixel
        / uiScale
    );
    if (modelLongEdge > maxLongEdge) modelLongEdge = maxLongEdge;
    auto modelSize = scaledScreenSize(size, modelLongEdge);

    playClientCaptureChime(config);
    auto fullArtifact = clientToolUploadedArtifactJson(parseJSON(client.uploadClientToolArtifact(
        config.profileId,
        request.requestId,
        fullPath,
        artifactId,
        "screen_capture",
        "image/png",
    )));
    auto details = appendArtifactFields(
        fullArtifact,
        size,
        modelSize,
        captureScope,
        uiScale,
    );
    return ClientToolExecution(
        true,
        jsonTextContent("Captured the requested screen."),
        "[" ~ details ~ "]",
        "null",
    );
}

private void captureScreenPng(ConsoleConfig config, string captureScope, string targetPath)
{
    if (config.clientToolsDryRun) {
        auto ffmpeg = resolveBundledExecutable("ffmpeg", "ffmpeg binary", config.appDataRoot);
        requireSuccessfulCapture([
            ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "color=c=0x334155:s=640x400",
            "-frames:v", "1", "-update", "1", targetPath,
        ], targetPath, "dry-run screen capture");
        return;
    }
    auto configured = environment.get("WHEATLEY_CAPTURE_SCREEN_COMMAND", "").strip;
    if (configured.length) {
        auto command = configured
            .replace("{output}", shellQuote(targetPath))
            .replace("{scope}", shellQuote(captureScope));
        requireSuccessfulCapture(["sh", "-lc", command], targetPath, "configured screen capture");
        return;
    }
    version (OSX) {
        auto screencapture = "/usr/sbin/screencapture";
        auto target = foregroundMacScreenTarget();
        if (captureScope == "active_display") {
            requireSuccessfulCapture(
                [screencapture, "-x", "-D", target.displayIndex, "-t", "png", targetPath],
                targetPath,
                "active display capture",
            );
            return;
        }
        requireSuccessfulCapture(
            [screencapture, "-x", "-o", "-l", target.windowId, "-t", "png", targetPath],
            targetPath,
            "foreground window capture",
        );
        return;
    }
    version (Windows) {
        auto powershell = findExecutableOnPath("powershell.exe");
        if (!powershell.length)
            throw new Exception("PowerShell is required for Windows screen capture.");
        requireSuccessfulCapture([
            powershell,
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-Command", windowsCaptureScript,
            captureScope,
            targetPath,
        ], targetPath, "Windows screen capture");
        return;
    }
    throw new Exception(
        "Native screen capture is unavailable on this platform. Set WHEATLEY_CAPTURE_SCREEN_COMMAND.",
    );
}

version (OSX) {
private struct MacScreenTarget
{
    string windowId;
    string displayIndex;
    double uiScale;
}

private MacScreenTarget foregroundMacScreenTarget()
{
    auto swift = findExecutableOnPath("swift");
    if (!swift.length) throw new Exception("Swift is required to identify the foreground macOS window.");
    enum source = `import AppKit; import CoreGraphics
guard let app = NSWorkspace.shared.frontmostApplication else { exit(2) }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
guard let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }), let number = window[kCGWindowNumber as String] as? Int, let dictionary = window[kCGWindowBounds as String] as? CFDictionary, let bounds = CGRect(dictionaryRepresentation: dictionary) else { exit(3) }
let candidates = NSScreen.screens.enumerated().compactMap { index, screen -> (Int, NSScreen, CGFloat)? in
    guard let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
    let overlap = CGDisplayBounds(CGDirectDisplayID(raw)).intersection(bounds)
    return (index, screen, max(0, overlap.width) * max(0, overlap.height))
}
guard let target = candidates.max(by: { $0.2 < $1.2 }), target.2 > 0 else { exit(4) }
print("\(number)|\(target.0 + 1)|\(target.1.backingScaleFactor)")`;
    auto result = runLocalProcess([swift, "-e", source], "", "", 15, 16 * 1024);
    auto fields = result.output.strip.split("|");
    if (result.status != 0 || result.timedOut || fields.length != 3)
        throw new Exception("Could not identify the foreground macOS window and display.");
    auto scale = fields[2].to!double;
    if (scale < 1.0 || scale > 4.0)
        throw new Exception("Foreground macOS display scale is invalid.");
    return MacScreenTarget(fields[0], fields[1], scale);
}
}

private double screenUiScale(ConsoleConfig config, string captureScope)
{
    if (config.clientToolsDryRun) return 1.0;
    version (OSX) {
        return foregroundMacScreenTarget().uiScale;
    }
    version (Windows) {
        auto powershell = findExecutableOnPath("powershell.exe");
        if (powershell.length) {
            auto result = runLocalProcess([
                powershell,
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy", "Bypass",
                "-Command", windowsUiScaleScript,
                captureScope,
            ], "", "", 15, 4096);
            if (result.status == 0 && !result.timedOut) {
                try {
                    auto value = result.output.strip.to!double;
                    if (value >= 1.0 && value <= 4.0) return value;
                } catch (Exception) {}
            }
        }
    }
    return 1.0;
}

version (Windows) {
    enum windowsCaptureScript = `
param([string]$scope, [string]$output)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WheatleyScreenCaptureWin32 {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
}
'@
$window = [WheatleyScreenCaptureWin32]::GetForegroundWindow()
if ($window -eq [IntPtr]::Zero) { throw 'No foreground window is available.' }
if ($scope -eq 'active_window') {
    $bounds = New-Object WheatleyScreenCaptureWin32+Rect
    if (-not [WheatleyScreenCaptureWin32]::GetWindowRect($window, [ref]$bounds)) { throw 'Could not read foreground window bounds.' }
} else {
    $monitor = [WheatleyScreenCaptureWin32]::MonitorFromWindow($window, 2)
    $info = New-Object WheatleyScreenCaptureWin32+MonitorInfo
    $info.Size = [Runtime.InteropServices.Marshal]::SizeOf($info)
    if (-not [WheatleyScreenCaptureWin32]::GetMonitorInfo($monitor, [ref]$info)) { throw 'Could not read active display bounds.' }
    $bounds = $info.Monitor
}
$width = $bounds.Right - $bounds.Left
$height = $bounds.Bottom - $bounds.Top
if ($width -le 0 -or $height -le 0) { throw 'Screen capture bounds are empty.' }
$bitmap = New-Object Drawing.Bitmap $width, $height
$graphics = [Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($output, [Drawing.Imaging.ImageFormat]::Png)
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}
`;

    enum windowsUiScaleScript = `
param([string]$scope)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WheatleyScreenDpiWin32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
}
'@
$window = [WheatleyScreenDpiWin32]::GetForegroundWindow()
if ($window -eq [IntPtr]::Zero) { throw 'No foreground window is available.' }
$dpi = [WheatleyScreenDpiWin32]::GetDpiForWindow($window)
if ($dpi -le 0) { throw 'Could not read foreground window DPI.' }
[Console]::Write(($dpi / 96.0).ToString([Globalization.CultureInfo]::InvariantCulture))
`;
}

private struct PngSize { long width; long height; }

private PngSize scaledScreenSize(PngSize full, long longEdge)
{
    auto fullLongEdge = max(full.width, full.height);
    if (longEdge >= fullLongEdge) return full;
    enforce(longEdge > 0, "Screen capture model long edge must be positive");
    if (full.width >= full.height) return PngSize(
        longEdge,
        max(1L, cast(long) round(cast(double) full.height * longEdge / full.width)),
    );
    return PngSize(
        max(1L, cast(long) round(cast(double) full.width * longEdge / full.height)),
        longEdge,
    );
}

private PngSize pngSize(string path)
{
    auto bytes = cast(ubyte[]) read(path);
    if (bytes.length < 24 || bytes[0 .. 8] != cast(ubyte[]) [137,80,78,71,13,10,26,10])
        throw new Exception("Screen capture is not a valid PNG.");
    return PngSize(bigEndianUint(bytes, 16), bigEndianUint(bytes, 20));
}

private long bigEndianUint(ubyte[] bytes, size_t offset)
{
    return (cast(long) bytes[offset] << 24)
        | (cast(long) bytes[offset + 1] << 16)
        | (cast(long) bytes[offset + 2] << 8)
        | cast(long) bytes[offset + 3];
}

private string appendArtifactFields(
    string artifact,
    PngSize size,
    PngSize modelSize,
    string captureScope,
    double uiScale,
)
{
    return artifact[0 .. $ - 1] ~ ","
        ~ jsonStringField("kind", "screen_capture") ~ ","
        ~ jsonLongField("width", size.width) ~ ","
        ~ jsonLongField("height", size.height) ~ ","
        ~ jsonStringField("scope", captureScope) ~ ","
        ~ `"ui_scale":` ~ uiScale.to!string ~ ","
        ~ jsonLongField("model_width", modelSize.width) ~ ","
        ~ jsonLongField("model_height", modelSize.height) ~ "}";
}

private void requireSuccessfulCapture(string[] command, string path, string label)
{
    auto result = runLocalProcess(command, "", "", 30, 64 * 1024);
    if (result.status != 0 || result.timedOut || !captureOutputReady(path))
        throw new Exception(label ~ " failed: " ~ result.output.strip);
}

private void playClientCaptureChime(ConsoleConfig config) nothrow
{
    playCaptureChime(ConsoleListeningChimes(
        config.appDataRoot,
        config.resourcesRoot,
        config.ttsPlaybackCommand,
    ));
}

private string[][] capturePhotoCommands(string targetPath)
{
    auto configured = environment.get("WHEATLEY_CAPTURE_PHOTO_COMMAND", "").strip;
    if (configured.length) {
        auto command = configured.replace("{output}", shellQuote(targetPath));
        return [["sh", "-lc", command]];
    }

    auto imagesnap = findExecutableOnPath("imagesnap");
    if (imagesnap.length) return [[imagesnap, "-q", targetPath]];

    auto ffmpeg = findExecutableOnPath("ffmpeg");
    if (ffmpeg.length) {
        version (OSX) {
            auto input = avfoundationCameraInput();
            return [
                ffmpegCaptureCommand(ffmpeg, input, "1280x720", "30", "", targetPath),
                ffmpegCaptureCommand(ffmpeg, input, "640x480", "30", "", targetPath),
                ffmpegCaptureCommand(ffmpeg, input, "1280x720", "30", "nv12", targetPath),
                ffmpegCaptureCommand(ffmpeg, input, "1280x720", "15", "nv12", targetPath),
                ffmpegCaptureCommand(ffmpeg, input, "640x480", "30", "nv12", targetPath),
                ffmpegCaptureCommand(ffmpeg, input, "640x480", "15", "nv12", targetPath),
                [
                    ffmpeg,
                    "-y",
                    "-hide_banner",
                    "-f", "avfoundation",
                    "-i", input,
                    "-frames:v", "1",
                    "-update", "1",
                    targetPath,
                ],
            ];
        }
    }

    throw new Exception(
        "No photo capture command is available. Set WHEATLEY_CAPTURE_PHOTO_COMMAND or install imagesnap/ffmpeg.",
    );
}

private string[] ffmpegCaptureCommand(
    string ffmpeg,
    string input,
    string videoSize,
    string frameRate,
    string pixelFormat,
    string targetPath,
)
{
    string[] command = [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-f", "avfoundation",
    ];
    if (pixelFormat.length) command ~= ["-pixel_format", pixelFormat];
    command ~= [
        "-framerate",
        frameRate,
        "-video_size",
        videoSize,
        "-i",
        input,
        "-frames:v",
        "1",
        "-update",
        "1",
        targetPath,
    ];
    return command;
}

private string avfoundationCameraInput()
{
    return normalizeAvfoundationInput(environment.get("WHEATLEY_CAMERA_INPUT", "0"));
}

private string normalizeAvfoundationInput(string input)
{
    input = input.strip;
    if (!input.length) input = "0";
    return input.canFind(":") ? input : input ~ ":none";
}

private string clientCapabilitiesJson(bool dryRun)
{
    return "[" ~ jsonObject([
            jsonStringField("name", "capture_photo"),
            jsonStringField("label", "Capture photo"),
            jsonRawField("schema", jsonObject([])),
            jsonRawField("returns", dryRun ? `["text/plain"]` : `["image/jpeg"]`),
        ]) ~ "," ~ jsonObject([
            jsonStringField("name", "capture_screen"),
            jsonStringField("label", "Capture screen"),
            jsonRawField("schema", jsonObject([
                jsonStringField("type", "object"),
                jsonRawField("properties", jsonObject([
                    jsonRawField("scope", jsonObject([
                        jsonStringField("type", "string"),
                        jsonRawField("enum", `["active_window","active_display"]`),
                    ])),
                ])),
            ])),
            jsonRawField("returns", `["image/png"]`),
        ]) ~ "]";
}

private string clientMetadataJson(ConsoleConfig config)
{
    return jsonObject([
        jsonStringField("runner", "wheatley-console-client-tools"),
        jsonBoolField("dry_run", config.clientToolsDryRun),
        jsonStringField("app_data_root", config.appDataRoot),
    ]);
}

private string photoTargetPath(ConsoleConfig config, string artifactId)
{
    return absolutePath(buildNormalizedPath(buildPath(
        config.appDataRoot,
        "console-client",
        "tmp",
        "client-tools",
        "artifacts",
        artifactId ~ (config.clientToolsDryRun ? ".txt" : ".jpg"),
    )));
}

private string screenTargetPath(ConsoleConfig config, string artifactId, string rendition)
{
    return absolutePath(buildNormalizedPath(buildPath(
        config.appDataRoot,
        "console-client",
        "tmp",
        "client-tools",
        "artifacts",
        artifactId ~ "-" ~ rendition ~ ".png",
    )));
}

private bool idleTimedOut(MonoTime idleStart, int timeoutSeconds)
{
    if (timeoutSeconds <= 0) return false;
    return MonoTime.currTime - idleStart >= dur!"seconds"(timeoutSeconds);
}

private string jsonTextContent(string text)
{
    return "[" ~ jsonObject([
        jsonStringField("type", "text"),
        jsonStringField("text", text),
    ]) ~ "]";
}

private string commandJson(string[] command)
{
    auto output = appender!string;
    output.put("[");
    foreach (index, part; command) {
        if (index) output.put(",");
        output.put(json(part));
    }
    output.put("]");
    return output.data;
}

private void appendCaptureAttempt(
    ref Appender!string attempts,
    string[] command,
    LocalProcessResult result,
    string targetPath,
)
{
    long byteCount;
    auto hasOutputFile = captureOutputFileBytes(targetPath, byteCount);
    if (attempts.data.length) attempts.put(",");
    attempts.put(jsonObject([
        jsonRawField("command", commandJson(command)),
        jsonLongField("status", result.status),
        jsonBoolField("timed_out", result.timedOut),
        jsonBoolField("output_truncated", result.outputTruncated),
        jsonBoolField("output_file_exists", hasOutputFile),
        jsonLongField("output_file_bytes", byteCount),
        jsonStringField("output", limitText(result.output.strip, 4_000)),
    ]));
}

private double capturePhotoTimeoutSeconds()
{
    auto text = environment.get("WHEATLEY_CAPTURE_PHOTO_TIMEOUT_SECONDS", "").strip;
    if (!text.length) return 8.0;
    try {
        auto seconds = text.to!double;
        if (seconds > 0) return seconds;
    } catch (Exception) {
    }
    return 8.0;
}

private bool captureOutputReady(string targetPath)
{
    long byteCount;
    return captureOutputFileBytes(targetPath, byteCount) && byteCount > 0;
}

private bool captureOutputFileBytes(string targetPath, out long byteCount)
{
    byteCount = 0;
    if (!exists(targetPath)) return false;
    try {
        byteCount = cast(long) getSize(targetPath);
        return true;
    } catch (Exception) {
        return false;
    }
}

private string limitText(string text, size_t maxBytes)
{
    if (text.length <= maxBytes) return text;
    return text[0 .. maxBytes] ~ "\n[truncated]";
}

private string shellQuote(string value)
{
    return "'" ~ value.replace("'", "'\"'\"'") ~ "'";
}

private string safeFileToken(string value)
{
    auto output = appender!string;
    foreach (ch; value) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            output.put(ch);
        } else if (ch == '-' || ch == '_' || ch == '.') {
            output.put(ch);
        } else {
            output.put("-");
        }
    }
    auto result = output.data.strip;
    return result.length ? result : randomUUID().toString();
}
