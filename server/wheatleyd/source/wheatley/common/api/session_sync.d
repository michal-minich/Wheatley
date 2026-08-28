module wheatley.common.api.session_sync;

import std.array : appender;
import std.json : JSONValue;

import wheatley.common.json.object :
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

struct SessionSyncManifestFile
{
    string turnPath;
    string name;
}

struct SessionSyncManifest
{
    string sessionPath;
    SessionSyncManifestFile[] files;
}

string sessionSyncManifestJson(SessionSyncManifest manifest)
{
    auto files = appender!string;
    files.put("[");
    foreach (index, file; manifest.files) {
        if (index) files.put(",");
        files.put(jsonObject([
            jsonStringField("turn_path", file.turnPath),
            jsonStringField("name", file.name),
        ]));
    }
    files.put("]");
    return jsonObject([
        jsonStringField("session_path", manifest.sessionPath),
        jsonRawField("files", files.data),
    ]);
}

SessionSyncManifest sessionSyncManifestFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    SessionSyncManifest result;
    result.sessionPath = json.text("session_path");
    foreach (fileValue; json.array("files").value.array) {
        auto file = Json.object(fileValue);
        result.files ~= SessionSyncManifestFile(
            file.text("turn_path"),
            file.text("name"),
        );
    }
    return result;
}

unittest
{
    import std.json : parseJSON;

    auto expected = SessionSyncManifest(
        "2026/08/05/12_34_56",
        [
            SessionSyncManifestFile("", "session.json"),
            SessionSyncManifestFile("12_35_00_123456", "turn.json"),
        ],
    );
    auto actual = sessionSyncManifestFromJson(parseJSON(sessionSyncManifestJson(expected)));
    assert(actual.sessionPath == expected.sessionPath);
    assert(actual.files == expected.files);
}
