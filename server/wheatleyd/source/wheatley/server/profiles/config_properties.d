module wheatley.server.profiles.config_properties;

import std.exception : assertThrown, enforce;
import std.json : JSONValue;
import std.string : split, strip;

import wheatley.common.safe_token : enforceSafeToken;

struct ProfileConfigProperty
{
    string fieldPath;
    string valueType;
    string textValue;
    long integerValue;
    double realValue;
    bool boolValue;
}

struct ProfileConfigIndex
{
    ProfileConfigProperty[string] byPath;

    bool has(string path)
    {
        return (path in byPath) !is null;
    }

    bool hasNonNullValue(string path)
    {
        if (auto property = path in byPath) {
            return property.valueType != "null";
        }
        return false;
    }

    string textValue(string path, string fallback)
    {
        if (auto property = path in byPath) {
            return property.valueType == "text" ? property.textValue : fallback;
        }
        return fallback;
    }

    bool boolValue(string path, bool fallback)
    {
        if (auto property = path in byPath) {
            return property.valueType == "bool" ? property.boolValue : fallback;
        }
        return fallback;
    }

    long intValue(string path, long fallback)
    {
        if (auto property = path in byPath) {
            return property.valueType == "int" ? property.integerValue : fallback;
        }
        return fallback;
    }

    double realValue(string path, double fallback)
    {
        if (auto property = path in byPath) {
            if (property.valueType == "real") return property.realValue;
            if (property.valueType == "int") return cast(double) property.integerValue;
        }
        return fallback;
    }
}

ProfileConfigIndex indexProfileConfigProperties(ProfileConfigProperty[] properties)
{
    ProfileConfigIndex index;
    foreach (property; properties) {
        index.byPath[property.fieldPath] = property;
    }
    return index;
}

string requiredConfigText(ProfileConfigIndex props, string path)
{
    auto property = path in props.byPath;
    enforce(property !is null, "Missing config text: " ~ path);
    enforce(property.valueType == "text", "Config value must be text: " ~ path);
    enforce(property.textValue.length > 0, "Config text must not be empty: " ~ path);
    return property.textValue;
}

string[] requiredConfigTextList(ProfileConfigProperty[] props, string path)
{
    string[] values;
    foreach (property; props) {
        if (property.fieldPath != path) continue;
        enforce(property.valueType == "text", "Config list values must be text: " ~ path);
        enforce(property.textValue.length, "Config list text must not be empty: " ~ path);
        values ~= property.textValue;
    }
    enforce(values.length, "Missing config text list: " ~ path);
    return values;
}

bool requiredConfigBool(ProfileConfigIndex props, string path)
{
    auto property = path in props.byPath;
    enforce(property !is null, "Missing config bool: " ~ path);
    enforce(property.valueType == "bool", "Config value must be bool: " ~ path);
    return property.boolValue;
}

long requiredConfigInt(ProfileConfigIndex props, string path)
{
    auto property = path in props.byPath;
    enforce(property !is null, "Missing config int: " ~ path);
    enforce(property.valueType == "int", "Config value must be int: " ~ path);
    return property.integerValue;
}

long requiredConfigInt(ProfileConfigIndex props, string path, long minimum, long maximum)
{
    auto value = requiredConfigInt(props, path);
    enforce(value >= minimum && value <= maximum, "Config value is out of range: " ~ path);
    return value;
}

double requiredConfigReal(ProfileConfigIndex props, string path)
{
    auto property = path in props.byPath;
    enforce(property !is null, "Missing config number: " ~ path);
    enforce(
        property.valueType == "real" || property.valueType == "int",
        "Config value must be a number: " ~ path,
    );
    return property.valueType == "real"
        ? property.realValue
        : cast(double) property.integerValue;
}

unittest
{
    auto props = indexProfileConfigProperties([
        ProfileConfigProperty("pi.command", "text", "pi"),
        ProfileConfigProperty("pi.label", "text", "Pi"),
        ProfileConfigProperty("pi.empty", "text", ""),
        ProfileConfigProperty("pi.wrong_type", "bool", "", 0, 0, true),
    ]);
    assert(requiredConfigText(props, "pi.label") == "Pi");
    assertThrown!Exception(requiredConfigText(props, "pi.missing"));
    assertThrown!Exception(requiredConfigText(props, "pi.empty"));
    assertThrown!Exception(requiredConfigText(props, "pi.wrong_type"));
}

