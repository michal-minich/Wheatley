module wheatley.server.media.thinking_music;

import std.exception : enforce;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, read, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;

import wheatley.common.api.media : MediaAssetRef;
import wheatley.common.json.read : Json;
import wheatley.common.safe_token : enforceSafeToken;
import wheatley.server.config.app_config_store : AppConfigStore;

struct ThinkingMusicSelection
{
    MediaAssetRef asset;
    string title;
    string path;
    double gainDb;
}

final class ThinkingMusicLibrary
{
    private string resourcesRoot;
    private AppConfigStore appConfig;
    private ThinkingMusicTrack[] tracks;
    private double masterGainDb;

    this(string resourcesRoot, AppConfigStore appConfig)
    {
        this.resourcesRoot = resourcesRoot;
        this.appConfig = appConfig;
        loadManifest();
    }

    ThinkingMusicSelection takeNext(string profileId)
    {
        auto stored = appConfig.takeThinkingMusicIndex(profileId);
        auto index = cast(size_t) (stored % tracks.length);
        auto track = tracks[index];
        auto path = buildPath(musicRoot(), track.fileName);
        enforce(exists(path), "Thinking music track does not exist: " ~ track.fileName);
        return ThinkingMusicSelection(
            MediaAssetRef(
                track.code,
                track.revision,
                "audio/mpeg",
                track.sizeBytes,
                track.sha256,
                "",
            ),
            track.title,
            path,
            masterGainDb + track.gainDb,
        );
    }

    ThinkingMusicSelection requireAsset(string code, string revision)
    {
        foreach (track; tracks) {
            if (track.code != code || track.revision != revision)
                continue;
            auto path = buildPath(musicRoot(), track.fileName);
            enforce(exists(path), "Thinking music track does not exist: " ~ track.fileName);
            return ThinkingMusicSelection(
                MediaAssetRef(
                    track.code,
                    track.revision,
                    "audio/mpeg",
                    track.sizeBytes,
                    track.sha256,
                    "",
                ),
                track.title,
                path,
                masterGainDb + track.gainDb,
            );
        }
        throw new Exception("Thinking music asset not found");
    }

    private void loadManifest()
    {
        auto path = buildPath(musicRoot(), "manifest.json");
        enforce(exists(path), "Thinking music manifest does not exist");
        auto manifest = Json.parse(readText(path));
        masterGainDb = jsonNumber(manifest.value.object["master_gain_db"]);
        auto values = manifest.array("tracks");
        foreach (value; values.value.array) {
            auto track = Json.object(value);
            auto code = track.token("code");
            auto revision = track.token("revision");
            enforceSafeToken(code, "Thinking music code");
            enforceSafeToken(revision, "Thinking music revision");
            auto fileName = track.text("file");
            auto assetPath = buildPath(musicRoot(), fileName);
            enforce(exists(assetPath), "Thinking music track does not exist: " ~ fileName);
            auto bytes = cast(ubyte[]) read(assetPath);
            tracks ~= ThinkingMusicTrack(
                code,
                revision,
                track.text("title"),
                fileName,
                jsonNumber(track.value.object["gain_db"]),
                cast(ulong) bytes.length,
                toHexString!(LetterCase.lower)(sha256Of(bytes)).idup,
            );
        }
        enforce(tracks.length > 0, "Thinking music manifest has no tracks");
    }

    private string musicRoot()
    {
        return buildPath(resourcesRoot, "assets", "audio", "thinking-music");
    }
}

private struct ThinkingMusicTrack
{
    string code;
    string revision;
    string title;
    string fileName;
    double gainDb;
    ulong sizeBytes;
    string sha256;
}

private double jsonNumber(JSONValue value)
{
    if (value.type == JSONType.float_) return value.floating;
    if (value.type == JSONType.integer) return cast(double) value.integer;
    if (value.type == JSONType.uinteger) return cast(double) value.uinteger;
    throw new Exception("Thinking music gain must be a number");
}

unittest
{
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-thinking-music-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);
    auto musicRoot = buildPath(root, "assets", "audio", "thinking-music");
    mkdirRecurse(musicRoot);
    write(buildPath(musicRoot, "a.mp3"), "a");
    write(buildPath(musicRoot, "b.mp3"), "b");
    write(buildPath(musicRoot, "manifest.json"), `{
        "master_gain_db": -12,
        "tracks": [
            {"code":"a","revision":"1","title":"Track A","file":"a.mp3","gain_db":0},
            {"code":"b","revision":"2","title":"Track B","file":"b.mp3","gain_db":-1}
        ]
    }`);
    auto configPath = buildPath(root, "config.json");
    write(configPath, `{
        "profiles": {"wheatley": {"thinking_music_index": 0}}
    }`);
    auto appConfig = new AppConfigStore(configPath);
    auto library = new ThinkingMusicLibrary(root, appConfig);
    auto first = library.takeNext("wheatley");
    assert(first.asset.code == "a");
    assert(first.asset.revision == "1");
    assert(first.title == "Track A");
    assert(first.asset.sizeBytes == 1);
    assert(first.asset.sha256.length == 64);
    assert(library.takeNext("wheatley").asset.code == "b");
    assert(library.takeNext("wheatley").asset.code == "a");
    assert(library.takeNext("atom").asset.code == "a");
    assert(library.requireAsset("b", "2").asset.code == "b");
    auto loaded = parseJSON(readText(configPath));
    assert(loaded["profiles"]["wheatley"]["thinking_music_index"].integer == 3);
    assert(loaded["profiles"]["atom"]["thinking_music_index"].integer == 1);
}
