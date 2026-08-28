module wheatley.common.runtime.local_tools;

import std.algorithm : canFind, endsWith, startsWith;
import std.exception : enforce;
import std.file : exists;
import std.path : absolutePath, buildNormalizedPath, buildPath, isAbsolute;
import std.string : toLower;

string resolveBundledExecutable(string rawPath, string label, string appDataRoot)
{
    auto root = toolBinRoot(appDataRoot);
    enforce(rawPath.length > 0, label ~ " is not configured");
    string candidate;
    if (rawPath.canFind("/") || rawPath.canFind("\\")) {
        candidate = isAbsolute(rawPath) ? rawPath : buildPath(appDataRoot, rawPath);
    } else {
        foreach (fileName; executableFileNames(rawPath)) {
            candidate = buildPath(root, fileName);
            if (exists(candidate)) break;
        }
    }

    auto path = normalizedAbsolute(candidate);
    enforce(isInside(path, root), label ~ " must live under " ~ root);
    enforce(exists(path), label ~ " does not exist: " ~ path);
    return path;
}

string resolveAppDataPath(string rawPath, string label, string appDataRoot)
{
    enforce(rawPath.length > 0, label ~ " is not configured");
    auto root = normalizedAbsolute(appDataRoot);
    auto path = normalizedAbsolute(isAbsolute(rawPath) ? rawPath : buildPath(appDataRoot, rawPath));
    enforce(isInside(path, root), label ~ " must live under app data root " ~ root);
    enforce(exists(path), label ~ " does not exist: " ~ path);
    return path;
}

string resolveLocalExecutable(string rawPath, string label, string appDataRoot)
{
    enforce(rawPath.length > 0, label ~ " is not configured");
    auto path = normalizedAbsolute(isAbsolute(rawPath) ? rawPath : buildPath(appDataRoot, rawPath));
    enforce(exists(path), label ~ " does not exist: " ~ path);
    return path;
}

string toolBinRoot(string appDataRoot)
{
    return normalizedAbsolute(buildPath(appDataRoot, "tools", toolPlatformName(), "bin"));
}

string toolPlatformName()
{
    return platformOsName() ~ "-" ~ platformArchName();
}

private string platformOsName()
{
    version (OSX) {
        return "macos";
    } else version (linux) {
        return "linux";
    } else version (Windows) {
        return "windows";
    } else {
        static assert(false, "Unsupported Wheatley tool platform OS");
    }
}

private string platformArchName()
{
    version (AArch64) {
        return "arm64";
    } else version (X86_64) {
        return "x86_64";
    } else {
        static assert(false, "Unsupported Wheatley tool platform architecture");
    }
}

private string[] executableFileNames(string name)
{
    version (Windows) {
        auto lower = name.toLower;
        if (lower.endsWith(".exe") || lower.endsWith(".cmd") || lower.endsWith(".bat")) {
            return [name];
        }
        return [name ~ ".exe", name ~ ".cmd", name ~ ".bat"];
    } else {
        return [name];
    }
}

private string normalizedAbsolute(string path)
{
    return absolutePath(buildNormalizedPath(path));
}

private bool isInside(string path, string root)
{
    if (path == root) return true;
    if (!path.startsWith(root)) return false;
    if (path.length <= root.length) return false;
    return path[root.length] == '/' || path[root.length] == '\\';
}
