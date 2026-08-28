module wheatley.server.i18n.product_translations;

import std.array : split;
import std.exception : enforce;
import std.file : exists, isFile, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.string : strip;

import wheatley.common.choice : requireChoice;
import wheatley.common.json.read : Json;

import vibe.core.sync : TaskMutex;

private TaskMutex cacheMutex;
private JSONValue[string] translationCache;

shared static this()
{
    cacheMutex = new TaskMutex;
}

string productTranslationText(string resourcesRoot, string language, string path)
{
    auto requested = language.strip;
    auto value = translationText(resourcesRoot, requested, path);
    if (value.length) return value;
    if (requested != "en") {
        value = translationText(resourcesRoot, "en", path);
        if (value.length) return value;
    }
    enforce(false, "Missing product translation: " ~ path ~ " (" ~ requested ~ ")");
    assert(false);
}

private string translationText(string resourcesRoot, string language, string path)
{
    if (!language.length || !path.length) return "";
    auto root = document(resourcesRoot, language);
    if (root.type == JSONType.null_) return "";
    return dottedString(root, path);
}

private JSONValue document(string resourcesRoot, string language)
{
    enforce(resourcesRoot.strip.length > 0, "Resources root is required for product translations");
    requireChoice!("en", "sk", "de")(language, "language");
    auto filePath = buildPath(
        absolutePath(buildNormalizedPath(resourcesRoot)),
        "translations",
        language ~ ".json",
    );
    cacheMutex.lock();
    scope(exit) cacheMutex.unlock();
    if (auto cached = filePath in translationCache) return *cached;
    enforce(exists(filePath) && isFile(filePath), "Missing translations file: " ~ filePath);
    auto payload = Json.parse(readText(filePath)).value;
    translationCache[filePath] = payload;
    return payload;
}

private string dottedString(JSONValue root, string path)
{
    JSONValue current = root;
    foreach (part; path.split(".")) {
        if (current.type != JSONType.object) return "";
        auto next = part in current.object;
        if (next is null) return "";
        current = *next;
    }
    if (current.type != JSONType.string) return "";
    return current.str;
}
