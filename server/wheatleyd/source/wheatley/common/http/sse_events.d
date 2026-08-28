module wheatley.common.http.sse_events;

import std.array : appender;
import std.exception : enforce;
import std.string : startsWith, strip;

import vibe.stream.operations : readLine;

struct SseEvent
{
    string name;
    string data;
}

void readSseEvents(Reader)(Reader reader, bool delegate(SseEvent event) onEvent)
{
    string eventName;
    auto eventData = appender!string;
    bool reading = true;

    bool dispatchEvent()
    {
        if (!eventName.length && !eventData.data.length) return true;
        enforce(eventName.length, "SSE event name is required");
        enforce(eventData.data.length, "SSE event data is required");
        auto event = SseEvent(eventName, eventData.data);
        eventName = "";
        eventData = appender!string;
        return onEvent(event);
    }

    while (reading) {
        string line;
        try {
            line = cast(string) reader.readLine(1024 * 1024, "\n");
        } catch (Exception) {
            break;
        }

        if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
        if (!line.length) {
            reading = dispatchEvent();
            continue;
        }
        if (line.startsWith("event:")) {
            eventName = line["event:".length .. $].strip;
        } else if (line.startsWith("data:")) {
            if (eventData.data.length) eventData.put("\n");
            eventData.put(line["data:".length .. $].strip);
        }
    }

    if (reading && (eventName.length || eventData.data.length)) dispatchEvent();
}

unittest
{
    // Reader behavior is integration-tested by both HTTP adapters. Keep the
    // transport value itself independent of console/server ownership.
    assert(SseEvent("conversation", "{}").name == "conversation");
}
