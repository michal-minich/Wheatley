module wheatley.server.history.files;

import std.algorithm : canFind, sort, startsWith;
import std.array : split;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse, remove;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName, dirSeparator;
import std.string : endsWith, replace;

import wheatley.common.safe_token : enforceSafeToken;

struct FilePayload
{
    string path;
    string mediaType;
}

struct GeneratedFileTarget
{
    string path;
    string relativePath;
    string mediaType;
}

class RuntimeFiles
{
    private string profilesRoot;

    this(string profilesRoot)
    {
        this.profilesRoot = absolutePath(buildNormalizedPath(profilesRoot));
    }

    FilePayload resolveArtifact(string relativePath, string mediaType)
    {
        enforce(relativePath.startsWith("profiles/"), "Artifact is not profile-local");
        auto path = trustedProfilesRelativePath(relativePath["profiles/".length .. $]);
        enforce(exists(path), "Artifact file does not exist");
        return FilePayload(path, mediaType.length ? mediaType : "application/octet-stream");
    }

    GeneratedFileTarget generatedTtsTarget(string profileId, string artifactId)
    {
        rejectGeneratedArtifactId(artifactId);
        auto profileRelativePath = profileFilesRelativePath(
            profileId,
            "_generated/tts/" ~ artifactId ~ ".opus",
        );
        auto path = trustedProfilesRelativePath(profileRelativePath);
        mkdirRecurse(dirName(path));
        return GeneratedFileTarget(path, "profiles/" ~ profileRelativePath, "audio/ogg");
    }

    FilePayload resolveGeneratedTts(string profileId, string artifactId)
    {
        auto target = generatedTtsTarget(profileId, artifactId);
        enforce(exists(target.path), "Generated TTS audio does not exist");
        return FilePayload(target.path, target.mediaType);
    }

    /// Exact normalized voice input awaiting the accepted-live-voice commit.
    /// This is deliberately separate from durable turn artifacts.
    string stagedUserAudioPath(string profileId, string submissionId)
    {
        enforceSafeToken(submissionId, "Accepted voice submission ID");
        auto profileRelativePath = profileFilesRelativePath(
            profileId,
            "_staged/user-audio/" ~ submissionId ~ ".opus",
        );
        return trustedProfilesRelativePath(profileRelativePath);
    }

    FilePayload resolveStagedUserAudio(string profileId, string submissionId)
    {
        auto path = stagedUserAudioPath(profileId, submissionId);
        enforce(exists(path), "Accepted voice audio does not exist");
        return FilePayload(path, "audio/ogg");
    }

    /// Accepted-live-voice sidecars not yet represented by a durable turn.
    /// Interpretation of the manifest remains owned by the voice subsystem.
    string[] stagedUserAudioManifestPaths(string profileId)
    {
        auto directory = trustedProfilesRelativePath(profileFilesRelativePath(
            profileId,
            "_staged/user-audio",
        ));
        if (!exists(directory) || !isDir(directory)) return [];

        string[] result;
        foreach (entry; dirEntries(directory, SpanMode.shallow)) {
            if (entry.isFile && entry.name.endsWith(".opus.accepted.json"))
                result ~= entry.name;
        }
        sort(result);
        return result;
    }

    void removeGeneratedTts(string profileId, string artifactId)
    {
        auto target = generatedTtsTarget(profileId, artifactId);
        if (exists(target.path)) remove(target.path);
    }

    void cleanupGeneratedTts()
    {
        if (!exists(profilesRoot) || !isDir(profilesRoot)) return;
        foreach (profile; dirEntries(profilesRoot, SpanMode.shallow)) {
            if (!profile.isDir) continue;
            auto directory = buildPath(profile.name, "files", "_generated", "tts");
            if (!exists(directory) || !isDir(directory)) continue;
            foreach (entry; dirEntries(directory, SpanMode.shallow)) {
                if (entry.isFile) remove(entry.name);
            }
        }
    }

    private string profileFilesRelativePath(string profileId, string relativePath)
    {
        rejectUnsafeProfileId(profileId);
        rejectUnsafeRelativePath(relativePath);
        return profileId ~ "/files/" ~ relativePath;
    }

    private string trustedProfilesRelativePath(string relativePath)
    {
        rejectUnsafeRelativePath(relativePath);
        auto platformRelative = relativePath.replace("/", dirSeparator);
        auto path = absolutePath(buildNormalizedPath(buildPath(profilesRoot, platformRelative)));
        enforce(path == profilesRoot || path.startsWith(profilesRoot ~ dirSeparator), "Resolved path escaped profiles root");
        return path;
    }
}

private void rejectUnsafeProfileId(string profileId)
{
    enforce(profileId.length > 0, "Profile ID is empty");
    enforce(!profileId.canFind("/") && !profileId.canFind("\\"), "Profile ID contains a path separator");
    enforce(profileId != "." && profileId != "..", "Profile ID is unsafe");
}

private void rejectUnsafeRelativePath(string relativePath)
{
    enforce(relativePath.length > 0, "Relative path is empty");
    enforce(relativePath[0] != '/' && relativePath[0] != '\\', "Absolute paths are not allowed");
    enforce(!relativePath.canFind('\\'), "Backslash paths are not allowed");
    foreach (part; relativePath.split("/")) {
        enforce(part.length > 0, "Empty path segments are not allowed");
        enforce(part != "." && part != "..", "Dot path segments are not allowed");
    }
}

private void rejectGeneratedArtifactId(string artifactId)
{
    enforceSafeToken(artifactId, "Generated artifact ID");
}

unittest
{
    import std.file : rmdirRecurse, tempDir, write;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-runtime-files-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto generated = buildPath(root, "tester", "files", "_generated", "tts");
    auto preserved = buildPath(root, "tester", "files", "owned.opus");
    mkdirRecurse(generated);
    write(buildPath(generated, "stale.opus"), cast(ubyte[]) [1]);
    write(preserved, cast(ubyte[]) [2]);

    auto files = new RuntimeFiles(root);
    files.cleanupGeneratedTts();

    assert(!exists(buildPath(generated, "stale.opus")));
    assert(exists(preserved));
}
