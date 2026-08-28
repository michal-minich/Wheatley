module wheatley.server.turns.audio.final_transcription;

import core.time : MonoTime;
import std.file : write;

import wheatley.server.stt.whisper_cpp : WhisperCppWorkers;
import wheatley.server.stt.runtime_settings :
    SttRuntimeSettings,
    sttRuntimeModelName;
import wheatley.common.runtime.temp_files : removeQuietly;
import wheatley.server.stt.transcription : SttExecutionMetrics;
import wheatley.server.turns.audio.pcm16_wav : temporarySttWavPath;
import wheatley.server.turns.audio.user_text : combinedAudioUserText;

struct FinalAudioTurnTranscription
{
    string transcriptText;
    string userText;
    string language;
    string modelName;
    long durationMs;
    long coveredAudioMs;
    long maxContextTokens;
    SttExecutionMetrics execution;
}

FinalAudioTurnTranscription transcribeFinalAudioTurn(
    WhisperCppWorkers workers,
    SttRuntimeSettings settings,
    string requestedLanguage,
    string audioPath,
    string typedText,
)
{
    auto started = MonoTime.currTime;
    auto transcript = workers.transcribe(
        settings,
        audioPath,
        typedText,
        true,
    );
    auto durationMs = cast(long) (MonoTime.currTime - started).total!"msecs";
    return FinalAudioTurnTranscription(
        transcript.text,
        combinedAudioUserText(typedText, transcript.text),
        requestedLanguage.length ? requestedLanguage : transcript.language,
        sttRuntimeModelName(settings),
        durationMs,
        transcript.coveredAudioMs,
        settings.maxContextTokens,
        transcript.execution,
    );
}

FinalAudioTurnTranscription transcribeFinalAudioTurnWavBytes(
    WhisperCppWorkers workers,
    SttRuntimeSettings settings,
    string requestedLanguage,
    const(ubyte)[] wavBytes,
    string typedText,
)
{
    auto wavPath = temporarySttWavPath(settings.appDataRoot, "final");
    scope(exit) removeQuietly(wavPath);
    write(wavPath, wavBytes);
    return transcribeFinalAudioTurn(workers, settings, requestedLanguage, wavPath, typedText);
}
