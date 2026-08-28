module wheatley.server.turns.audio.live_audio_settings;

import wheatley.server.api.core.config : ServerConfig;
import wheatley.common.api.profile_startup : ProfileSessionResumeAnswers;
import wheatley.server.profile.runtime : ResolvedSessionConfig;
import wheatley.server.profiles.config_properties :
    requiredConfigInt,
    requiredConfigReal;
import wheatley.server.startup.session_resume_answers : loadSessionResumeAnswers;
import wheatley.server.stt.runtime_settings :
    SttRuntimeSettings,
    loadFinalSttRuntimeSettings,
    loadPreviewSttRuntimeSettings;

struct LivePreviewBoundarySettings
{
    double stableMinAudioSeconds;
    double mutableMinAudioSeconds;
    long stableMinWords;
    long mutableMinWords;
    double softBoundaryWindowSeconds;
    double maxMutableWindowSeconds;
}

struct LiveVadAdaptiveSettings
{
    double startThreshold;
    double continueThreshold;
    double noiseFloorStartMultiplier;
    double noiseFloorContinueMultiplier;
    double noiseFloorAlpha;
    double continueThresholdScale;
}

struct LiveSessionResumeAudioSettings
{
    double minSpeechSeconds;
    double silenceSeconds;
    double maxWaitSeconds;
    double trailingSilenceKeepSeconds;
    double maxUtteranceSeconds;
    double partialTranscriptIntervalSeconds;
    double partialTranscriptMinAudioSeconds;
}

struct LiveFinalSelectionSettings
{
    long minDraftWords;
    long maxWeakFinalWords;
    long draftWordAdvantage;
    double coverageMinAudioSeconds;
    long coverageSlackMs;
    double weakVoiceSeconds;
    double weakVoiceRatio;
}

struct LiveAudioRuntimeSettings
{
    int sampleRate;
    ushort channels;
    double vadThreshold;
    double minSpeechSeconds;
    double silenceSeconds;
    double maxWaitSeconds;
    double preRollSeconds;
    double trailingSilenceKeepSeconds;
    double trailingSilenceKeepCapSeconds;
    double maxUtteranceSeconds;
    double partialTranscriptIntervalSeconds;
    double partialTranscriptMinAudioSeconds;
    double previewVoiceGraceSeconds;
    long previewStablePromptWords;
    double draftEndpointStableMinSeconds;
    long spokenSubmitConfirmationCount;
    long responseMusicDelayMs;
    bool shortChoiceRecognition;
    LivePreviewBoundarySettings previewBoundaries;
    LiveVadAdaptiveSettings vadAdaptive;
    LiveSessionResumeAudioSettings sessionResume;
    LiveFinalSelectionSettings finalSelection;
    ProfileSessionResumeAnswers resumeAnswers;
    SttRuntimeSettings previewStt;
    SttRuntimeSettings finalStt;
}

