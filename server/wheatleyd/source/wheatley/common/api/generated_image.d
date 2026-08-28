module wheatley.common.api.generated_image;

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;

struct GeneratedImageArtifact
{
    long generatedImageId;
    string itemId;
    string filename;
    string mediaType;
    string url;
    string path;
    string sha256;
    long byteCount;
    long width;
    long height;
    long seed;
    string quality;
    string aspect;
    string prompt;
    string kind;
    long modelWidth;
    long modelHeight;
}

void assignMissingGeneratedImageIds(GeneratedImageArtifact[] artifacts)
{
    bool[long] used;
    foreach (artifact; artifacts) {
        if (artifact.kind == "screen_capture" || artifact.generatedImageId <= 0) continue;
        used[artifact.generatedImageId] = true;
    }

    long candidate = 1;
    foreach (ref artifact; artifacts) {
        if (artifact.kind == "screen_capture" || artifact.generatedImageId > 0) continue;
        while (candidate in used) candidate++;
        artifact.generatedImageId = candidate;
        used[candidate] = true;
        candidate++;
    }
}

string generatedImageArtifactJson(GeneratedImageArtifact artifact)
{
    return jsonObject([
        artifact.kind == "screen_capture" ? ""
            : jsonLongField("generated_image_id", artifact.generatedImageId),
        jsonStringField("item_id", artifact.itemId),
        jsonStringField("kind", artifact.kind.length ? artifact.kind : "generated_image"),
        jsonStringField("filename", artifact.filename),
        jsonStringField("media_type", artifact.mediaType),
        jsonStringField("url", artifact.url),
        jsonStringField("path", artifact.path),
        jsonStringField("sha256", artifact.sha256),
        jsonLongField("byte_count", artifact.byteCount),
        jsonLongField("width", artifact.width),
        jsonLongField("height", artifact.height),
        jsonLongField("seed", artifact.seed),
        jsonStringField("quality", artifact.quality),
        jsonStringField("aspect", artifact.aspect),
        jsonStringField("prompt", artifact.prompt),
        artifact.modelWidth > 0 ? jsonLongField("model_width", artifact.modelWidth) : "",
        artifact.modelHeight > 0 ? jsonLongField("model_height", artifact.modelHeight) : "",
    ]);
}

GeneratedImageArtifact generatedImageArtifactFromJson(Json json)
{
    return GeneratedImageArtifact(
        json.opt.integer("generated_image_id", 1).get(0),
        json.nonEmpty("item_id"),
        json.nonEmpty("filename"),
        json.choice!"image/png"("media_type"),
        json.text("url"),
        json.nonEmpty("path"),
        json.nonEmpty("sha256"),
        json.positiveInt("byte_count"),
        json.positiveInt("width"),
        json.positiveInt("height"),
        json.integer("seed"),
        json.choice!("low", "medium", "high")("quality"),
        json.choice!("square", "portrait", "landscape")("aspect"),
        json.nonEmpty("prompt"),
        json.opt.textOrEmpty("kind"),
        json.opt.integer("model_width", 1).get(0),
        json.opt.integer("model_height", 1).get(0),
    );
}

unittest
{
    GeneratedImageArtifact[] artifacts = [
        GeneratedImageArtifact(0, "old-first", "", "", "", "old/first", ""),
        GeneratedImageArtifact(2, "stored", "", "", "", "stored", ""),
        GeneratedImageArtifact(0, "old-last", "", "", "", "old/last", ""),
        GeneratedImageArtifact(0, "screen", "", "", "", "screen", "", 0, 0, 0, 0,
            "", "", "", "screen_capture"),
    ];
    assignMissingGeneratedImageIds(artifacts);
    assert(artifacts[0].generatedImageId == 1);
    assert(artifacts[1].generatedImageId == 2);
    assert(artifacts[2].generatedImageId == 3);
    assert(artifacts[3].generatedImageId == 0);
}
