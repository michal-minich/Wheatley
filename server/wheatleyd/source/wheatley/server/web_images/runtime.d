module wheatley.server.web_images.runtime;

import std.base64 : Base64;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, remove, rename, write;
import std.string : startsWith, strip;
import std.uri : encodeComponent;
import std.uuid : randomUUID;

import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.web_image : WebImageArtifact, webImageArtifactJson;
import wheatley.common.json.read : Json;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.json : writeJsonFileAtomic;

private enum maxImageBytes = 8_000_000;
private enum maxPixels = 25_000_000;

final class WebImageRuntime
{
    private HistoryStore store;
    private TaskMutex lane;

    this(HistoryStore store)
    {
        enforce(store !is null, "History store is required for web images");
        this.store = store;
        this.lane = new TaskMutex;
    }

    WebImageArtifact persist(string profileId, Json request)
    {
        auto session = SessionKey(profileId, request.nonEmpty("session_id"));
        auto turnId = request.nonEmpty("turn_id");
        auto title = request.nonEmpty("title").strip;
        auto sourceUrl = request.nonEmpty("source_url").strip;
        auto originalImageUrl = request.nonEmpty("original_image_url").strip;
        auto mediaType = request.choice!("image/png", "image/jpeg")("media_type");
        auto encoded = request.nonEmpty("data_base64");
        enforce(title.length <= 2_000, "Web image title is too long");
        enforce(sourceUrl.length <= 16_000 && validPublicLink(sourceUrl),
            "Web image source URL is invalid");
        enforce(originalImageUrl.length <= 16_000 && validPublicLink(originalImageUrl),
            "Web image URL is invalid");
        enforce(encoded.length <= 10_700_000, "Web image payload is too large");

        ubyte[] bytes;
        try {
            bytes = Base64.decode(encoded);
        } catch (Exception) {
            throw new Exception("Web image payload is not valid base64");
        }
        enforce(bytes.length > 0 && bytes.length <= maxImageBytes,
            "Web image size is outside the allowed range");
        auto dimensions = imageDimensions(bytes, mediaType);
        enforce(cast(long) dimensions.width * dimensions.height <= maxPixels,
            "Web image pixel dimensions are outside the safe range");

        auto guard = scopedMutexLock(lane);
        auto index = store.nextWebImageIndex(session, turnId);
        auto extension = mediaType == "image/png" ? ".png" : ".jpg";
        auto filename = "web-" ~ twoDigits(index) ~ extension;
        auto paths = store.webImagePaths(session, turnId, filename);
        auto staging = paths.imagePath ~ ".partial-" ~ randomUUID().toString();
        scope(failure) {
            if (exists(staging)) remove(staging);
            if (exists(paths.metadataPath)) remove(paths.metadataPath);
            if (exists(paths.imagePath)) remove(paths.imagePath);
        }
        requireRunningTurn(store, session, turnId);
        mkdirRecurse(paths.imagesRoot);
        write(staging, bytes);
        rename(staging, paths.imagePath);

        auto artifact = WebImageArtifact(
            filename,
            mediaType,
            webImageUrl(profileId, turnId, filename, session.sessionId),
            paths.artifactPath,
            toHexString!(LetterCase.lower)(sha256Of(bytes)).idup,
            cast(long) bytes.length,
            dimensions.width,
            dimensions.height,
            title,
            sourceUrl,
            originalImageUrl,
        );
        writeJsonFileAtomic(paths.metadataPath, webImageArtifactJson(artifact));
        requireRunningTurn(store, session, turnId);
        return artifact;
    }
}

private struct ImageDimensions
{
    long width;
    long height;
}

private ImageDimensions imageDimensions(scope const ubyte[] bytes, string mediaType)
{
    return mediaType == "image/png" ? pngDimensions(bytes) : jpegDimensions(bytes);
}

private ImageDimensions pngDimensions(scope const ubyte[] bytes)
{
    immutable ubyte[] signature = [137, 80, 78, 71, 13, 10, 26, 10];
    enforce(bytes.length >= 24 && bytes[0 .. 8] == signature,
        "Web image bytes do not match image/png");
    enforce(bytes[12 .. 16] == cast(ubyte[]) "IHDR", "PNG is missing IHDR dimensions");
    return ImageDimensions(bigEndianInt(bytes[16 .. 20]), bigEndianInt(bytes[20 .. 24]));
}

