module wheatley.common.json.write;

import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;

string jsonObject(scope const string[] fields)
{
    auto buffer = appender!string;
    buffer.put("{");
    bool hasField;
    foreach (field; fields) {
        if (!field.length) continue;
        if (hasField) buffer.put(",");
        hasField = true;
        buffer.put(field);
    }
    buffer.put("}");
    return buffer.data;
}

string jsonText(string name, string value)
{
    return jsonRaw(name, jsonQuote(value));
}

string jsonBool(string name, bool value)
{
    return jsonRaw(name, value ? "true" : "false");
}

string jsonLong(string name, long value)
{
    return jsonRaw(name, value.to!string);
}

string jsonUlong(string name, ulong value)
{
    return jsonRaw(name, value.to!string);
}

string jsonRaw(string name, string valueJson)
{
    return jsonQuote(name) ~ ":" ~ valueJson;
}

string jsonObjectRaw(string valueJson)
{
    auto value = parseJSON(valueJson);
    enforce(value.type == JSONType.object, "JSON");
    return value.toString();
}

string jsonArrayRaw(string valueJson)
{
    auto value = parseJSON(valueJson);
    enforce(value.type == JSONType.array, "JSON");
    return value.toString();
}

string jsonObjectOrNullRaw(string valueJson)
{
    auto value = parseJSON(valueJson);
    enforce(
        value.type == JSONType.object || value.type == JSONType.null_,
        "JSON",
    );
    return value.toString();
}

string jsonQuote(string value)
{
    return JSONValue(value).toString();
}
