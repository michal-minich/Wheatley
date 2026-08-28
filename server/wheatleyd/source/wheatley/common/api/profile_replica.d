module wheatley.common.api.profile_replica;

import std.array : appender;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.json : JSONValue;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

enum profileReplicaSchemaVersion = 1;

struct ProfileReplicaProperty
{
    string path;
    string valueType;
    string text;
    long integer;
    double numberValue;
    bool boolean;
}

/// A paired device's acknowledged server-authoritative profile replica.
/// Its documents become active through one atomic snapshot; it remains a
/// replica, never a second writer or merge authority.
struct ProfileReplicaSnapshot
{
    string profileId;
    string revision;
    ProfileReplicaProperty[] properties;
    ProfileReplicaDocument[] documents;
}

struct ProfileReplicaDocument
{
    string name;
    string content;
    string sha256;
}

string profileReplicaSnapshotJson(ProfileReplicaSnapshot snapshot)
{
    auto entries = appender!string;
    entries.put("[");
    foreach (index, property; snapshot.properties) {
        if (index) entries.put(",");
        entries.put(jsonObject([
            jsonStringField("path", property.path),
            jsonStringField("value_type", property.valueType),
            jsonStringField("text", property.text),
            jsonLongField("integer", property.integer),
            jsonRawField("real", JSONValue(finiteNumber(property.numberValue)).toString()),
            jsonBoolField("boolean", property.boolean),
        ]));
    }
    entries.put("]");
    auto documents = appender!string;
    documents.put("[");
    foreach (index, document; snapshot.documents) {
        if (index) documents.put(",");
        documents.put(jsonObject([
            jsonStringField("name", document.name),
            jsonStringField("content", document.content),
            jsonStringField("sha256", document.sha256),
        ]));
    }
    documents.put("]");
    return jsonObject([
        jsonLongField("schema_version", profileReplicaSchemaVersion),
        jsonStringField("profile_id", snapshot.profileId),
        jsonStringField("version", snapshot.revision),
        jsonRawField("properties", entries.data),
        jsonRawField("documents", documents.data),
    ]);
}

private double finiteNumber(double value)
{
    return value == value && value != double.infinity && value != -double.infinity
        ? value
        : 0;
}

ProfileReplicaSnapshot profileReplicaSnapshotFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    json.integer("schema_version", profileReplicaSchemaVersion, profileReplicaSchemaVersion);
    ProfileReplicaSnapshot result;
    result.profileId = json.token("profile_id");
    result.revision = json.nonEmpty("version");
    foreach (entry; json.array("properties").value.array) {
        auto property = Json.object(entry);
        result.properties ~= ProfileReplicaProperty(
            property.nonEmpty("path"),
            property.nonEmpty("value_type"),
            property.text("text"),
            property.integer("integer"),
            property.number("real", -double.max, double.max),
            property.boolean("boolean"),
        );
    }
    foreach (entry; json.array("documents").value.array) {
        auto document = Json.object(entry);
        result.documents ~= ProfileReplicaDocument(
            document.nonEmpty("name"),
            document.text("content"),
            document.nonEmpty("sha256"),
        );
    }
    return result;
}

string profileReplicaDocumentSha256(string content)
{
    return toHexString!(LetterCase.lower)(sha256Of(cast(ubyte[]) content)).idup;
}

unittest
{
    import std.json : parseJSON;

    auto expected = ProfileReplicaSnapshot(
        "tester",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        [ProfileReplicaProperty("runtime.value", "int", "", 3, 0, false)],
        [ProfileReplicaDocument("system.md", "You are Wheatley.", profileReplicaDocumentSha256("You are Wheatley."))],
    );
    auto actual = profileReplicaSnapshotFromJson(parseJSON(profileReplicaSnapshotJson(expected)));
    assert(actual.profileId == expected.profileId);
    assert(actual.revision == expected.revision);
    assert(actual.properties == expected.properties);
}
