module wheatley.server.turns.audio.live_final_transcript;

import std.algorithm.comparison : max;
import std.string : split, strip;

import wheatley.server.turns.audio.live_audio_settings : LiveFinalSelectionSettings;
import wheatley.server.turns.audio.live_transcript_text :
    isKnownNoSpeechTranscript,
    speechTextFromTranscript;
import wheatley.server.turns.audio.user_text : combinedAudioUserText;

struct FinalTranscriptSelection
{
    bool ignore;
    bool usedPreviewDraft;
    bool incompleteFinal;
    string transcriptText;
    string userText;
}

FinalTranscriptSelection selectFinalTranscript(
    string finalTranscriptText,
    long finalCoveredAudioMs,
    string previewDraftText,
    string typedText,
    double voiceSeconds,
    double audioSeconds,
    LiveFinalSelectionSettings settings,
)
{
    auto finalText = speechTextFromTranscript(finalTranscriptText);
    auto draftText = speechTextFromTranscript(previewDraftText);

    if (
        finalCoverageIncomplete(finalCoveredAudioMs, audioSeconds, settings) &&
        wordCount(draftText) >= settings.minDraftWords
    ) {
        return FinalTranscriptSelection(
            false,
            true,
            true,
            draftText,
            combinedAudioUserText(typedText, draftText),
        );
    }

    if (
        shouldUsePreviewDraftAsFinal(finalText, draftText, voiceSeconds, audioSeconds, settings)
    ) {
        return FinalTranscriptSelection(
            false,
            true,
            false,
            draftText,
            combinedAudioUserText(typedText, draftText),
        );
    }

    if (isKnownNoSpeechTranscript(finalText)) {
        return FinalTranscriptSelection(true, false, false, "", "");
    }

    return FinalTranscriptSelection(
        false,
        false,
        false,
        finalText,
        combinedAudioUserText(typedText, finalText),
    );
}

bool finalCoverageIncomplete(
    long coveredAudioMs,
    double audioSeconds,
    LiveFinalSelectionSettings settings,
)
{
    if (coveredAudioMs <= 0 || audioSeconds <= settings.coverageMinAudioSeconds) return false;
    return coveredAudioMs + settings.coverageSlackMs < cast(long) (audioSeconds * 1_000);
}

string finalTranscriptSource(FinalTranscriptSelection selection)
{
    if (!selection.usedPreviewDraft) return "final_stt";
    return selection.incompleteFinal
        ? "accepted_draft_incomplete_final"
        : "accepted_draft_unreliable_final";
}

bool shouldUsePreviewDraftAsFinal(
    string finalText,
    string draftText,
    double voiceSeconds,
    double audioSeconds,
    LiveFinalSelectionSettings settings,
)
{
    auto draftWords = wordCount(draftText);
    if (draftWords < settings.minDraftWords) return false;
    if (isKnownNoSpeechTranscript(finalText)) return true;

    auto finalWords = wordCount(finalText);
    if (finalWords > settings.maxWeakFinalWords) return false;
    if (draftWords < finalWords + settings.draftWordAdvantage) return false;
    return weakVoiceEvidence(voiceSeconds, audioSeconds, settings);
}

bool weakVoiceEvidence(
    double voiceSeconds,
    double audioSeconds,
    LiveFinalSelectionSettings settings,
)
{
    if (audioSeconds <= 0.0) return true;
    return voiceSeconds < settings.weakVoiceSeconds
        || voiceSeconds / max(audioSeconds, 0.001) < settings.weakVoiceRatio;
}

size_t wordCount(string text)
{
    size_t count;
    foreach (word; text.strip.split) {
        if (word.strip.length) count++;
    }
    return count;
}

private LiveFinalSelectionSettings testFinalSelectionSettings()
{
    return LiveFinalSelectionSettings(4, 3, 4, 30.0, 5_000, 0.8, 0.15);
}

unittest
{
    auto settings = testFinalSelectionSettings();
    auto selected = selectFinalTranscript(
        "Okay.",
        0,
        "This is the full displayed draft text.",
        "",
        0.3,
        12.0,
        settings,
    );
    assert(!selected.ignore);
    assert(selected.usedPreviewDraft);
    assert(selected.userText == "This is the full displayed draft text.");
}

unittest
{
    auto settings = testFinalSelectionSettings();
    auto selected = selectFinalTranscript(
        "Okay.",
        0,
        "",
        "",
        0.3,
        12.0,
        settings,
    );
    assert(!selected.ignore);
    assert(!selected.usedPreviewDraft);
    assert(selected.transcriptText == "Okay.");
}

unittest
{
    auto settings = testFinalSelectionSettings();
    auto selected = selectFinalTranscript(
        "Reply with exactly audio smoke okay.",
        0,
        "Reply with exactly audio smoke okay.",
        "",
        2.0,
        4.0,
        settings,
    );
    assert(!selected.ignore);
    assert(!selected.usedPreviewDraft);
    assert(selected.userText == "Reply with exactly audio smoke okay.");
}

unittest
{
    auto settings = testFinalSelectionSettings();
    auto selected = selectFinalTranscript(
        "[playing music] *clears throat* (click)",
        0,
        "",
        "",
        0.0,
        3.0,
        settings,
    );
    assert(selected.ignore);
    assert(!selected.transcriptText.length);
}

unittest
{
    auto settings = testFinalSelectionSettings();
    auto selected = selectFinalTranscript(
        "Hello [door opens] there.",
        0,
        "",
        "",
        1.0,
        3.0,
        settings,
    );
    assert(!selected.ignore);
    assert(selected.transcriptText == "Hello there.");
    assert(selected.userText == "Hello there.");
}
