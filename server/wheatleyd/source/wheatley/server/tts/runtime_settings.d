module wheatley.server.tts.runtime_settings;

import std.algorithm : startsWith;

import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.profile.runtime : ResolvedSessionConfig;
import wheatley.server.profiles.config_properties :
    ProfileConfigIndex,
    languageConfigPath,
    requiredConfigBool,
    requiredConfigInt,
    requiredConfigReal,
    requiredConfigText;
import wheatley.common.runtime.local_tools :
    resolveAppDataPath,
    resolveBundledExecutable,
    resolveLocalExecutable;
import wheatley.server.tts.piper_types : PiperSynthesisSettings;
import wheatley.server.tts.supertonic : SupertonicSynthesisSettings;
import wheatley.server.tts.opus_encoding : enforceAssistantSpeechOpusBitrate;

struct TtsRuntimeSettings
{
    bool enabled;
    string backend;
    string voice;
    string language;
    long assistantOpusBitrateKbps;
    PiperSynthesisSettings piper;
    SupertonicSynthesisSettings supertonic;
}

TtsRuntimeSettings loadTtsRuntimeSettings(
    ServerConfig serverConfig,
    ResolvedSessionConfig resolved,
)
{
    auto props = resolved.configIndex;
    TtsRuntimeSettings settings;
    settings.enabled = requiredConfigBool(props, "tts.enabled");
    settings.backend = requiredConfigText(props, "tts.backend");
    settings.voice = requiredConfigText(props, "tts.voice");
    settings.assistantOpusBitrateKbps = requiredConfigInt(props, "tts.assistant_opus_bitrate_kbps");
    enforceAssistantSpeechOpusBitrate(settings.assistantOpusBitrateKbps);
    settings.piper.binary = requiredConfigText(props, "tts.piper_binary");
    settings.piper.model = requiredConfigText(props, "tts.piper_model");
    settings.piper.config = props.textValue("tts.piper_config", "");
    settings.piper.hasSpeaker = props.hasNonNullValue("tts.piper_speaker");
    settings.piper.speaker = props.intValue("tts.piper_speaker", 0);
    settings.piper.lengthScale = requiredConfigReal(props, "tts.length_scale");
    settings.piper.noiseScale = requiredConfigReal(props, "tts.noise_scale");
    settings.piper.noiseWScale = requiredConfigReal(props, "tts.noise_w_scale");
    settings.piper.sentenceSilence = requiredConfigReal(props, "tts.sentence_silence");
    settings.piper.volume = requiredConfigReal(props, "tts.volume");
    settings.piper.requestTimeoutSeconds = requiredConfigReal(props, "tts.request_timeout_seconds");
    settings.supertonic.python = requiredConfigText(props, "tts.supertonic_python");
    settings.supertonic.voice = requiredConfigText(props, "tts.supertonic_voice");
    settings.supertonic.speed = requiredConfigReal(props, "tts.supertonic_speed");
    settings.supertonic.steps = requiredConfigInt(props, "tts.supertonic_steps");
    settings.supertonic.requestTimeoutSeconds = settings.piper.requestTimeoutSeconds;
    settings.language = resolved.language;
    settings.piper.pronunciationReplacements = piperPronunciationReplacements(props);

    if (settings.language.length) {
        applyLanguageOverrides(settings, props, settings.language);
    }

    if (settings.backend == "piper") {
        settings.piper.binary = resolveBundledExecutable(settings.piper.binary, "Piper binary", serverConfig.appDataRoot);
        settings.piper.model = resolveAppDataPath(settings.piper.model, "Piper model", serverConfig.appDataRoot);
        if (settings.piper.config.length) {
            settings.piper.config = resolveAppDataPath(settings.piper.config, "Piper config", serverConfig.appDataRoot);
        }
    } else if (settings.backend == "supertonic") {
        version (Windows) {
            if (settings.supertonic.python == "environments/tts/bin/python") {
                settings.supertonic.python = "environments/tts/Scripts/python.exe";
            }
        }
        settings.supertonic.python = resolveLocalExecutable(
            settings.supertonic.python,
            "Supertonic Python runtime",
            serverConfig.appDataRoot,
        );
        settings.voice = settings.supertonic.voice;
    }
    return settings;
}

private void applyLanguageOverrides(ref TtsRuntimeSettings settings, ProfileConfigIndex props, string language)
{
    overrideText(settings.backend, props, languageConfigPath(language, "tts_backend"));
    overrideText(settings.voice, props, languageConfigPath(language, "tts_voice"));
    overrideText(settings.piper.model, props, languageConfigPath(language, "tts_piper_model"));
    overrideText(settings.supertonic.voice, props, languageConfigPath(language, "tts_supertonic_voice"));
    auto piperConfigPath = languageConfigPath(language, "tts_piper_config");
    if (props.has(piperConfigPath)) {
        settings.piper.config = props.textValue(piperConfigPath, "");
    }
    auto piperSpeakerPath = languageConfigPath(language, "tts_piper_speaker");
    if (props.has(piperSpeakerPath)) {
        settings.piper.hasSpeaker = props.hasNonNullValue(piperSpeakerPath);
        settings.piper.speaker = props.intValue(piperSpeakerPath, 0);
    }

    settings.piper.lengthScale = props.realValue(
        languageConfigPath(language, "tts_length_scale"),
        settings.piper.lengthScale,
    );
    settings.piper.noiseScale = props.realValue(
        languageConfigPath(language, "tts_noise_scale"),
        settings.piper.noiseScale,
    );
    settings.piper.noiseWScale = props.realValue(
        languageConfigPath(language, "tts_noise_w_scale"),
        settings.piper.noiseWScale,
    );
    settings.piper.sentenceSilence = props.realValue(
        languageConfigPath(language, "tts_sentence_silence"),
        settings.piper.sentenceSilence,
    );
    settings.piper.volume = props.realValue(languageConfigPath(language, "tts_volume"), settings.piper.volume);
    settings.supertonic.speed = props.realValue(
        languageConfigPath(language, "tts_supertonic_speed"),
        settings.supertonic.speed,
    );
    settings.supertonic.steps = props.intValue(
        languageConfigPath(language, "tts_supertonic_steps"),
        settings.supertonic.steps,
    );
}

private void overrideText(ref string target, ProfileConfigIndex props, string path)
{
    auto value = props.textValue(path, "");
    if (value.length) target = value;
}

private string[string] piperPronunciationReplacements(ProfileConfigIndex props)
{
    enum prefix = "tts.piper_pronunciation_replacements.";
    string[string] replacements;
    foreach (path, property; props.byPath) {
        if (path.startsWith(prefix) && property.valueType == "text") {
            replacements[path[prefix.length .. $]] = property.textValue;
        }
    }
    return replacements;
}
