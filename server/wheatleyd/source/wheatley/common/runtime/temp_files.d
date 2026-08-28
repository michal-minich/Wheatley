module wheatley.common.runtime.temp_files;

import std.array : appender;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse, remove;
import std.path : buildPath;
import std.uuid : randomUUID;

string temporaryRuntimeFile(string appDataRoot, string owner, string category, string stem, string extension)
{
    auto directory = buildPath(appDataRoot, owner, "tmp", category);
    mkdirRecurse(directory);
    return buildPath(directory, safeTempToken(stem) ~ "-" ~ randomUUID().toString() ~ extension);
}

string runtimeOwnerRoot(string appDataRoot, string owner)
{
    auto directory = buildPath(appDataRoot, owner);
    mkdirRecurse(directory);
    return directory;
}

void removeQuietly(string path)
{
    if (!path.length) return;
    try {
        remove(path);
    } catch (Exception) {
    }
}

void cleanupRuntimeTempFiles(string appDataRoot, string owner, string category)
{
    auto directory = buildPath(appDataRoot, owner, "tmp", category);
    if (!exists(directory) || !isDir(directory)) return;
    foreach (entry; dirEntries(directory, SpanMode.shallow)) {
        if (entry.isFile) removeQuietly(entry.name);
    }
}

private string safeTempToken(string value)
{
    auto output = appender!string;
    foreach (ch; value) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            output.put(ch);
        } else {
            output.put("-");
        }
    }
    return output.data.length ? output.data : "tmp";
}