private ImageDimensions jpegDimensions(scope const ubyte[] bytes)
{
    enforce(bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff,
        "Web image bytes do not match image/jpeg");
    size_t offset = 2;
    while (offset + 3 < bytes.length) {
        if (bytes[offset] != 0xff) {
            offset++;
            continue;
        }
        while (offset < bytes.length && bytes[offset] == 0xff) offset++;
        if (offset >= bytes.length) break;
        auto marker = bytes[offset++];
        if (marker == 0xd8 || marker == 0xd9 || marker == 0x01
            || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (offset + 1 >= bytes.length) break;
        auto length = cast(size_t) ((bytes[offset] << 8) | bytes[offset + 1]);
        if (length < 2 || offset + length > bytes.length) break;
        auto startOfFrame = (marker >= 0xc0 && marker <= 0xc3)
            || (marker >= 0xc5 && marker <= 0xc7)
            || (marker >= 0xc9 && marker <= 0xcb)
            || (marker >= 0xcd && marker <= 0xcf);
        if (startOfFrame) {
            enforce(length >= 7, "JPEG dimensions are invalid");
            return ImageDimensions(
                cast(long) ((bytes[offset + 5] << 8) | bytes[offset + 6]),
                cast(long) ((bytes[offset + 3] << 8) | bytes[offset + 4]),
            );
        }
        offset += length;
    }
    throw new Exception("JPEG dimensions could not be read safely");
}

private long bigEndianInt(scope const ubyte[] bytes)
{
    enforce(bytes.length == 4, "Image dimension field is invalid");
    auto value = (cast(ulong) bytes[0] << 24)
        | (cast(ulong) bytes[1] << 16)
        | (cast(ulong) bytes[2] << 8)
        | bytes[3];
    enforce(value > 0 && value <= int.max, "Image dimension is invalid");
    return cast(long) value;
}

private bool validPublicLink(string value)
{
    return value.startsWith("https://") || value.startsWith("http://");
}

private void requireRunningTurn(HistoryStore store, SessionKey session, string turnId)
{
    auto turn = store.findTurn(session, turnId);
    enforce(turn.id.length && turn.status == "running",
        "Web image turn is no longer running");
}

private string webImageUrl(
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

private string twoDigits(long value)
{
    return value < 10 ? "0" ~ value.to!string : value.to!string;
}

unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, isAbsolute;

    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.server.config.app_config_store : AppConfigStore;
    import wheatley.server.history.rows.text_turn_record : TextTurnRecord;

    auto root = buildPath(tempDir(), "wheatley-web-image-runtime-" ~ randomUUID().toString());
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
    record.userText = "find a lake";
    record.reasoningMode = ReasoningMode.off;
    record.submissionJson = `{}`;
    auto turnId = store.beginTextTurn(record);
    assert(store.claimConversationTurn(session, turnId).length);

    ubyte[] png = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82];
    foreach (shift; [24, 16, 8, 0]) png ~= cast(ubyte) (640 >> shift);
    foreach (shift; [24, 16, 8, 0]) png ~= cast(ubyte) (480 >> shift);
    auto runtime = new WebImageRuntime(store);
    auto requestJson = (
        `{"session_id":"` ~ session.sessionId ~ `","turn_id":"` ~ turnId
        ~ `","title":"Lake","source_url":"https://example.com/lake"`
        ~ `,"original_image_url":"https://images.example.com/lake.png"`
        ~ `,"media_type":"image/png","data_base64":"`
        ~ Base64.encode(png) ~ `"}`
    ).idup;
    auto artifact = runtime.persist("tester", Json.parse(requestJson));
    assert(artifact.filename == "web-01.png");
    assert(artifact.width == 640 && artifact.height == 480);
    assert(!isAbsolute(artifact.path));
    auto stored = store.webImage(session, turnId, artifact.filename);
    assert(isAbsolute(stored.path));
    assert(exists(stored.path));
    assert(stored.title == "Lake");
}
