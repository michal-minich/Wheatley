module wheatley.server.config.app_config_store;

import std.array : join;
import std.exception : enforce;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;

import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.api.reasoning : ReasoningMode, reasoningModeText;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.safe_token : enforceSafeToken;
import wheatley.server.history.store.json : writeJsonFile;
import wheatley.server.profiles.config_properties :
    ProfileConfigProperty,
    flattenConfigProperties;

final class AppConfigStore
{
    private string path;
    private TaskMutex mutex;

    this(string path)
    {
        enforce(path.length, "App config path is required");
        enforce(exists(path), "App config does not exist");
        this.path = path;
        this.mutex = new TaskMutex;
        load();
    }

    string json()
    {
        auto guard = scopedMutexLock(mutex);
        return load().toString();
    }

    ProfileConfigProperty[] properties()
    {
        auto guard = scopedMutexLock(mutex);
        return flattenConfigProperties(load(), ["clients", "profiles"]);
    }

    string clientConfigJson(string clientId)
    {
        auto guard = scopedMutexLock(mutex);
        enforceSafeToken(clientId, "Client config ID");
        return renderClientConfigJson(load(), clientId);
    }

    string saveClientConfig(string clientId, JSONValue value)
    {
        auto guard = scopedMutexLock(mutex);
        enforceSafeToken(clientId, "Client config ID");
        validateClientConfig(value);
        auto config = load();
        ensureObjectField(config, "clients");
        ensureObjectField(config, "profiles");
        config.object.remove("voice");
        auto client = Json.object(value);
        config.object["clients"].object[clientId] = JSONValue([
            "last_used_profile_id": JSONValue(client.text("last_used_profile_id")),
            "speech_commit_delay_seconds": JSONValue(
                client.integer("speech_commit_delay_seconds", 1, 12),
            ),
            "output_recovery_ms": JSONValue(
                client.integer("output_recovery_ms", 0, 30_000),
            ),
            "thinking_music_fade_in_ms": JSONValue(
                client.integer("thinking_music_fade_in_ms", 0, 10_000),
            ),
            "thinking_music_fade_out_ms": JSONValue(
                client.integer("thinking_music_fade_out_ms", 0, 10_000),
            ),
        ]);
        auto profiles = client.array("profiles");
        foreach (entry; profiles.value.array) {
            auto profileEntry = Json.object(entry);
            auto profileId = profileEntry.text("profile_id");
            auto existing = profileId in config.object["profiles"].object;
            JSONValue profile = existing is null ? parseJSON("{}") : Json.object(*existing).value;
            profile.object["accent"] = JSONValue(profileEntry.text("accent"));
            profile.object["auto_speak"] = JSONValue(profileEntry.boolean("auto_speak"));
            profile.object["play_music"] = JSONValue(profileEntry.boolean("play_music"));
            profile.object["keep_microphone_on"] = JSONValue(
                profileEntry.boolean("keep_microphone_on"),
            );
            profile.object["reasoning_mode"] = JSONValue(
                profileEntry.enumeration!ReasoningMode("reasoning_mode").reasoningModeText,
            );
            profile.object["activity_pane_open"] = JSONValue(profileEntry.boolean("activity_pane_open"));
            profile.object["show_thinking"] = JSONValue(profileEntry.boolean("show_thinking"));
            profile.object["show_compacted_context"] = JSONValue(
                profileEntry.boolean("show_compacted_context"),
            );
            profile.object["language"] = JSONValue(profileEntry.text("language"));
            profile.object["model"] = JSONValue(profileEntry.text("model"));
            if (!("thinking_music_index" in profile.object))
                profile.object["thinking_music_index"] = JSONValue(0L);
            config.object["profiles"].object[profileId] = profile;
        }
        write(config);
        return renderClientConfigJson(config, clientId);
    }

    long takeThinkingMusicIndex(string profileId)
    {
        auto guard = scopedMutexLock(mutex);
        enforceSafeToken(profileId, "Profile");
        auto config = load();
        ensureObjectField(config, "profiles");
        auto profile = profileId in config.object["profiles"].object;
        long stored = 0;
        if (profile is null) {
            config.object["profiles"].object[profileId] = parseJSON("{}");
            profile = profileId in config.object["profiles"].object;
        } else {
            Json.object(*profile);
            auto field = "thinking_music_index" in profile.object;
            if (field !is null) {
                enforce(
                    field.type == JSONType.integer || field.type == JSONType.uinteger,
                    "thinking_music_index must be an integer",
                );
                stored = field.type == JSONType.integer
                    ? field.integer
                    : cast(long) field.uinteger;
                enforce(stored >= 0, "thinking_music_index cannot be negative");
            }
        }
        profile.object["thinking_music_index"] = JSONValue(stored + 1);
        write(config);
        return stored;
    }

