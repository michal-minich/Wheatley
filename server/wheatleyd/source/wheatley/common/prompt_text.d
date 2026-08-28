module wheatley.common.prompt_text;

import std.ascii : toLower;
import std.string : strip;

bool promptStartsWithThink(string text)
{
    auto cleaned = text.strip;
    if (!cleaned.length) return false;

    enum command = "think";
    if (cleaned.length < command.length) return false;
    if (!asciiEqualsIgnoreCase(cleaned[0 .. command.length], command)) return false;

    return cleaned.length == command.length
        || !isAsciiWordCharacter(cleaned[command.length]);
}

private bool isAsciiWordCharacter(char ch)
{
    return (ch >= 'a' && ch <= 'z')
        || (ch >= 'A' && ch <= 'Z')
        || (ch >= '0' && ch <= '9')
        || ch == '_';
}

private bool asciiEqualsIgnoreCase(string value, string expected)
{
    if (value.length != expected.length) return false;
    foreach (index, ch; value) {
        if (ch.toLower != expected[index]) return false;
    }
    return true;
}

unittest
{
    assert(promptStartsWithThink("Think, give me one more."));
    assert(promptStartsWithThink("think."));
    assert(promptStartsWithThink(" THINK?"));
    assert(promptStartsWithThink("think"));
    assert(!promptStartsWithThink("thinking"));
    assert(!promptStartsWithThink("thinker"));
    assert(!promptStartsWithThink("think2"));
}
