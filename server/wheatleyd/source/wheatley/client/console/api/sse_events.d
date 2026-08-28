module wheatley.client.console.api.sse_events;

import wheatley.common.http.sse_events : SseEvent, readSseEvents;

alias ConsoleSseEvent = SseEvent;

void readConsoleSseEvents(Reader)(Reader reader, bool delegate(ConsoleSseEvent event) onEvent)
{
    readSseEvents(reader, onEvent);
}
