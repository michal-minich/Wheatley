module wheatley.server.history.store.locations;

import std.algorithm : canFind, startsWith;
import std.path :
    absolutePath,
    baseName,
    buildNormalizedPath,
    buildPath,
    dirName,
    dirSeparator;
import std.string : replace;

import wheatley.server.history.store.paths : enforceSafeComponent;

package(wheatley.server.history) final class HistoryStoreLocations
{
    string profilesRoot;
    string displayRoot;

    this(string profilesRoot, string displayRoot)
    {
        this.profilesRoot = absolutePath(buildNormalizedPath(profilesRoot));
        this.displayRoot = displayRoot.length
            ? absolutePath(buildNormalizedPath(displayRoot))
            : dirName(dirName(this.profilesRoot));
    }

    string profileRoot(string profileId)
    {
        enforceSafeComponent(profileId, "Profile");
        return buildPath(profilesRoot, profileId);
    }

    string profileIdFromSessionRoot(string sessionRoot)
    {
        return baseName(dirName(dirName(dirName(dirName(dirName(sessionRoot))))));
    }

    string profileIdFromTurnRoot(string turnRoot)
    {
        return profileIdFromSessionRoot(dirName(dirName(turnRoot)));
    }

    string sessionIdFromSessionRoot(string profileId, string sessionRoot)
    {
        auto normalized = absolutePath(buildNormalizedPath(sessionRoot));
        auto prefix = buildPath(profileRoot(profileId), "sessions") ~ dirSeparator;
        if (!normalized.startsWith(prefix)) return "";
        return normalized[prefix.length .. $].replace(dirSeparator, "/");
    }

    string turnIdFromTurnRoot(string turnRoot)
    {
        auto normalized = absolutePath(buildNormalizedPath(turnRoot));
        auto prefix = profilesRoot ~ dirSeparator;
        if (normalized.startsWith(prefix)) {
            return normalized[prefix.length .. $].replace(dirSeparator, "/");
        }
        return profileArtifactRelativePath(turnRoot);
    }

    string turnRootFromPathId(string turnId)
    {
        if (!turnId.canFind("/")) return "";
        auto root = absolutePath(buildNormalizedPath(
            buildPath(profilesRoot, turnId.replace("/", dirSeparator)),
        ));
        auto prefix = profilesRoot ~ dirSeparator;
        if (!root.startsWith(prefix)) return "";
        if (!root.canFind(dirSeparator ~ "sessions" ~ dirSeparator)) return "";
        if (!root.canFind(dirSeparator ~ "turns" ~ dirSeparator)) return "";
        return root;
    }

    string displayRelative(string path)
    {
        auto normalized = absolutePath(buildNormalizedPath(path));
        auto prefix = displayRoot ~ dirSeparator;
        if (normalized.startsWith(prefix)) {
            return normalized[prefix.length .. $].replace(dirSeparator, "/");
        }
        return normalized.replace(dirSeparator, "/");
    }

    string profileArtifactRelativePath(string path)
    {
        auto normalized = absolutePath(buildNormalizedPath(path));
        auto prefix = profilesRoot ~ dirSeparator;
        if (normalized.startsWith(prefix)) {
            return "profiles/" ~ normalized[prefix.length .. $].replace(dirSeparator, "/");
        }
        return displayRelative(normalized);
    }
}
