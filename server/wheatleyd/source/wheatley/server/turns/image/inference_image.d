module wheatley.server.turns.image.inference_image;

import std.algorithm : canFind;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getSize;

import wheatley.common.runtime.local_tools : resolveBundledExecutable;
import wheatley.common.runtime.process_runner : enforceProcessOk, runLocalProcess;
import wheatley.common.runtime.temp_files : removeQuietly, runtimeOwnerRoot, temporaryRuntimeFile;
import wheatley.server.api.core.config : ServerConfig;

struct InferenceImage
{
    string path;
    string mediaType;
    string temporaryPath;

    void removeTemporary()
    {
        removeQuietly(temporaryPath);
        temporaryPath = "";
    }
}

InferenceImage prepareInferenceImage(
    ServerConfig config,
    string turnId,
    string originalPath,
    string originalMediaType,
    long longEdgePx,
)
{
    enforce(exists(originalPath), "Original inference image does not exist");
    enforce(longEdgePx >= 0 && longEdgePx <= 8192, "Inference image long edge is out of range");
    if (longEdgePx == 0) return InferenceImage(originalPath, originalMediaType, "");

    auto outputPath = temporaryRuntimeFile(
        config.appDataRoot,
        "wheatleyd",
        "image-inference",
        turnId,
        ".jpg",
    );
    scope(failure) removeQuietly(outputPath);
    auto ffmpeg = resolveBundledExecutable("ffmpeg", "ffmpeg binary", config.appDataRoot);
    auto result = runLocalProcess(
        inferenceImageCommand(ffmpeg, originalPath, outputPath, longEdgePx),
        "",
        runtimeOwnerRoot(config.appDataRoot, "wheatleyd"),
        30.0,
    );
    enforceProcessOk(result, "inference image resize");
    enforce(exists(outputPath) && getSize(outputPath) > 0,
        "ffmpeg did not create an inference image");
    return InferenceImage(outputPath, "image/jpeg", outputPath);
}

private string[] inferenceImageCommand(
    string ffmpeg,
    string inputPath,
    string outputPath,
    long longEdgePx,
)
{
    enforce(ffmpeg.length, "ffmpeg binary is required");
    enforce(inputPath.length, "Inference image input is required");
    enforce(outputPath.length, "Inference image output is required");
    enforce(longEdgePx > 0, "Inference image long edge must be positive");
    auto edge = longEdgePx.to!string;
    auto scale = "scale=min(" ~ edge ~ "\\,iw):min(" ~ edge
        ~ "\\,ih):force_original_aspect_ratio=decrease,format=yuvj420p";
    return [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-i", inputPath,
        "-map", "0:v:0",
        "-frames:v", "1",
        "-an",
        "-vf", scale,
        "-q:v", "3",
        "-map_metadata", "-1",
        outputPath,
    ];
}

unittest
{
    auto command = inferenceImageCommand("ffmpeg", "original.png", "inference.jpg", 1024);
    assert(command[0] == "ffmpeg");
    assert(command[$ - 1] == "inference.jpg");
    assert(command.canFind("scale=min(1024\\,iw):min(1024\\,ih):force_original_aspect_ratio=decrease,format=yuvj420p"));
}
