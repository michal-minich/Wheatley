module wheatley.server.image_generation.runtime;

import std.conv : to;
import std.digest.sha : sha256Of;
import std.digest : LetterCase, toHexString;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, remove, rename, write;
import std.path : buildPath;
import std.random : Random, unpredictableSeed, uniform;
import std.string : strip;
import std.uri : encodeComponent;
import std.uuid : randomUUID;

import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.api.generated_image :
    GeneratedImageArtifact,
    generatedImageArtifactJson;
import wheatley.common.api.session : SessionKey;
import wheatley.common.json.read : Json;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.json : writeJsonFileAtomic;
import wheatley.server.image_generation.port : ImageGeneratorPort;
import wheatley.server.image_generation.types :
    ImageGenerationConfig,
    ImageGenerationOutput,
    ImageGenerationRequest,
    ImagePreset;

final class ImageGenerationRuntime
{
    private HistoryStore store;
    private ImageGeneratorPort generator;
    private ImageGenerationConfig config;
    private TaskMutex lane;

    this(HistoryStore store, ImageGeneratorPort generator, ImageGenerationConfig config)
    {
        enforce(store !is null, "History store is required for image generation");
        enforce(generator !is null, "Image generator is required");
        this.store = store;
        this.generator = generator;
        this.config = config;
        this.lane = new TaskMutex;
    }

    bool healthy()
    {
        return generator.healthy();
    }

    GeneratedImageArtifact generate(string profileId, Json request)
    {
        auto session = SessionKey(profileId, request.nonEmpty("session_id"));
        auto turnId = request.nonEmpty("turn_id");
        auto prompt = request.nonEmpty("prompt").strip;
        enforce(prompt.length <= 8_000, "Image prompt is too long");
        auto quality = request.opt.textOrEmpty("quality");
        if (!quality.length) quality = "medium";
        enforce(quality == "low" || quality == "medium" || quality == "high",
            "Image quality must be low, medium, or high");
        auto aspect = request.text("aspect");
        enforce(aspect == "square" || aspect == "portrait" || aspect == "landscape",
            "Image aspect must be square, portrait, or landscape");
        auto seedValue = request.opt.integer("seed");
        auto seed = seedValue.isNull ? freshSeed() : seedValue.get;
        enforce(seed >= 0, "Image seed must not be negative");
        auto preset = config.presets[quality ~ "." ~ aspect];

        auto guard = scopedMutexLock(lane);
        auto index = store.nextGeneratedImageIndex(session, turnId);
        auto filename = "generated-" ~ twoDigits(index) ~ ".png";
        auto paths = store.generatedImagePaths(session, turnId, filename);
        auto staging = paths.imagePath ~ ".partial-" ~ randomUUID().toString();
        scope(failure) {
            if (exists(staging)) remove(staging);
            if (exists(paths.metadataPath)) remove(paths.metadataPath);
            if (exists(paths.imagePath)) remove(paths.imagePath);
        }

        auto output = generator.generate(ImageGenerationRequest(
            randomUUID().toString(),
            prompt,
            preset.width,
            preset.height,
            seed,
        ));
        enforceTurnRunning(store, session, turnId);
        auto dimensions = pngDimensions(output.png);
        enforce(dimensions.width == preset.width && dimensions.height == preset.height,
            "Image worker returned unexpected PNG dimensions");
        mkdirRecurse(paths.imagesRoot);
        write(staging, output.png);
        rename(staging, paths.imagePath);

        auto artifact = GeneratedImageArtifact(
            index,
            "generated-image:" ~ index.to!string,
            filename,
            "image/png",
            generatedImageUrl(profileId, turnId, filename, session.sessionId),
            paths.artifactPath,
            toHexString!(LetterCase.lower)(sha256Of(output.png)).idup,
            cast(long) output.png.length,
            preset.width,
            preset.height,
            seed,
            quality,
            aspect,
            prompt,
        );
        writeJsonFileAtomic(paths.metadataPath, generatedImageArtifactJson(artifact));
        enforceTurnRunning(store, session, turnId);
        return artifact;
    }
}

private void enforceTurnRunning(HistoryStore store, SessionKey session, string turnId)
{
    auto turn = store.findTurn(session, turnId);
    enforce(turn.id.length && turn.status == "running",
        "Image generation turn is no longer running");
}

private struct PngDimensions
{
    int width;
    int height;
}

private PngDimensions pngDimensions(scope const ubyte[] bytes)
{
    immutable ubyte[] signature = [137, 80, 78, 71, 13, 10, 26, 10];
    enforce(bytes.length >= 24 && bytes[0 .. 8] == signature, "Image worker returned invalid PNG data");
    enforce(bytes[12 .. 16] == cast(ubyte[]) "IHDR", "PNG is missing IHDR");
    return PngDimensions(bigEndianInt(bytes[16 .. 20]), bigEndianInt(bytes[20 .. 24]));
}

