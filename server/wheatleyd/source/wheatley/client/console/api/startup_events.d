module wheatley.client.console.api.startup_events;

import std.exception : enforce;
import std.json : parseJSON;

import wheatley.common.api.profile_startup :
    ProfileStartupResult,
    profileStartupErrorMessage,
    profileStartupOpenedFromJson,
    profileStartupResultFromJson,
    profileStartupSystemFromJson;
import wheatley.client.console.api.sse_events : readConsoleSseEvents;

ProfileStartupResult readConsoleStartupEvents(Reader)(
    Reader reader,
    void delegate(string kind, string message) onSystemMessage,
)
{
    string streamError;
    ProfileStartupResult result;
    bool doneReceived;

    readConsoleSseEvents(reader, (event) {
        auto data = event.data;
        if (event.name == "system") {
            auto system = profileStartupSystemFromJson(parseJSON(data));
            if (onSystemMessage !is null) {
                onSystemMessage(system.kind, system.message);
            }
        } else if (event.name == "opened") {
            profileStartupOpenedFromJson(parseJSON(data));
            return true;
        } else if (event.name == "done") {
            result = profileStartupResultFromJson(parseJSON(data));
            doneReceived = true;
            return false;
        } else if (event.name == "error") {
            streamError = profileStartupErrorMessage(parseJSON(data));
            return false;
        } else {
            throw new Exception("Unsupported startup event: " ~ event.name);
        }
        return true;
    });

    if (streamError.length) throw new Exception(streamError);
    enforce(doneReceived, "Startup stream ended without a final response");
    return result;
}
