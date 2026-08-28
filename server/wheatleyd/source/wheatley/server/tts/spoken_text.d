module wheatley.server.tts.spoken_text;

import std.array : appender;
import std.string : replace, strip;

string normalizeSpokenText(string text)
{
    auto value = stripPairedEmphasisMarkers(text.replace("**", ""));
    value = stripLineHeadingMarkers(value).strip;
    if (!value.length) return "";

    size_t dotCount;
    for (auto index = value.length; index > 0 && value[index - 1] == '.'; index--) {
        dotCount++;
    }
    if (dotCount >= 3) value = value[0 .. $ - dotCount] ~ ".";
    return value;
}

private string stripPairedEmphasisMarkers(string text)
{
    auto output = appender!string;
    size_t index;
    while (index < text.length) {
        if (text[index] != '*' || isEscaped(text, index)
            || index + 1 == text.length || isMarkdownWhitespace(text[index + 1])) {
            output.put(text[index++]);
            continue;
        }

        auto closing = findClosingEmphasisMarker(text, index + 1);
        if (closing == text.length) {
            output.put(text[index++]);
            continue;
        }

        output.put(text[index + 1 .. closing]);
        index = closing + 1;
    }
    return output.data;
}

private size_t findClosingEmphasisMarker(string text, size_t start)
{
    for (auto index = start; index < text.length; index++) {
        if (text[index] == '*' && !isEscaped(text, index)
            && !isMarkdownWhitespace(text[index - 1])) return index;
    }
    return text.length;
}

private bool isEscaped(string text, size_t index)
{
    size_t slashCount;
    while (index > slashCount && text[index - slashCount - 1] == '\\') slashCount++;
    return slashCount % 2 == 1;
}

private bool isMarkdownWhitespace(char value)
{
    return value == ' ' || value == '\t' || value == '\n'
        || value == '\r' || value == '\f' || value == '\v';
}

private string stripLineHeadingMarkers(string text)
{
    auto output = appender!string;
    bool lineStart = true;
    size_t index;
    while (index < text.length) {
        if (lineStart && text[index] == '#') {
            while (index < text.length && text[index] == '#') index++;
            while (index < text.length && (text[index] == ' ' || text[index] == '\t')) index++;
            continue;
        }
        auto value = text[index++];
        output.put(value);
        lineStart = value == '\n' || value == '\r';
    }
    return output.data;
}

unittest
{
    assert(normalizeSpokenText("**Heading:** value") == "Heading: value");
    assert(normalizeSpokenText("Read *this phrase* naturally.") == "Read this phrase naturally.");
    assert(normalizeSpokenText("Read *this sentence.*") == "Read this sentence.");
    assert(normalizeSpokenText("***Bold italic***") == "Bold italic");
    assert(normalizeSpokenText("* first\n* second") == "* first\n* second");
    assert(normalizeSpokenText("2 * 3 = 6") == "2 * 3 = 6");
    assert(normalizeSpokenText("Keep *unmatched text") == "Keep *unmatched text");
    assert(normalizeSpokenText(`Keep \*escaped\* markers`) == `Keep \*escaped\* markers`);
}
