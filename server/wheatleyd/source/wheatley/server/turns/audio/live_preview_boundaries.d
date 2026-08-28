module wheatley.server.turns.audio.live_preview_boundaries;

import std.algorithm.searching : canFind, endsWith;
import std.array : appender, join;
import std.string : split, strip;

import wheatley.server.stt.transcription : SttTimedText, SttTranscription;
import wheatley.server.turns.audio.live_audio_settings : LivePreviewBoundarySettings;
import wheatley.server.turns.audio.live_transcript_text :
    normalizeLiveTranscript,
    speechTextFromTranscript;

struct StablePreviewBoundary
{
    bool found;
    string agreement;
    string prefixText;
    string tailText;
    long endMs;
    string kind;
}

StablePreviewBoundary[] stablePreviewBoundaries(
    SttTranscription transcription,
    double windowAudioSeconds,
    LivePreviewBoundarySettings settings,
)
{
    StablePreviewBoundary[] result;
    foreach (index, piece; transcription.timedText)
    {
        auto prefixText = timedText(transcription.timedText[0 .. index + 1]);
        auto tailText = timedText(transcription.timedText[index + 1 .. $]);
        auto prefixSpeech = speechTextFromTranscript(prefixText);
        auto tailSpeech = speechTextFromTranscript(tailText);
        if (!prefixSpeech.length
            && piece.endMs >= cast(long) (settings.stableMinAudioSeconds * 1_000.0)
            && windowAudioSeconds - cast(double) piece.endMs / 1_000.0
                >= settings.mutableMinAudioSeconds) {
            result ~= StablePreviewBoundary(
                true,
                "annotation",
                "",
                tailSpeech,
                piece.endMs,
                "annotation",
            );
            continue;
        }
        if (
            piece.endMs < cast(long) (settings.stableMinAudioSeconds * 1_000.0) ||
            windowAudioSeconds - cast(double) piece.endMs / 1_000.0 < settings.mutableMinAudioSeconds ||
            previewWordCount(prefixSpeech) < settings.stableMinWords ||
            previewWordCount(tailSpeech) < settings.mutableMinWords
        ) {
            continue;
        }

        string kind;
        if (hasStrongPreviewBoundary(prefixText))
            kind = "sentence";
        else if (
            windowAudioSeconds >= settings.softBoundaryWindowSeconds &&
            hasSoftPreviewBoundary(prefixText)
        )
            kind = "clause";
        else if (
            windowAudioSeconds >= settings.maxMutableWindowSeconds &&
            hasTimedWordBoundary(transcription.timedText, index)
        )
            kind = "word";
        else
            continue;

        result ~= StablePreviewBoundary(
            true,
            previewAgreement(prefixSpeech),
            prefixSpeech,
            tailSpeech,
            piece.endMs,
            kind,
        );
    }
    return result;
}

StablePreviewBoundary agreeingStableBoundary(
    StablePreviewBoundary[] boundaries,
    string[] previousAgreements,
)
{
    for (auto index = boundaries.length; index > 0; index--)
    {
        auto boundary = boundaries[index - 1];
        if (previousAgreements.canFind(boundary.agreement))
            return boundary;
    }
    return StablePreviewBoundary.init;
}

string[] boundaryAgreements(StablePreviewBoundary[] boundaries)
{
    string[] result;
    foreach (boundary; boundaries)
        result ~= boundary.agreement;
    return result;
}

private string timedText(SttTimedText[] pieces)
{
    auto result = appender!string;
    foreach (piece; pieces)
        result.put(piece.text);
    return result.data.strip;
}

private string previewAgreement(string text)
{
    return normalizeLiveTranscript(text);
}

long previewWordCount(string text)
{
    return cast(long) text.split.length;
}

private bool hasStrongPreviewBoundary(string text)
{
    auto value = text.strip;
    return value.endsWith(".") || value.endsWith("?") ||
        value.endsWith("!") || value.endsWith("…");
}

private bool hasSoftPreviewBoundary(string text)
{
    auto value = text.strip;
    return value.endsWith(",") || value.endsWith(";") || value.endsWith(":") ||
        value.endsWith("—") || value.endsWith("–") || value.endsWith("-");
}

private bool hasTimedWordBoundary(SttTimedText[] pieces, size_t index)
{
    if (index + 1 >= pieces.length || !pieces[index + 1].text.length)
        return false;
    auto next = pieces[index + 1].text[0];
    return next == ' ' || next == '\t' || next == '\r' || next == '\n';
}

unittest
{
    auto settings = LivePreviewBoundarySettings(2.5, 20.0, 5, 35, 50.0, 70.0);
    SttTimedText[] timed = [
        SttTimedText(" This", 0, 500),
        SttTimedText(" is", 500, 900),
        SttTimedText(" the", 900, 1_200),
        SttTimedText(" first", 1_200, 1_700),
        SttTimedText(" sentence", 1_700, 2_900),
        SttTimedText(".", 2_900, 3_000),
    ];
    foreach (index; 0 .. 35)
    {
        auto startMs = 3_100 + cast(long) index * 600;
        timed ~= SttTimedText(" tail", startMs, startMs + 500);
    }
    auto transcription = SttTranscription("", "en", 25_000, timed);
    auto boundaries = stablePreviewBoundaries(transcription, 25.0, settings);
    assert(boundaries.length == 1);
    assert(boundaries[0].prefixText == "This is the first sentence.");
    assert(previewWordCount(boundaries[0].tailText) == 35);
    assert(boundaries[0].kind == "sentence");
    assert(!agreeingStableBoundary(boundaries, null).found);
    assert(agreeingStableBoundary(boundaries, boundaryAgreements(boundaries)).found);
}

unittest
{
    auto settings = LivePreviewBoundarySettings(1.0, 1.0, 2, 1, 2.0, 4.0);
    SttTimedText[] timed = [
        SttTimedText(" [paper crinkling]", 0, 1_200),
        SttTimedText(" [background noise]", 1_200, 2_500),
        SttTimedText(" Hello", 2_500, 3_500),
    ];
    auto boundaries = stablePreviewBoundaries(
        SttTranscription("", "en", 3_500, timed),
        3.5,
        settings,
    );
    assert(boundaries.length >= 1);
    assert(boundaries[0].kind == "annotation");
    assert(!boundaries[0].prefixText.length);
}

unittest
{
    auto settings = LivePreviewBoundarySettings(1.0, 1.0, 2, 1, 2.0, 4.0);
    SttTimedText[] timed = [
        SttTimedText(" [music] Hello", 0, 900),
        SttTimedText(" there.", 900, 1_500),
        SttTimedText(" [noise] Later", 1_500, 2_500),
    ];
    auto boundaries = stablePreviewBoundaries(
        SttTranscription("", "en", 2_500, timed),
        2.5,
        settings,
    );
    assert(boundaries.length == 1);
    assert(boundaries[0].prefixText == "Hello there.");
    assert(boundaries[0].tailText == "Later");
    assert(boundaries[0].agreement == "hello there");
}
