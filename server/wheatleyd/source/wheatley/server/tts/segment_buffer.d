module wheatley.server.tts.segment_buffer;

import std.string : split, startsWith, strip;

enum minInitialSegmentWords = 6;
enum minFollowingSegmentWords = 14;

struct TtsSegmentBuffer
{
    private string buffer;
    private bool hasInitialSegment;

    string[] feed(string text)
    {
        buffer ~= text;
        return popReady(false);
    }

    string[] finish()
    {
        return popReady(true);
    }

    void clear()
    {
        buffer = "";
        hasInitialSegment = false;
    }

    private string[] popReady(bool isFinal)
    {
        string[] segments;
        while (true) {
            auto segment = popSegment(isFinal);
            if (!segment.length) return segments;
            segments ~= segment;
            if (isFinal) return segments;
        }
    }

    private string popSegment(bool isFinal)
    {
        auto text = buffer.strip;
        if (!text.length) {
            buffer = "";
            return "";
        }

        if (isFinal) {
            buffer = "";
            return text;
        }

        auto minWords = hasInitialSegment
            ? minFollowingSegmentWords
            : minInitialSegmentWords;
        auto sentenceBoundary = preferredSentenceBoundaryIndex(buffer, minWords);
        if (sentenceBoundary > 0) return takeReady(sentenceBoundary);

        if (hasInitialSegment) return "";

        auto clauseBoundary = preferredInitialClauseBoundaryIndex(buffer);
        return clauseBoundary > 0 ? takeReady(clauseBoundary) : "";
    }

    private string takeReady(size_t endIndex)
    {
        hasInitialSegment = true;
        return take(endIndex);
    }

    private string take(size_t endIndex)
    {
        auto segment = buffer[0 .. endIndex].strip;
        buffer = buffer[endIndex .. $];
        return segment;
    }
}

private size_t preferredSentenceBoundaryIndex(string text, int minWords)
{
    for (size_t index; index < text.length; index++) {
        size_t endIndex;
        if (text[index] == '\n') {
            endIndex = skipNewlines(text, index);
        } else {
            endIndex = sentenceBoundaryEndIndex(text, index);
            if (!endIndex) continue;
        }

        if (countWords(text[0 .. endIndex].strip) >= minWords) return endIndex;
        index = endIndex - 1;
    }
    return 0;
}

private size_t preferredInitialClauseBoundaryIndex(string text)
{
    for (size_t index; index < text.length; index++) {
        auto endIndex = initialClauseBoundaryEndIndex(text, index);
        if (!endIndex) continue;
        if (countWords(text[0 .. index].strip) >= minInitialSegmentWords) return endIndex;
        index = endIndex - 1;
    }
    return 0;
}

private size_t sentenceBoundaryEndIndex(string text, size_t index)
{
    size_t punctuationEnd;
    if (isSentencePunctuation(text[index])) {
        punctuationEnd = index + 1;
    } else if (text[index .. $].startsWith("…")) {
        punctuationEnd = index + "…".length;
    } else {
        return 0;
    }
    return completedBoundaryEndIndex(text, punctuationEnd);
}

private size_t initialClauseBoundaryEndIndex(string text, size_t index)
{
    size_t punctuationEnd;
    if (text[index] == ',' || text[index] == ';' || text[index] == ':') {
        punctuationEnd = index + 1;
    } else if (text[index .. $].startsWith("—")) {
        punctuationEnd = index + "—".length;
    } else if (text[index .. $].startsWith("–")) {
        punctuationEnd = index + "–".length;
    } else if (text[index .. $].startsWith("--")) {
        punctuationEnd = index + 2;
    } else if (
        text[index] == '-'
        && index > 0
        && isWhitespace(text[index - 1])
    ) {
        punctuationEnd = index + 1;
    } else {
        return 0;
    }
    return completedBoundaryEndIndex(text, punctuationEnd);
}

private size_t completedBoundaryEndIndex(string text, size_t punctuationEnd)
{
    auto endIndex = skipBoundaryClosers(text, punctuationEnd);
    if (endIndex == text.length || !isWhitespace(text[endIndex])) return 0;
    return skipWhitespace(text, endIndex);
}

private size_t skipBoundaryClosers(string text, size_t index)
{
    while (index < text.length) {
        if (
            text[index] == '\''
            || text[index] == '"'
            || text[index] == ')'
            || text[index] == ']'
            || text[index] == '}'
        ) {
            index++;
        } else if (text[index .. $].startsWith("’")) {
            index += "’".length;
        } else if (text[index .. $].startsWith("”")) {
            index += "”".length;
        } else {
            return index;
        }
    }
    return index;
}

private int countWords(string text)
{
    auto trimmed = text.strip;
    return trimmed.length ? cast(int) trimmed.split.length : 0;
}

private bool isSentencePunctuation(char value)
{
    return value == '.' || value == '!' || value == '?';
}

private bool isWhitespace(char value)
{
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

private size_t skipWhitespace(string text, size_t index)
{
    while (index < text.length && isWhitespace(text[index])) index++;
    return index;
}

private size_t skipNewlines(string text, size_t index)
{
    while (index < text.length && text[index] == '\n') index++;
    return index;
}
