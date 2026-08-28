module wheatley.server.profile.runtime;

import std.exception : enforce;

import wheatley.server.history.store : HistoryStore;
import wheatley.server.profiles.config_properties :
    ProfileConfigIndex,
    ProfileConfigProperty,
    activeProfileLanguage,
    indexProfileConfigProperties;

/**
 * Immutable-by-interface product configuration resolved for one profile and
 * language selection. Runtime roles receive this value instead of reopening
 * app/profile configuration themselves.
 */
final class ResolvedSessionConfig
{
    private string profileId_;
    private string language_;
    private string resourcesRoot_;
    private ProfileConfigProperty[] properties_;

    private this(
        string profileId,
        string language,
        string resourcesRoot,
        ProfileConfigProperty[] properties,
    )
    {
        enforce(profileId.length, "Resolved profile is required");
        this.profileId_ = profileId;
        this.language_ = language;
        this.resourcesRoot_ = resourcesRoot;
        this.properties_ = properties.dup;
    }

    string profileId() const
    {
        return profileId_;
    }

    string language() const
    {
        return language_;
    }

    string resourcesRoot() const
    {
        return resourcesRoot_;
    }

    ProfileConfigIndex configIndex() const
    {
        // Build a caller-owned lookup so consumers cannot mutate the snapshot.
        return indexProfileConfigProperties(properties_.dup);
    }
}

/** Owns resolution of server-canonical app/profile product configuration. */
final class ProfileRuntime
{
    private HistoryStore store;

    this(HistoryStore store)
    {
        enforce(store !is null, "Profile history store is required");
        this.store = store;
    }

    ResolvedSessionConfig resolveSession(string profileId, string requestedLanguage = "")
    {
        auto properties = store.effectiveConfigProperties(profileId);
        auto language = activeProfileLanguage(
            indexProfileConfigProperties(properties),
            requestedLanguage,
        );
        return new ResolvedSessionConfig(
            profileId,
            language,
            store.resourcesRoot,
            properties,
        );
    }
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.json : parseJSON;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    import wheatley.server.config.app_config_store : AppConfigStore;
    import wheatley.server.history.store.json : writeJsonFile;

    auto root = buildPath(tempDir(), "wheatley-profile-runtime-" ~ randomUUID().toString());
    auto profilesRoot = buildPath(root, "Profiles");
    auto profileRoot = buildPath(profilesRoot, "tester");
    mkdirRecurse(profileRoot);
    scope(exit) rmdirRecurse(root);
    writeJsonFile(buildPath(profileRoot, "config.json"), `{}`);
    auto configPath = buildPath(root, "config.json");
    writeJsonFile(configPath, parseJSON(
        `{"language":{"enabled":true,"default":"en","supported":"en","languages":{"en":{"response_language":"English"}}},"value":"app"}`,
    ).toString());

    auto store = new HistoryStore(profilesRoot, new AppConfigStore(configPath), root, root);
    auto profiles = new ProfileRuntime(store);
    auto resolved = profiles.resolveSession("tester", "");
    assert(resolved.profileId == "tester");
    assert(resolved.language == "en");
    assert(resolved.configIndex.textValue("value", "") == "app");

    auto callerIndex = resolved.configIndex;
    callerIndex.byPath.remove("value");
    assert(resolved.configIndex.textValue("value", "") == "app");

    writeJsonFile(configPath, parseJSON(
        `{"language":{"enabled":true,"default":"en","supported":"en","languages":{"en":{"response_language":"English"}}},"value":"changed"}`,
    ).toString());
    assert(resolved.configIndex.textValue("value", "") == "app");
    assert(profiles.resolveSession("tester").configIndex.textValue("value", "") == "changed");
}
