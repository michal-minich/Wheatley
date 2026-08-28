module wheatley.common.api.web_image;

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;

struct WebImageArtifact
{
    string filename;
    string mediaType;
    string url;
    string path;
    string sha256;
    long byteCount;
    long width;
    long height;
    string title;
    string sourceUrl;
    string originalImageUrl;
}

string webImageArtifactJson(WebImageArtifact artifact)
{
    return jsonObject([
        jsonStringField("kind", "web_image"),
        jsonStringField("filename", artifact.filename),
        jsonStringField("media_type", artifact.mediaType),
        jsonStringField("url", artifact.url),
        jsonStringField("path", artifact.path),
        jsonStringField("sha256", artifact.sha256),
        jsonLongField("byte_count", artifact.byteCount),
        jsonLongField("width", artifact.width),
        jsonLongField("height", artifact.height),
        jsonStringField("title", artifact.title),
        jsonStringField("source_url", artifact.sourceUrl),
        jsonStringField("original_image_url", artifact.originalImageUrl),
    ]);
}

WebImageArtifact webImageArtifactFromJson(Json json)
{
    return WebImageArtifact(
        json.nonEmpty("filename"),
        json.choice!("image/png", "image/jpeg")("media_type"),
        json.text("url"),
        json.nonEmpty("path"),
        json.nonEmpty("sha256"),
        json.positiveInt("byte_count"),
        json.positiveInt("width"),
        json.positiveInt("height"),
        json.nonEmpty("title"),
        json.nonEmpty("source_url"),
        json.nonEmpty("original_image_url"),
    );
}
