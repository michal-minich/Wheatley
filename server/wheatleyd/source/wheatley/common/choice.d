module wheatley.common.choice;

import std.conv : to;
import std.exception : enforce;
import std.traits : EnumMembers;

/// Require `value` to be one of `allowed`. Optional `path` is used in the
/// failure message (`JSON language`); empty path → `"JSON"`.
string requireChoice(string value, scope const string[] allowed)
{
    return requireChoice(value, "", allowed);
}

string requireChoice(string value, string path, scope const string[] allowed)
{
    foreach (option; allowed) {
        if (value == option) return value;
    }
    enforce(false, fail(path));
    assert(false);
}

string requireChoice(allowed...)(string value)
    if (allowed.length >= 1)
{
    return requireChoice(value, [allowed]);
}

string requireChoice(allowed...)(string value, string path)
    if (allowed.length >= 1)
{
    return requireChoice(value, path, [allowed]);
}

/// Map a wire string to a D enum whose member names match the wire values.
T requireEnum(T)(string value, string path = "")
    if (is(T == enum))
{
    foreach (member; EnumMembers!T) {
        if (value == member.to!string) return member;
    }
    enforce(false, fail(path));
    assert(false);
}

private string fail(string path)
{
    return path.length ? "JSON " ~ path : "JSON";
}

unittest
{
    assert(requireChoice!("off", "on")("off") == "off");
    assert(requireChoice("sk", ["en", "sk"]) == "sk");
    try {
        requireChoice!("off", "on")("maybe");
        assert(false);
    } catch (Exception ex) {
        assert(ex.msg == "JSON");
    }
    try {
        requireChoice!("en", "sk")("cz", "language");
        assert(false);
    } catch (Exception ex) {
        assert(ex.msg == "JSON language");
    }
}
