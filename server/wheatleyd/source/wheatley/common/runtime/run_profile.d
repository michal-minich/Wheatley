module wheatley.common.runtime.run_profile;

import std.exception : enforce;
import std.file : exists, isFile, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildNormalizedPath, dirName, isAbsolute;
import std.process : environment;
import std.string : startsWith, endsWith;

import wheatley.common.json.read : Json;

struct RunProfile
{
    JSONValue root;
    string directory;

    JSONValue section(string name) const
    {
        return Json.object(root).object(name).value;
    }
}

RunProfile loadRunProfile(string path)
{
    return loadRunProfile(path, 0);
}

private RunProfile loadRunProfile(string path, int depth)
{
    enforce(depth <= 4, "Run profile inheritance is too deep");
    auto absolute = absolutePath(buildNormalizedPath(path));
    enforce(exists(absolute) && isFile(absolute), "Run profile does not exist: " ~ absolute);
    auto root = Json.parse(readText(absolute)).value;
    auto rootObject = root.objectNoRef;
    if (auto inherited = "extends" in rootObject) {
        enforce(inherited.type == JSONType.string, "Run profile extends must be a string");
        auto base = loadRunProfile(
            buildNormalizedPath(dirName(absolute), inherited.str),
            depth + 1,
        );
        root = mergeJson(base.root, root);
    }
    enforce(Json.object(root).integer("version") == 1, "Unsupported run profile version");
    return RunProfile(root, dirName(absolute));
}

private JSONValue mergeJson(JSONValue base, JSONValue overrideValue)
{
    if (base.type != JSONType.object || overrideValue.type != JSONType.object)
        return overrideValue;
    auto result = base.object.dup;
    foreach (key, value; overrideValue.object) {
        if (key == "extends") continue;
        auto current = key in result;
        result[key] = current is null ? value : mergeJson(*current, value);
    }
    return JSONValue(result);
}

string runProfileValue(string value)
{
    if (!value.startsWith("${") || !value.endsWith("}")) return value;
    auto name = value[2 .. $ - 1];
    enforce(name.length > 0, "Empty environment reference in run profile");
    return environment.get(name, "");
}

string runProfilePath(string value, string directory)
{
    auto resolved = runProfileValue(value);
    if (!isAbsolute(resolved)) resolved = buildNormalizedPath(directory, resolved);
    return absolutePath(buildNormalizedPath(resolved));
}
