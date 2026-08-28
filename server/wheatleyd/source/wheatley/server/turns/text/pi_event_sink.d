module wheatley.server.turns.text.pi_event_sink;

interface PiWorkerEventSink
{
    void handleLine(string line);
}