    private JSONValue load()
    {
        return Json.parse(readText(path)).value;
    }

    private void write(JSONValue config)
    {
        writeJsonFile(path, config.toString());
    }
}

private string renderClientConfigJson(JSONValue config, string clientId)
{
    auto client = Json.object(requireClientObject(config, clientId));
    auto lastUsed = client.text("last_used_profile_id");
    auto speechCommitDelaySeconds = client.integer("speech_commit_delay_seconds", 1, 12);
    auto outputRecoveryMs = client.integer("output_recovery_ms", 0, 30_000);
    auto fadeInMs = client.integer("thinking_music_fade_in_ms", 0, 10_000);
    auto fadeOutMs = client.integer("thinking_music_fade_out_ms", 0, 10_000);
    ensureObjectField(config, "profiles");
    string[] profileJson;
    foreach (profileId, profile; config.object["profiles"].object) {
        if (!profileHasClientUi(profile)) continue;
        profileJson ~= clientProfileJson(profileId, profile);
    }
    enforce(profileJson.length > 0, "At least one profile must have client UI config");
    enforce(
        (lastUsed in config.object["profiles"].object) !is null
            && profileHasClientUi(config.object["profiles"].object[lastUsed]),
        "clients." ~ clientId ~ ".last_used_profile_id must reference a configured profile",
    );
    return jsonObject([
        jsonStringField("last_used_profile_id", lastUsed),
        jsonLongField("speech_commit_delay_seconds", speechCommitDelaySeconds),
        jsonLongField("output_recovery_ms", outputRecoveryMs),
        jsonLongField("thinking_music_fade_in_ms", fadeInMs),
        jsonLongField("thinking_music_fade_out_ms", fadeOutMs),
        jsonRawField("profiles", "[" ~ profileJson.join(",") ~ "]"),
    ]);
}

private JSONValue requireClientObject(JSONValue config, string clientId)
{
    ensureObjectField(config, "clients");
    auto client = clientId in config.object["clients"].object;
    enforce(
        client !is null && client.type == JSONType.object,
        "clients." ~ clientId ~ " config must be an object",
    );
    return *client;
}

private bool profileHasClientUi(JSONValue profile)
{
    if (profile.type != JSONType.object) return false;
    return ("accent" in profile.object) !is null;
}

private string clientProfileJson(string profileId, JSONValue profile)
{
    auto json = Json.object(profile);
    return jsonObject([
        jsonStringField("profile_id", profileId),
        jsonStringField("accent", json.text("accent")),
        jsonBoolField("auto_speak", json.boolean("auto_speak")),
        jsonBoolField("play_music", json.boolean("play_music")),
        jsonBoolField("keep_microphone_on", profileBooleanOr(profile, "keep_microphone_on", true)),
        jsonStringField("reasoning_mode", json.text("reasoning_mode")),
        jsonBoolField("activity_pane_open", json.boolean("activity_pane_open")),
        jsonBoolField("show_thinking", json.boolean("show_thinking")),
        jsonBoolField("show_compacted_context", json.boolean("show_compacted_context")),
        jsonStringField("language", json.text("language")),
        jsonStringField("model", json.text("model")),
    ]);
}

private void validateClientConfig(JSONValue value)
{
    auto json = Json.object(value);
    enforce(json.nonEmpty("last_used_profile_id"));
    json.integer("speech_commit_delay_seconds", 1, 12);
    json.integer("output_recovery_ms", 0, 30_000);
    json.integer("thinking_music_fade_in_ms", 0, 10_000);
    json.integer("thinking_music_fade_out_ms", 0, 10_000);
    auto profiles = json.array("profiles");
    enforce(profiles.value.array.length > 0, "Client config profiles must not be empty");
    foreach (profileValue; profiles.value.array) {
        auto profile = Json.object(profileValue);
        enforceSafeToken(profile.text("profile_id"), "Client config profile");
        profile.nonEmpty("accent");
        profile.boolean("auto_speak");
        profile.boolean("play_music");
        profile.boolean("keep_microphone_on");
        profile.boolean("activity_pane_open");
        profile.boolean("show_thinking");
        profile.boolean("show_compacted_context");
        profile.enumeration!ReasoningMode("reasoning_mode");
        profile.text("language");
        profile.text("model");
    }
}

private bool profileBooleanOr(JSONValue profile, string name, bool fallback)
{
    Json.object(profile);
    return (name in profile.object) is null
        ? fallback
        : Json.object(profile).boolean(name);
}

private void ensureObjectField(ref JSONValue value, string name)
{
    Json.object(value);
    auto existing = name in value.object;
    if (existing is null) {
        value.object[name] = parseJSON("{}");
        return;
    }
    Json.object(*existing, name);
}