private int bigEndianInt(scope const ubyte[] bytes)
{
    enforce(bytes.length == 4, "PNG dimension field is invalid");
    auto value = (cast(ulong) bytes[0] << 24)
        | (cast(ulong) bytes[1] << 16)
        | (cast(ulong) bytes[2] << 8)
        | bytes[3];
    enforce(value > 0 && value <= int.max, "PNG dimension is invalid");
    return cast(int) value;
}

private long freshSeed()
{
    auto random = Random(unpredictableSeed);
    return uniform(0L, cast(long) int.max, random);
}

private string twoDigits(long value)
{
    return value < 10 ? "0" ~ value.to!string : value.to!string;
}

private string generatedImageUrl(
    string profileId,
    string turnId,
    string filename,
    string sessionId,
)
{
    return "/api/profiles/" ~ encodeComponent(profileId)
        ~ "/turns/" ~ encodeComponent(turnId)
        ~ "/images/" ~ encodeComponent(filename)
        ~ "?session_id=" ~ encodeComponent(sessionId);
}

version (unittest) private final class FakeImageGenerator : ImageGeneratorPort
{
    ImageGenerationOutput output;
    ImageGenerationRequest lastRequest;

    this(ubyte[] png)
    {
        output = ImageGenerationOutput(png);
    }

    ImageGenerationOutput generate(ImageGenerationRequest request)
    {
        lastRequest = request;
        return output;
    }

    bool healthy()
    {
        return true;
    }
}

unittest
{
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, isAbsolute;

    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.server.config.app_config_store : AppConfigStore;
    import wheatley.server.history.rows.text_turn_record : TextTurnRecord;

    auto root = buildPath(tempDir(), "wheatley-image-runtime-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(
        profilesRoot,
        new AppConfigStore(configPath),
        root,
        root,
    );
    auto session = store.startProfileSession(
        "tester",
        "2026-08-11T18:00:00.000000Z",
        "test",
        "en",
    );
    TextTurnRecord record;
    record.turnId = "submission-1";
    record.submissionId = "submission-1";
    record.profileId = session.profileId;
    record.sessionId = session.sessionId;
    record.deviceId = "device";
    record.source = "api_text";
    record.status = "pending";
    record.startedAt = "2026-08-11T18:00:00.000000Z";
    record.modelName = "pi:test";
    record.language = "en";
    record.userText = "make a lake";
    record.reasoningMode = ReasoningMode.off;
    record.submissionJson = `{}`;
    auto turnId = store.beginTextTurn(record);
    assert(store.claimConversationTurn(session, turnId).length);

    ImageGenerationConfig config;
    config.endpoint = "http://image-host:8790";
    config.timeoutSeconds = 60;
    config.presets["medium.landscape"] = ImagePreset(960, 640);
    auto bytes = testPng(960, 640);
    auto generator = new FakeImageGenerator(bytes);
    auto runtime = new ImageGenerationRuntime(store, generator, config);
    auto artifact = runtime.generate("tester", Json.parse(
        `{"session_id":"` ~ session.sessionId ~ `","turn_id":"` ~ turnId
        ~ `","prompt":"A calm lake","aspect":"landscape","seed":42}`,
    ));
    assert(artifact.quality == "medium");
    assert(artifact.width == 960 && artifact.height == 640);
    assert(generator.lastRequest.width == 960 && generator.lastRequest.height == 640);
    assert(!isAbsolute(artifact.path));
    auto stored = store.generatedImage(session, turnId, artifact.filename);
    assert(isAbsolute(stored.path));
    assert(exists(stored.path));

    generator.output = ImageGenerationOutput(testPng(512, 512));
    assertThrown!Exception(runtime.generate("tester", Json.parse(
        `{"session_id":"` ~ session.sessionId ~ `","turn_id":"` ~ turnId
        ~ `","prompt":"Wrong dimensions","aspect":"landscape"}`,
    )));
    auto failed = store.generatedImagePaths(session, turnId, "generated-02.png");
    assert(!exists(failed.imagePath));
    assert(!exists(failed.metadataPath));
}

version (unittest) private ubyte[] testPng(int width, int height)
{
    ubyte[] bytes = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82];
    foreach (shift; [24, 16, 8, 0]) bytes ~= cast(ubyte) (width >> shift);
    foreach (shift; [24, 16, 8, 0]) bytes ~= cast(ubyte) (height >> shift);
    return bytes;
}
