module wheatley.server.tts.on_demand;

import std.exception : enforce;
import std.file : getSize;

import wheatley.common.api.tts : TtsResponse;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.profile.runtime : ProfileRuntime;
import wheatley.server.tts.generated_artifacts : generatedTtsArtifactId, sha256File;
import wheatley.server.tts.opus_encoding : encodeAssistantSpeechWavAsOpus;
import wheatley.server.tts.piper :
    applyPiperPronunciationReplacements,
    runPiper;
import wheatley.server.tts.runtime_settings : loadTtsRuntimeSettings;
import wheatley.server.tts.spoken_text : normalizeSpokenText;
import wheatley.server.tts.supertonic : runSupertonic;
import wheatley.common.runtime.temp_files : removeQuietly, temporaryRuntimeFile;

class OnDemandTts
{
    private ServerConfig serverConfig;
    private HistoryStore store;
    private ProfileRuntime profiles;
    private RuntimeFiles files;

    this(
        ServerConfig serverConfig,
        HistoryStore store,
        ProfileRuntime profiles,
        RuntimeFiles files,
    )
    {
        this.serverConfig = serverConfig;
        this.store = store;
        this.profiles = profiles;
        this.files = files;
    }

    TtsResponse synthesize(string profileId, string inputText, string requestedLanguage = "")
    {
        enforce(store.profileExists(profileId), "Profile not found");

        auto text = normalizeSpokenText(inputText);
        enforce(text.length > 0, "TTS text is required");

        auto resolved = profiles.resolveSession(profileId, requestedLanguage);
        auto settings = loadTtsRuntimeSettings(serverConfig, resolved);
        enforce(settings.enabled, "TTS is disabled for profile " ~ profileId);
        auto spokenText = settings.backend == "piper"
            ? applyPiperPronunciationReplacements(text, settings.piper)
            : text;
        auto artifactId = generatedTtsArtifactId(profileId, spokenText);
        auto target = files.generatedTtsTarget(profileId, artifactId);
        auto wavPath = temporaryRuntimeFile(
            serverConfig.appDataRoot,
            "wheatleyd",
            "tts-synthesis",
            "speech-" ~ artifactId,
            ".wav",
        );
        scope(exit) removeQuietly(wavPath);
        scope(failure) files.removeGeneratedTts(profileId, artifactId);
        string provider;
        string model;
        if (settings.backend == "piper") {
            runPiper(settings.piper, spokenText, wavPath);
            provider = "piper";
            model = settings.piper.model;
        } else if (settings.backend == "supertonic") {
            runSupertonic(settings.supertonic, spokenText, settings.language, wavPath);
            provider = "supertonic";
            model = "supertonic-3";
        } else {
            throw new Exception("On-demand TTS does not support backend " ~ settings.backend);
        }
        encodeAssistantSpeechWavAsOpus(
            serverConfig,
            wavPath,
            target.path,
            settings.assistantOpusBitrateKbps,
            settings.piper.requestTimeoutSeconds,
        );

        auto bytes = getSize(target.path);
        return TtsResponse(
            artifactId,
            profileId,
            nowIso(),
            target.mediaType,
            bytes,
            sha256File(target.path),
            provider,
            model,
            settings.voice,
            settings.language,
            target.relativePath,
            "",
        );
    }
}
