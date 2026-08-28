module wheatley.server.turns.audio.live_transcript_text;

import std.algorithm.searching : canFind;
import std.ascii : isWhite;
import std.array : appender, join;
import std.string : split, strip, toLower;

struct SpokenSubmitCommand
{
    bool found;
    string promptText;
    long repetitions;
}

SpokenSubmitCommand spokenSubmitCommand(string text)
{
    auto remainingEnd = text.length;
    long repetitions;
    while (remainingEnd) {
        auto wordEnd = remainingEnd;
        while (
            wordEnd && (
                isWhite(text[wordEnd - 1])
                || text[wordEnd - 1] == '.'
                || text[wordEnd - 1] == '!'
            )
        ) wordEnd--;

        auto wordStart = wordEnd;
        while (wordStart && !isWhite(text[wordStart - 1])) wordStart--;
        if (text[wordStart .. wordEnd].toLower != "submit")
            break;
        repetitions++;
        remainingEnd = wordStart;
    }
    if (!repetitions)
        return SpokenSubmitCommand.init;

    return SpokenSubmitCommand(true, text[0 .. remainingEnd].strip, repetitions);
}

bool isKnownNoSpeechTranscript(string text)
{
    return isKnownNormalizedNoSpeechTranscript(
        normalizeLiveTranscript(speechTextFromTranscript(text)),
    );
}

string speechTextFromTranscript(string text)
{
    auto cleaned = appender!string;
    size_t index;
    while (index < text.length)
    {
        auto ch = text[index];
        if (ch == '[' || ch == '(')
        {
            auto close = ch == '[' ? ']' : ')';
            auto closeIndex = findChar(text, index + 1, close);
            if (closeIndex < text.length
                && isRecognizedAnnotation(text[index + 1 .. closeIndex]))
            {
                cleaned.put(' ');
                index = closeIndex + 1;
                continue;
            }
        }
        if (ch == '*')
        {
            auto markerLength = starRunLength(text, index);
            auto closeIndex = findStarRun(text, index + markerLength, markerLength);
            if (closeIndex < text.length
                && isRecognizedAnnotation(text[index + markerLength .. closeIndex]))
            {
                cleaned.put(' ');
                index = closeIndex + markerLength;
                continue;
            }
        }
        cleaned.put(ch);
        index++;
    }
    return cleaned.data.split.join(" ").strip;
}

bool isRecognizedAnnotation(string text)
{
    auto normalized = normalizeLiveTranscript(text);
    if (!normalized.length) return true;
    foreach (marker; [
        "audio", "applause", "background", "beep", "breath", "click",
        "cough", "crinkl", "door", "footstep", "laugh", "music", "noise",
        "paper", "ring", "rustl", "sigh", "silence", "sound", "throat",
        "typing", "wind",
    ]) if (normalized.canFind(marker)) return true;
    return false;
}

string normalizeLiveTranscript(string text)
{
    string[] words;
    foreach (word; replacePreviewSeparators(text.toLower).split)
    {
        auto normalized = word.strip;
        if (normalized.length)
            words ~= normalized;
    }
    return words.join(" ");
}

private size_t findChar(string text, size_t start, char expected)
{
    foreach (index; start .. text.length)
    {
        if (text[index] == expected)
            return index;
    }
    return text.length;
}

private size_t starRunLength(string text, size_t start)
{
    size_t length;
    while (start + length < text.length && text[start + length] == '*')
        length++;
    return length;
}

private size_t findStarRun(string text, size_t start, size_t expectedLength)
{
    auto index = start;
    while (index < text.length)
    {
        if (text[index] != '*')
        {
            index++;
            continue;
        }
        auto length = starRunLength(text, index);
        if (length == expectedLength)
            return index;
        index += length;
    }
    return text.length;
}

bool isKnownNormalizedNoSpeechTranscript(string normalized)
{
    return !normalized.length
        || normalized.canFind("castingwords")
        || normalized.canFind("thanks for watching")
        || normalized.canFind("subtitles by");
}

private string replacePreviewSeparators(string text)
{
    auto normalized = text.dup;
    foreach (index; 0 .. normalized.length)
    {
        auto ch = normalized[index];
        if (!isPreviewWordChar(ch))
            normalized[index] = ' ';
    }
    return normalized.idup;
}

private bool isPreviewWordChar(char ch)
{
    return (ch >= 'a' && ch <= 'z')
        || (ch >= 'A' && ch <= 'Z')
        || (ch >= '0' && ch <= '9')
        || ch >= 0x80;
}

unittest
{
    assert(isKnownNoSpeechTranscript("."));
    assert(isKnownNoSpeechTranscript("..."));
    assert(isKnownNoSpeechTranscript(" . . "));
    assert(!isKnownNoSpeechTranscript("Okay."));
    assert(isKnownNoSpeechTranscript("[door opens]"));
    assert(!isKnownNoSpeechTranscript("Let's go."));
    assert(!isKnownNoSpeechTranscript("thank you."));
    assert(!isKnownNoSpeechTranscript("hello there."));
    assert(!isKnownNoSpeechTranscript("Reply with exactly audio smoke okay."));
}

unittest
{
    auto command = spokenSubmitCommand("Explain this carefully. Submit!");
    assert(command.found);
    assert(command.promptText == "Explain this carefully.");
    assert(spokenSubmitCommand("Hello SUBMIT...!!  ").promptText == "Hello");
    assert(spokenSubmitCommand("Hello submit ! !").promptText == "Hello");
    assert(!spokenSubmitCommand("We should submit the form tomorrow.").found);
    assert(!spokenSubmitCommand("Please submit?").found);
    assert(spokenSubmitCommand("Submit.").found);
    auto repeated = spokenSubmitCommand("Explain this. Submit. Submit! submit");
    assert(repeated.found);
    assert(repeated.promptText == "Explain this.");
    assert(repeated.repetitions == 3);
    assert(!spokenSubmitCommand("submission").found);
}

unittest
{
    assert(speechTextFromTranscript("[playing music] *clears throat* (click)") == "");
    assert(speechTextFromTranscript("Hello [door opens] there") == "Hello there");
    assert(speechTextFromTranscript("Hello **background music** there") == "Hello there");
    assert(speechTextFromTranscript("Keep [important term] here")
        == "Keep [important term] here");
    assert(speechTextFromTranscript("Keep [an unmatched annotation") == "Keep [an unmatched annotation");
    assert(isKnownNoSpeechTranscript("[playing music] *clears throat* (click)"));
    assert(!isKnownNoSpeechTranscript("[door opens] Thank you."));
    assert(!isKnownNoSpeechTranscript("Hello (click) there."));
}
