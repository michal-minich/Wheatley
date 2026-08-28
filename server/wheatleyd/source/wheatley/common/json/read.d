module wheatley.common.json.read;

import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.typecons : Nullable, nullable;

import vibe.http.server : HTTPServerRequest;
import vibe.stream.operations : readAllUTF8;

import wheatley.common.choice : requireChoice, requireEnum;
import wheatley.common.safe_token : enforceSafeToken;

/// Required-by-default JSON object reader. Optional fields use `.opt`.
/// Path is tracked for failure messages (`metrics.total_ms`); no call-site labels.
struct Json
{
    private JSONValue value_;
    private string path_;

    this(JSONValue value, string path = "")
    {
        value_ = value;
        path_ = path;
    }

    @property JSONValue value()
    {
        return value_;
    }

    @property string path()
    {
        return path_;
    }

    static Json parse(string text, string path = "")
    {
        return object(parseJSON(text), path);
    }

    static Json object(JSONValue value, string path = "")
    {
        enforceType(value, JSONType.object, path);
        return Json(value, path);
    }

    static Json bodyObject(HTTPServerRequest req)
    {
        return parse(req.bodyReader.readAllUTF8(), "body");
    }

    Json object(string name)
    {
        return Json.object(require(name), childPath(name));
    }

    /// Required string field. Named `text` because `string` is a D keyword.
    string text(string name)
    {
        auto field = require(name);
        enforceType(field, JSONType.string, childPath(name));
        return field.str;
    }

    /// Required non-empty string field.
    string nonEmpty(string name)
    {
        auto value = text(name);
        enforce(value.length, fail(childPath(name)));
        return value;
    }

    /// Required array of strings (`name[i]` on bad element).
    string[] texts(string name)
    {
        auto field = array(name);
        string[] result;
        foreach (index, value; field.value.array) {
            enforce(value.type == JSONType.string, fail(field.path ~ "[" ~ index.to!string ~ "]"));
            result ~= value.str;
        }
        return result;
    }

    /// Required non-empty array of strings.
    string[] nonEmptyTexts(string name)
    {
        auto result = texts(name);
        enforce(result.length, fail(childPath(name)));
        return result;
    }

    /// Required array of object readers (`name[i]` on bad element).
    Json[] objects(string name)
    {
        auto field = array(name);
        Json[] result;
        foreach (index, value; field.value.array) {
            result ~= Json.object(value, field.path ~ "[" ~ index.to!string ~ "]");
        }
        return result;
    }

    /// Required string field restricted to `allowed` values.
    string choice(string name, scope const string[] allowed)
    {
        return requireChoice(text(name), childPath(name), allowed);
    }

    string choice(allowed...)(string name)
        if (allowed.length >= 1)
    {
        return choice(name, [allowed]);
    }

    /// Required string field mapped to a D enum whose member names match wire values.
    T enumeration(T)(string name)
        if (is(T == enum))
    {
        return requireEnum!T(text(name), childPath(name));
    }

    string token(string name)
    {
        auto value = text(name);
        enforceSafeToken(value, childPath(name));
        return value;
    }

    bool boolean(string name)
    {
        auto field = require(name);
        enforce(
            field.type == JSONType.true_ || field.type == JSONType.false_,
            fail(childPath(name)),
        );
        return field.boolean;
    }

    long integer(string name)
    {
        return integerValue(require(name), childPath(name));
    }

    double number(string name, double minimum, double maximum)
    {
        auto field = require(name);
        double value;
        if (field.type == JSONType.float_) {
            value = field.floating;
        } else if (field.type == JSONType.integer) {
            value = cast(double) field.integer;
        } else if (field.type == JSONType.uinteger) {
            value = cast(double) field.uinteger;
        } else {
            throw new Exception(fail(childPath(name)));
        }
        enforce(value >= minimum && value <= maximum, fail(childPath(name)));
        return value;
    }

    /// Required integer, optionally lower/upper bounded (`maximum` defaults to `long.max`).
    long integer(string name, long minimum, long maximum = long.max)
    {
        auto value = integer(name);
        enforce(value >= minimum && value <= maximum, fail(childPath(name)));
        return value;
    }

    /// Required integer in `1 .. int.max`, returned as `int`.
    int positiveInt(string name, int maximum = int.max)
    {
        return cast(int) integer(name, 1, maximum);
    }

    /// Required integer in `0 .. int.max`, returned as `int`.
    int nonNegativeInt(string name, int maximum = int.max)
    {
        return cast(int) integer(name, 0, maximum);
    }

    /// Required integer in `[minimum, maximum]`, returned as `int`.
    int intRange(string name, int minimum, int maximum)
    {
        return cast(int) integer(name, minimum, maximum);
    }

    Json array(string name)
    {
        auto field = require(name);
        enforceType(field, JSONType.array, childPath(name));
        return Json(field, childPath(name));
    }

    string objectRaw(string name)
    {
        return object(name).value.toString();
    }

    string arrayRaw(string name)
    {
        return array(name).value.toString();
    }

    string objectOrNullRaw(string name)
    {
        auto field = require(name);
        enforce(
            field.type == JSONType.object || field.type == JSONType.null_,
            fail(childPath(name)),
        );
        return field.toString();
    }

    OptJson opt()
    {
        return OptJson(this);
    }

    private JSONValue require(string name)
    {
        enforceType(value_, JSONType.object, path_);
        auto field = name in value_.objectNoRef;
        enforce(field !is null, fail(childPath(name)));
        return *field;
    }

    private string childPath(string name)
    {
        return path_.length ? path_ ~ "." ~ name : name;
    }

    private static string fail(string path)
    {
        return path.length ? "JSON " ~ path : "JSON";
    }

    private static void enforceType(JSONValue value, JSONType expected, string path)
    {
        enforce(value.type == expected, fail(path));
    }

