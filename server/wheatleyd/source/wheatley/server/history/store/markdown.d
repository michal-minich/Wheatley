module wheatley.server.history.store.markdown;

import std.file : exists, readText;
import std.string : indexOf, strip;

import wheatley.server.history.store.types : TurnText;

string turnMarkdown(string userText, string assistantText)
{
    return "# Turn\n\n## Prompt\n\n" ~ userText ~ "\n\n## Response\n\n" ~ assistantText ~ "\n";
}

TurnText readTurnMarkdown(string path)
{
    if (!exists(path)) return TurnText();
    auto text = readText(path);
    auto promptIndex = text.indexOf("## Prompt");
    auto responseIndex = text.indexOf("## Response");
    if (promptIndex < 0 || responseIndex < 0 || responseIndex <= promptIndex) {
        return TurnText(text, "");
    }
    auto promptStart = skipHeadingLine(text, cast(size_t) promptIndex + "## Prompt".length);
    auto responseStart = skipHeadingLine(text, cast(size_t) responseIndex + "## Response".length);
    return TurnText(
        text[promptStart .. cast(size_t) responseIndex].strip,
        text[responseStart .. $].strip,
    );
}

private size_t skipHeadingLine(string text, size_t index)
{
    while (index < text.length && (text[index] == '\r' || text[index] == '\n')) index++;
    return index;
}
