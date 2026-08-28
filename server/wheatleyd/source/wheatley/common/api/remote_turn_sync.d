module wheatley.common.api.remote_turn_sync;

import std.json : JSONValue;

import wheatley.common.json.object :
    jsonObject,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

/// Exact session metadata handed to the Conversation authority before a turn.
struct RemoteTurnSessionHandoff
{
    string sessionPath;
    string sessionJson;
}

string remoteTurnSessionHandoffJson(RemoteTurnSessionHandoff handoff)
{
    return jsonObject([
        jsonStringField("session_path", handoff.sessionPath),
        jsonRawField("session", jsonObjectRaw(handoff.sessionJson)),
    ]);
}

RemoteTurnSessionHandoff remoteTurnSessionHandoffFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return RemoteTurnSessionHandoff(
        json.text("session_path"),
        json.objectRaw("session"),
    );
}

unittest
{
    import std.json : parseJSON;

    auto expected = RemoteTurnSessionHandoff(
        "2026/08/05/12_00_00",
        `{"client":"offline","language":"en"}`,
    );
    auto actual = remoteTurnSessionHandoffFromJson(parseJSON(
        remoteTurnSessionHandoffJson(expected),
    ));
    assert(actual.sessionPath == expected.sessionPath);
    assert(parseJSON(actual.sessionJson) == parseJSON(expected.sessionJson));
}
