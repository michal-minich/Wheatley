module wheatley.common.api.media;

import std.json : JSONValue;

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

/// Stable, content-addressed description of reusable source media.
///
/// `code` is the human-readable catalog name. `revision` is an intentional
/// catalog revision, while `sha256` is the authoritative byte identity used by
/// caches and integrity checks.
struct MediaAssetRef
{
    string code;
    string revision;
    string mediaType;
    ulong sizeBytes;
    string sha256;
    string url;
}

struct ThinkingMusicAssetSelection
{
    MediaAssetRef asset;
    string title;
    double gainDb;
}

MediaAssetRef mediaAssetRefFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return MediaAssetRef(
        json.text("code"),
        json.text("revision"),
        json.text("media_type"),
        cast(ulong) json.integer("size_bytes", 1),
        json.text("sha256"),
        json.text("url"),
    );
}

string mediaAssetRefJson(MediaAssetRef asset)
{
    return jsonObject([
        jsonStringField("code", asset.code),
        jsonStringField("revision", asset.revision),
        jsonStringField("media_type", asset.mediaType),
        jsonLongField("size_bytes", cast(long) asset.sizeBytes),
        jsonStringField("sha256", asset.sha256),
        jsonStringField("url", asset.url),
    ]);
}

ThinkingMusicAssetSelection thinkingMusicAssetSelectionFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ThinkingMusicAssetSelection(
        mediaAssetRefFromJson(json.object("asset").value),
        json.text("title"),
        json.number("gain_db", -120, 24),
    );
}

string thinkingMusicAssetSelectionJson(ThinkingMusicAssetSelection selection)
{
    return jsonObject([
        jsonRawField("asset", mediaAssetRefJson(selection.asset)),
        jsonStringField("title", selection.title),
        jsonRawField("gain_db", JSONValue(selection.gainDb).toString()),
    ]);
}

unittest
{
    import std.json : parseJSON;

    auto selection = ThinkingMusicAssetSelection(
        MediaAssetRef(
            "busted-jazz",
            "1",
            "audio/mpeg",
            123UL,
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "/api/profiles/wheatley/thinking-music/busted-jazz/1",
        ),
        "Busted Jazz",
        -20.34,
    );
    auto decoded = thinkingMusicAssetSelectionFromJson(
        parseJSON(thinkingMusicAssetSelectionJson(selection)),
    );
    assert(decoded.asset.code == selection.asset.code);
    assert(decoded.asset.sizeBytes == selection.asset.sizeBytes);
    assert(decoded.title == selection.title);
    assert(decoded.gainDb == selection.gainDb);
}