LiveAudioRuntimeSettings loadLiveAudioRuntimeSettings(
    ServerConfig config,
    ResolvedSessionConfig resolved,
)
{
    auto props = resolved.configIndex;
    LiveAudioRuntimeSettings settings;
    settings.sampleRate = 16_000;
    settings.channels = 1;
    settings.vadThreshold = requiredConfigReal(props, "audio.vad.threshold");
    settings.minSpeechSeconds = requiredConfigReal(props, "audio.endpoint.min_speech_seconds");
    settings.maxWaitSeconds = requiredConfigReal(props, "audio.endpoint.max_wait_seconds");
    settings.preRollSeconds = requiredConfigReal(props, "audio.endpoint.pre_roll_seconds");
    settings.trailingSilenceKeepSeconds = requiredConfigReal(
        props,
        "audio.endpoint.trailing_silence_keep_seconds",
    );
    settings.trailingSilenceKeepCapSeconds = requiredConfigReal(
        props,
        "audio.endpoint.trailing_silence_keep_cap_seconds",
    );
    settings.maxUtteranceSeconds = requiredConfigReal(props, "audio.endpoint.max_utterance_seconds");
    settings.partialTranscriptIntervalSeconds = requiredConfigReal(
        props,
        "audio.partial_transcript.interval_seconds",
    );
    settings.partialTranscriptMinAudioSeconds = requiredConfigReal(
        props,
        "audio.partial_transcript.min_audio_seconds",
    );
    settings.previewVoiceGraceSeconds = requiredConfigReal(
        props,
        "audio.preview.voice_grace_seconds",
    );
    settings.previewStablePromptWords = requiredConfigInt(
        props,
        "audio.preview.stable_prompt_words",
        1,
        1_000,
    );
    settings.draftEndpointStableMinSeconds = requiredConfigReal(
        props,
        "audio.draft_endpoint.stable_min_seconds",
    );
    settings.spokenSubmitConfirmationCount = requiredConfigInt(
        props,
        "audio.spoken_submit.confirmation_count",
        1,
        10,
    );
    settings.responseMusicDelayMs = requiredConfigInt(
        props,
        "runtime.response_music_delay_ms",
        0,
        60_000,
    );
    settings.previewBoundaries = LivePreviewBoundarySettings(
        requiredConfigReal(props, "audio.preview.stable_min_audio_seconds"),
        requiredConfigReal(props, "audio.preview.mutable_min_audio_seconds"),
        requiredConfigInt(props, "audio.preview.stable_min_words", 1, 1_000),
        requiredConfigInt(props, "audio.preview.mutable_min_words", 1, 1_000),
        requiredConfigReal(props, "audio.preview.soft_boundary_window_seconds"),
        requiredConfigReal(props, "audio.preview.max_mutable_window_seconds"),
    );
    settings.vadAdaptive = LiveVadAdaptiveSettings(
        requiredConfigReal(props, "audio.vad.start_threshold"),
        requiredConfigReal(props, "audio.vad.continue_threshold"),
        requiredConfigReal(props, "audio.vad.noise_floor_start_multiplier"),
        requiredConfigReal(props, "audio.vad.noise_floor_continue_multiplier"),
        requiredConfigReal(props, "audio.vad.noise_floor_alpha"),
        requiredConfigReal(props, "audio.vad.continue_threshold_scale"),
    );
    settings.sessionResume = LiveSessionResumeAudioSettings(
        requiredConfigReal(props, "audio.session_resume.min_speech_seconds"),
        requiredConfigReal(props, "audio.session_resume.silence_seconds"),
        requiredConfigReal(props, "audio.session_resume.max_wait_seconds"),
        requiredConfigReal(props, "audio.session_resume.trailing_silence_keep_seconds"),
        requiredConfigReal(props, "audio.session_resume.max_utterance_seconds"),
        requiredConfigReal(props, "audio.session_resume.partial_transcript.interval_seconds"),
        requiredConfigReal(props, "audio.session_resume.partial_transcript.min_audio_seconds"),
    );
    settings.finalSelection = LiveFinalSelectionSettings(
        requiredConfigInt(props, "audio.final_selection.min_draft_words", 1, 1_000),
        requiredConfigInt(props, "audio.final_selection.max_weak_final_words", 0, 1_000),
        requiredConfigInt(props, "audio.final_selection.draft_word_advantage", 0, 1_000),
        requiredConfigReal(props, "audio.final_selection.coverage_min_audio_seconds"),
        requiredConfigInt(props, "audio.final_selection.coverage_slack_ms", 0, 60_000),
        requiredConfigReal(props, "audio.final_selection.weak_voice_seconds"),
        requiredConfigReal(props, "audio.final_selection.weak_voice_ratio"),
    );
    settings.resumeAnswers = loadSessionResumeAnswers(props, resolved.language);
    settings.previewStt = loadPreviewSttRuntimeSettings(config, resolved);
    settings.finalStt = loadFinalSttRuntimeSettings(config, resolved);

    return settings;
}

LiveAudioRuntimeSettings applySessionResumeChoiceSettings(LiveAudioRuntimeSettings settings)
{
    auto resume = settings.sessionResume;
    settings.minSpeechSeconds = resume.minSpeechSeconds;
    settings.silenceSeconds = resume.silenceSeconds;
    settings.maxWaitSeconds = resume.maxWaitSeconds;
    settings.trailingSilenceKeepSeconds = resume.trailingSilenceKeepSeconds;
    settings.maxUtteranceSeconds = resume.maxUtteranceSeconds;
    settings.partialTranscriptIntervalSeconds = resume.partialTranscriptIntervalSeconds;
    settings.partialTranscriptMinAudioSeconds = resume.partialTranscriptMinAudioSeconds;
    settings.shortChoiceRecognition = true;
    return settings;
}
