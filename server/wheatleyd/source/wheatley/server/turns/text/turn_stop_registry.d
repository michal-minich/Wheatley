module wheatley.server.turns.text.turn_stop_registry;

import core.sync.mutex : Mutex;

class TurnStopRegistry
{
    private Mutex mutex;
    private bool[string] stoppedTurns;

    this()
    {
        mutex = new Mutex;
    }

    void stop(string turnId)
    {
        if (!turnId.length) return;
        mutex.lock();
        scope(exit) mutex.unlock();
        stoppedTurns[turnId] = true;
    }

    bool stopped(string turnId)
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return (turnId in stoppedTurns) !is null;
    }

    void clear(string turnId)
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        stoppedTurns.remove(turnId);
    }
}
