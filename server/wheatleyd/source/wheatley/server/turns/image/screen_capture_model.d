module wheatley.server.turns.image.screen_capture_model;

import std.algorithm : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getSize, read;

import wheatley.common.api.generated_image : GeneratedImageArtifact;
import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.process_runner : enforceProcessOk, runLocalProcess;
import wheatley.common.runtime.temp_files :
    removeQuietly,
    runtimeOwnerRoot,
    temporaryRuntimeFile;
import wheatley.server.api.core.config : ServerConfig;

ubyte[] renderScreenCaptureModel(ServerConfig config, GeneratedImageArtifact capture)
{
    enforce(capture.kind == "screen_capture", "Artifact is not a screen capture");
    enforce(capture.modelWidth > 0 && capture.modelHeight > 0,
        "Screen capture has no model dimensions");
    enforce(capture.modelWidth < capture.width && capture.modelHeight < capture.height,
        "Screen capture was not reduced for the model");
    enforce(exists(capture.path), "Screen capture does not exist");

    auto outputPath = temporaryRuntimeFile(
        config.appDataRoot,
        "wheatleyd",
        "screen-capture-model",
        capture.sha256[0 .. 16],
        ".png",
    );
    scope(exit) removeQuietly(outputPath);
    auto ffmpeg = resolveBundledExecutable("ffmpeg", "ffmpeg binary", config.appDataRoot);
    auto result = runLocalProcess(
        screenCaptureModelCommand(
            ffmpeg,
            capture.path,
            outputPath,
            capture.modelWidth,
            capture.modelHeight,
        ),
        "",
        runtimeOwnerRoot(config.appDataRoot, "wheatleyd"),
        30.0,
    );
    enforceProcessOk(result, "screen capture model resize");
    enforce(exists(outputPath) && getSize(outputPath) > 0,
        "Screen capture model resize produced no PNG");
    auto png = cast(ubyte[]) read(outputPath);
    enforce(pngDimensions(png) == [capture.modelWidth, capture.modelHeight],
        "Screen capture model dimensions changed");
    return png;
}

private string[] screenCaptureModelCommand(
    string ffmpeg,
    string inputPath,
    string outputPath,
    long width,
    long height,
)
{
    enforce(ffmpeg.length && inputPath.length && outputPath.length,
        "Screen capture model command paths are required");
    enforce(width > 0 && height > 0, "Screen capture model dimensions must be positive");
    return [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-i", inputPath,
        "-map", "0:v:0",
        "-frames:v", "1",
        "-an",
        "-vf", "scale=" ~ width.to!string ~ ":" ~ height.to!string ~ ":flags=lanczos",
        "-map_metadata", "-1",
        outputPath,
    ];
}

private long[2] pngDimensions(scope const ubyte[] bytes)
{
    immutable ubyte[] signature = [137, 80, 78, 71, 13, 10, 26, 10];
    enforce(bytes.length >= 24 && bytes[0 .. 8] == signature,
        "Screen capture model is not a PNG");
    return [bigEndian(bytes[16 .. 20]), bigEndian(bytes[20 .. 24])];
}

private long bigEndian(scope const ubyte[] bytes)
{
    enforce(bytes.length == 4, "PNG dimension field is invalid");
    return (cast(long) bytes[0] << 24)
        | (cast(long) bytes[1] << 16)
        | (cast(long) bytes[2] << 8)
        | cast(long) bytes[3];
}

unittest
{
    auto command = screenCaptureModelCommand("ffmpeg", "full.png", "model.png", 1496, 967);
    assert(command.canFind("scale=1496:967:flags=lanczos"));
}
