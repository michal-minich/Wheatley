module wheatley.server.history.store.json;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText, remove, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.uuid : randomUUID;

import wheatley.common.json.object : json;

string readOptionalText(string path)
{
    return exists(path) ? readText(path) : "";
}

string readJsonFile(string path, string fallback)
{
    if (!exists(path)) return fallback;
    return parseJSON(readText(path)).toString();
}

void writeTextFile(string path, string value)
{
    mkdirRecurse(dirName(path));
    write(path, value);
}

void writeJsonFile(string path, string jsonText)
{
    enforce(jsonText.length, "JSON text is empty");
    mkdirRecurse(dirName(path));
    write(path, prettyJson(parseJSON(jsonText)) ~ "\n");
}

void writeJsonFileAtomic(string path, string jsonText)
{
    enforce(jsonText.length, "JSON text is empty");
    mkdirRecurse(dirName(path));
    auto staged = path ~ ".pending-" ~ randomUUID().toString();
    scope(failure) if (exists(staged)) remove(staged);
    write(staged, prettyJson(parseJSON(jsonText)) ~ "\n");
    rename(staged, path);
}

string prettyJson(JSONValue value, int indent = 0)
{
    final switch (value.type) {
        case JSONType.object:
            auto object = value.objectNoRef;
            if (!object.length) return "{}";
            string[] keys;
            foreach (key; object.keys) keys ~= key;
            sort(keys);
            auto output = appender!string;
            output.put("{\n");
            foreach (index, key; keys) {
                if (index) output.put(",\n");
                output.put(spaces(indent + 2));
                output.put(json(key));
                output.put(": ");
                output.put(prettyJson(object[key], indent + 2));
            }
            output.put("\n");
            output.put(spaces(indent));
            output.put("}");
            return output.data;
        case JSONType.array:
            if (!value.array.length) return "[]";
            auto output = appender!string;
            output.put("[\n");
            foreach (index, item; value.array) {
                if (index) output.put(",\n");
                output.put(spaces(indent + 2));
                output.put(prettyJson(item, indent + 2));
            }
            output.put("\n");
            output.put(spaces(indent));
            output.put("]");
            return output.data;
        case JSONType.string:
            return json(value.str);
        case JSONType.integer:
            return value.integer.to!string;
        case JSONType.uinteger:
            return value.uinteger.to!string;
        case JSONType.float_:
            return value.floating.to!string;
        case JSONType.true_:
            return "true";
        case JSONType.false_:
            return "false";
        case JSONType.null_:
            return "null";
    }
}

string jsonText(JSONValue value, string name)
{
    // Soft read for legacy on-disk turn/session files; prefer Json at owned IO boundaries.
    if (value.type != JSONType.object) return "";
    auto object = value.objectNoRef;
    auto field = name in object;
    return field !is null && field.type == JSONType.string ? field.str : "";
}

string valueOr(string value, string fallback)
{
    return value.length ? value : fallback;
}

long jsonLong(JSONValue value, string name)
{
    if (value.type != JSONType.object) return 0;
    auto object = value.objectNoRef;
    auto field = name in object;
    if (field is null) return 0;
    if (field.type == JSONType.integer) return field.integer;
    if (field.type == JSONType.uinteger) return cast(long) field.uinteger;
    return 0;
}

bool jsonBool(JSONValue value, string name)
{
    if (value.type != JSONType.object) return false;
    auto object = value.objectNoRef;
    auto field = name in object;
    return field !is null && field.type == JSONType.true_;
}

JSONValue objectField(JSONValue value, string name)
{
    if (value.type != JSONType.object) return JSONValue(null);
    auto object = value.objectNoRef;
    auto field = name in object;
    return field is null || field.type != JSONType.object ? JSONValue(null) : *field;
}

JSONValue[] jsonArrayField(JSONValue value, string name)
{
    if (value.type != JSONType.object) return [];
    auto object = value.objectNoRef;
    auto field = name in object;
    return field is null || field.type != JSONType.array ? [] : field.array;
}

string jsonFieldJson(JSONValue value, string name, string fallback)
{
    if (value.type != JSONType.object) return fallback;
    auto object = value.objectNoRef;
    auto field = name in object;
    return field is null ? fallback : field.toString();
}

string preview(string text, size_t limit)
{
    return text.length <= limit ? text : text[0 .. limit];
}

private string spaces(int count)
{
    string value;
    foreach (_; 0 .. count) value ~= " ";
    return value;
}