string activeProfileLanguage(ProfileConfigIndex props, string requestedLanguage)
{
    auto language = requestedLanguage;
    if (!language.length && props.boolValue("language.enabled", false)) {
        language = props.textValue("language.default", "");
    }
    if (language.length) {
        enforceSafeToken(language, "Language");
        enforce(
            props.hasNonNullValue(languageConfigPath(language, "response_language")),
            "Unsupported language: " ~ language,
        );
    }
    return language;
}

string[] supportedProfileLanguages(ProfileConfigIndex props)
{
    auto languages = requiredConfigText(props, "language.supported").split(",");
    foreach (ref language; languages) {
        language = language.strip;
        enforceSafeToken(language, "Supported language");
        enforce(
            props.hasNonNullValue(languageConfigPath(language, "response_language")),
            "Unsupported configured language: " ~ language,
        );
    }
    return languages;
}

string languageTextOverride(ProfileConfigIndex props, string language, string key, string fallback)
{
    if (!language.length) return fallback;
    auto value = props.textValue("language.languages." ~ language ~ "." ~ key, "");
    return value.length ? value : fallback;
}

string languageConfigText(ProfileConfigIndex props, string language, string key)
{
    if (language.length) {
        auto value = props.textValue(languageConfigPath(language, key), "");
        if (value.length) return value;
    }
    auto englishPath = languageConfigPath("en", key);
    auto english = props.textValue(englishPath, "");
    enforce(english.length > 0, "Missing language config text: " ~ englishPath);
    return english;
}

string localizedConfigText(ProfileConfigIndex props, string language, string path)
{
    if (language.length) {
        auto value = props.textValue(path ~ "." ~ language, "");
        if (value.length) return value;
    }
    auto englishPath = path ~ ".en";
    auto english = props.textValue(englishPath, "");
    enforce(english.length > 0, "Missing localized config text: " ~ englishPath);
    return english;
}

string[] localizedConfigList(ProfileConfigIndex props, string language, string path)
{
    string[] result;
    foreach (value; localizedConfigText(props, language, path).split(",")) {
        auto clean = value.strip;
        if (clean.length) result ~= clean;
    }
    enforce(result.length > 0, "Localized config list must not be empty: " ~ path);
    return result;
}

string languageConfigPath(string language, string key)
{
    enforce(language.length > 0, "Language is empty");
    return "language.languages." ~ language ~ "." ~ key;
}

ProfileConfigProperty[] flattenConfigProperties(
    JSONValue value,
    scope const string[] excludedRootFields = [],
)
{
    ProfileConfigProperty[] properties;
    flattenConfig("", value, excludedRootFields, properties);
    return properties;
}

private void flattenConfig(
    string prefix,
    JSONValue value,
    scope const string[] excludedRootFields,
    ref ProfileConfigProperty[] properties,
)
{
    import std.algorithm : canFind;
    import std.json : JSONType;

    final switch (value.type) {
        case JSONType.object:
            foreach (key, item; value.objectNoRef) {
                if (!prefix.length && excludedRootFields.canFind(key)) continue;
                auto path = prefix.length ? prefix ~ "." ~ key : key;
                flattenConfig(path, item, excludedRootFields, properties);
            }
            break;
        case JSONType.array:
            foreach (item; value.array) {
                auto path = prefix.length ? prefix ~ ".[]" : "[]";
                flattenConfig(path, item, excludedRootFields, properties);
            }
            break;
        case JSONType.string:
            properties ~= ProfileConfigProperty(prefix, "text", value.str, 0, 0, false);
            break;
        case JSONType.integer:
            properties ~= ProfileConfigProperty(prefix, "int", "", value.integer, 0, false);
            break;
        case JSONType.uinteger:
            properties ~= ProfileConfigProperty(prefix, "int", "", cast(long) value.uinteger, 0, false);
            break;
        case JSONType.float_:
            properties ~= ProfileConfigProperty(prefix, "real", "", 0, value.floating, false);
            break;
        case JSONType.true_:
            properties ~= ProfileConfigProperty(prefix, "bool", "", 0, 0, true);
            break;
        case JSONType.false_:
            properties ~= ProfileConfigProperty(prefix, "bool", "", 0, 0, false);
            break;
        case JSONType.null_:
            properties ~= ProfileConfigProperty(prefix, "null", "", 0, 0, false);
            break;
    }
}
