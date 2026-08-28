module wheatley.common.safe_token;

import std.array : appender;
import std.exception : enforce;

bool isSafeTokenChar(dchar ch)
{
    return (ch >= 'a' && ch <= 'z') ||
        (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9') ||
        ch == '-' ||
        ch == '_';
}

bool isSafeIdTokenChar(dchar ch)
{
    return isSafeTokenChar(ch) || ch == '.';
}

void enforceSafeToken(string value, string label)
{
    enforce(value.length > 0, label ~ " is empty");
    foreach (ch; value) {
        enforce(isSafeTokenChar(ch), label ~ " contains an unsafe character");
    }
}

void enforceSafeIdToken(string value, string label)
{
    enforce(value.length > 0, label ~ " is empty");
    foreach (ch; value) {
        enforce(isSafeIdTokenChar(ch), label ~ " contains an unsafe character");
    }
}

string requireSafeIdToken(string value, string label = "id")
{
    enforceSafeIdToken(value, label);
    return value;
}

string safeToken(string value, string fallback)
{
    auto output = appender!string;
    foreach (ch; value) {
        output.put(isSafeTokenChar(ch) ? ch : '-');
    }
    return output.data.length ? output.data : fallback;
}
