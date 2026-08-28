module wheatley.common.http.form;

import std.exception : enforce;
import std.conv : to;
import std.string : strip;

import vibe.http.server : HTTPServerRequest;

import wheatley.common.safe_token : enforceSafeToken;

/// Required-by-default multipart form reader. Failures use `form.<name>`.
struct Form
{
    private typeof(HTTPServerRequest.init.form) form_;

    this(typeof(HTTPServerRequest.init.form) form)
    {
        form_ = form;
    }

    static Form from(HTTPServerRequest req)
    {
        return Form(req.form);
    }

    string text(string name)
    {
        auto value = name in form_;
        enforce(value !is null, fail(name));
        return *value;
    }

    string nonEmpty(string name)
    {
        auto value = text(name).strip;
        enforce(value.length, fail(name));
        return value;
    }

    /// Required present field; empty string allowed. Non-empty values must be safe tokens.
    string token(string name)
    {
        auto value = text(name);
        if (value.length) {
            enforce(value != "auto", fail(name));
            enforceSafeToken(value, fail(name));
        }
        return value;
    }

    /// Absent field → `""`.
    string textOrEmpty(string name)
    {
        auto value = name in form_;
        return value is null ? "" : *value;
    }

    /// Absent → `""`. Present non-empty values must be safe tokens.
    string tokenOrEmpty(string name)
    {
        auto value = textOrEmpty(name);
        if (value.length) {
            enforce(value != "auto", fail(name));
            enforceSafeToken(value, fail(name));
        }
        return value;
    }

    bool boolean(string name)
    {
        auto value = text(name).strip;
        enforce(value.length, fail(name));
        if (value == "1" || value == "true" || value == "yes" || value == "on") return true;
        if (value == "0" || value == "false" || value == "no" || value == "off") return false;
        throw new Exception(fail(name));
    }

    long nonNegativeInt(string name)
    {
        auto value = text(name).strip;
        enforce(value.length, fail(name));
        long parsed;
        try {
            parsed = value.to!long;
        } catch (Exception) {
            throw new Exception(fail(name));
        }
        enforce(parsed >= 0, fail(name));
        return parsed;
    }

    private static string fail(string name)
    {
        return "form." ~ name;
    }
}
