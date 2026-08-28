module wheatley.server.stt.runtime_settings;

import std.exception : enforce;
import std.algorithm.searching : startsWith;
import std.path : baseName;
import std.string : strip;

import wheatley.common.choice : requireChoice;

import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.profile.runtime : ResolvedSessionConfig;
import wheatley.server.profiles.config_properties :
    ProfileConfigIndex,
    languageTextOverride,
    requiredConfigInt,
    requiredConfigReal,
    requiredConfigText;
import wheatley.common.runtime.local_tools :
    resolveBundledExecutable,
    resolveAppDataPath;
import wheatley.common.safe_token : enforceSafeToken;

struct SttRuntimeSettings
{
    SttModelRole role;
    string appDataRoot;
    SttRecognizerType recognizerType;
    string serverBinary;
    string model;
    string endpoint;
    string language;
    long beamSize;
    long maxContextTokens;
    double requestTimeoutSeconds;
}

enum SttModelRole
{
    preview,
    finalTurn,
}

enum SttRecognizerType
{
    localWhisperCpp,
    remoteWhisperCpp,
}

string sttRuntimeModelName(SttRuntimeSettings settings)
{
    auto model = baseName(settings.model.strip);
    return "whisper.cpp:" ~ (model.length ? model : "unknown");
}

SttRuntimeSettings loadPreviewSttRuntimeSettings(
    ServerConfig serverConfig,
    ResolvedSessionConfig resolved,
)
{
    return loadSttRuntimeSettings(serverConfig, resolved, SttModelRole.preview);
}

SttRuntimeSettings loadFinalSttRuntimeSettings(
    ServerConfig serverConfig,
    ResolvedSessionConfig resolved,
)
{
    return loadSttRuntimeSettings(serverConfig, resolved, SttModelRole.finalTurn);
}

private SttRuntimeSettings loadSttRuntimeSettings(
    ServerConfig serverConfig,
    ResolvedSessionConfig resolved,
    SttModelRole role,
)
{
    auto props = resolved.configIndex;
    auto language = requestedSttLanguage(resolved.language);
    auto root = "stt." ~ phaseConfigKey(role);

    SttRuntimeSettings settings;
    settings.role = role;
    settings.appDataRoot = serverConfig.appDataRoot;
    auto recognizerType = requiredConfigText(props, root ~ ".type");
    requireChoice!("local_whisper_cpp", "remote_whisper_cpp")(recognizerType, root ~ ".type");
    settings.recognizerType = recognizerType == "local_whisper_cpp"
        ? SttRecognizerType.localWhisperCpp
        : SttRecognizerType.remoteWhisperCpp;
    settings.model = requiredConfigText(props, root ~ ".model");
    settings.language = language.length
        ? languageTextOverride(props, language, "stt_language", language)
        : "";
    settings.beamSize = requiredConfigInt(props, root ~ ".beam_size");
    settings.maxContextTokens = requiredConfigInt(props, root ~ ".max_context_tokens");
    settings.requestTimeoutSeconds = requiredConfigReal(props, "stt.request_timeout_seconds");

    enforce(
        settings.maxContextTokens >= -1,
        "STT max context tokens must be -1 or greater",
    );
    final switch (settings.recognizerType) {
        case SttRecognizerType.localWhisperCpp:
            settings.serverBinary = resolveBundledExecutable(
                requiredConfigText(props, root ~ ".server_binary"),
                "whisper.cpp server binary",
                serverConfig.appDataRoot,
            );
            settings.model = resolveAppDataPath(
                settings.model,
                whisperModelLabel(role),
                serverConfig.appDataRoot,
            );
            break;
        case SttRecognizerType.remoteWhisperCpp:
            settings.endpoint = normalizeRemoteEndpoint(requiredConfigText(props, root ~ ".endpoint"));
            break;
    }
    return settings;
}

private string normalizeRemoteEndpoint(string value)
{
    auto endpoint = value.strip;
    enforce(endpoint.startsWith("http://"), "Remote STT endpoint must use http://");
    while (endpoint.length && endpoint[$ - 1] == '/') endpoint = endpoint[0 .. $ - 1];
    enforce(endpoint.length > "http://".length, "Remote STT endpoint host is required");
    return endpoint;
}

private string phaseConfigKey(SttModelRole role)
{
    final switch (role) {
        case SttModelRole.preview:
            return "preview";
        case SttModelRole.finalTurn:
            return "final";
    }
}

private string whisperModelLabel(SttModelRole role)
{
    final switch (role) {
        case SttModelRole.preview:
            return "Whisper preview model";
        case SttModelRole.finalTurn:
            return "Whisper final model";
    }
}

private string requestedSttLanguage(string requestedLanguage)
{
    auto language = requestedLanguage;
    if (language.length) enforceSafeToken(language, "STT language");
    return language;
}

unittest
{
    import std.exception : assertThrown;

    assert(normalizeRemoteEndpoint(" http://speech-server.local:8791/ ") ==
        "http://speech-server.local:8791");
    assertThrown!Exception(normalizeRemoteEndpoint("https://speech-server.local:8791"));
    assertThrown!Exception(normalizeRemoteEndpoint("http://"));
}