    private static long integerValue(JSONValue value, string path)
    {
        if (value.type == JSONType.integer) return value.integer;
        if (value.type == JSONType.uinteger) {
            enforce(value.uinteger <= cast(ulong) long.max, fail(path));
            return cast(long) value.uinteger;
        }
        throw new Exception(fail(path));
    }
}

struct OptJson
{
    private Json parent;

    this(Json parent)
    {
        this.parent = parent;
    }

    Nullable!string text(string name)
    {
        auto field = peek(name);
        if (field is null) return Nullable!string.init;
        Json.enforceType(*field, JSONType.string, parent.childPath(name));
        return nullable(field.str);
    }

    Nullable!string choice(string name, scope const string[] allowed)
    {
        auto value = text(name);
        if (value.isNull) return value;
        return nullable(requireChoice(value.get, parent.childPath(name), allowed));
    }

    Nullable!string choice(allowed...)(string name)
        if (allowed.length >= 1)
    {
        return choice(name, [allowed]);
    }

    Nullable!T enumeration(T)(string name)
        if (is(T == enum))
    {
        auto value = text(name);
        if (value.isNull) return Nullable!T.init;
        return nullable(requireEnum!T(value.get, parent.childPath(name)));
    }

    Nullable!string token(string name)
    {
        auto value = text(name);
        if (value.isNull) return value;
        enforceSafeToken(value.get, parent.childPath(name));
        return value;
    }

    Nullable!bool boolean(string name)
    {
        auto field = peek(name);
        if (field is null) return Nullable!bool.init;
        enforce(
            field.type == JSONType.true_ || field.type == JSONType.false_,
            Json.fail(parent.childPath(name)),
        );
        return nullable(field.boolean);
    }

    Nullable!long integer(string name)
    {
        auto field = peek(name);
        if (field is null) return Nullable!long.init;
        return nullable(Json.integerValue(*field, parent.childPath(name)));
    }

    Nullable!long integer(string name, long minimum, long maximum = long.max)
    {
        auto value = integer(name);
        if (value.isNull) return value;
        enforce(
            value.get >= minimum && value.get <= maximum,
            Json.fail(parent.childPath(name)),
        );
        return value;
    }

    Nullable!int positiveInt(string name, int maximum = int.max)
    {
        auto value = integer(name, 1, maximum);
        if (value.isNull) return Nullable!int.init;
        return nullable(cast(int) value.get);
    }

    Nullable!int nonNegativeInt(string name, int maximum = int.max)
    {
        auto value = integer(name, 0, maximum);
        if (value.isNull) return Nullable!int.init;
        return nullable(cast(int) value.get);
    }

    Nullable!int intRange(string name, int minimum, int maximum)
    {
        auto value = integer(name, minimum, maximum);
        if (value.isNull) return Nullable!int.init;
        return nullable(cast(int) value.get);
    }

    Nullable!Json object(string name)
    {
        auto field = peek(name);
        if (field is null || field.type == JSONType.null_) return Nullable!Json.init;
        return nullable(Json.object(*field, parent.childPath(name)));
    }

    /// Absent field → `""`; present wrong type still fails.
    string textOrEmpty(string name)
    {
        auto field = peek(name);
        if (field is null) return "";
        Json.enforceType(*field, JSONType.string, parent.childPath(name));
        return field.str;
    }

    /// Absent field → `""`; present non-empty value must be a safe token.
    string tokenOrEmpty(string name)
    {
        auto value = textOrEmpty(name);
        if (value.length) enforceSafeToken(value, parent.childPath(name));
        return value;
    }

    private JSONValue* peek(string name)
    {
        Json.enforceType(parent.value_, JSONType.object, parent.path_);
        return name in parent.value_.objectNoRef;
    }
}

unittest
{
    auto json = Json.parse(`{"object":null}`);
    assert(json.opt.object("object").isNull);
    assert(json.opt.object("missing").isNull);
}

unittest
{
    import std.json : parseJSON;

    auto json = Json.parse(`{"mode":"on","lang":"sk","empty":"","n":3,"z":0,"items":["a","b"]}`);
    assert(json.texts("items") == ["a", "b"]);
    assert(Json.parse(`{"words":["yes"]}`).nonEmptyTexts("words") == ["yes"]);
    try {
        Json.parse(`[]`);
        assert(false);
    } catch (Exception ex) {
        assert(ex.msg == "JSON");
    }
    try {
        Json.parse(`{"words":[]}`).nonEmptyTexts("words");
        assert(false);
    } catch (Exception ex) {
        assert(ex.msg == "JSON words");
    }
    try {
        json.nonEmpty("empty");
        assert(false);
    } catch (Exception ex) {
        assert(ex.msg == "JSON empty");
    }
    auto optional = Json.parse(`{"x":"hi"}`).opt;
    assert(optional.textOrEmpty("missing") == "");
    assert(optional.textOrEmpty("x") == "hi");
    assert(optional.tokenOrEmpty("missing") == "");
    assert(json.choice!("off", "on")("mode") == "on");
    assert(json.choice("lang", ["en", "sk"]) == "sk");
    assert(json.positiveInt("n") == 3);
    assert(json.nonNegativeInt("z") == 0);
    assert(json.intRange("n", 1, 12) == 3);
    assert(json.integer("n", 1) == 3);
    assert(json.integer("z", 0, 0) == 0);
    assert(json.positiveInt("n", 12) == 3);
    try {
        json.choice!("off", "on")("lang");
        assert(false);
    } catch (Exception ex) {
        assert(ex.msg == "JSON lang");
    }
    try {
        json.positiveInt("z");
        assert(false);
    } catch (Exception ex) {
        assert(ex.msg == "JSON z");
    }
}
