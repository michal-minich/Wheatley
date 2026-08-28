module wheatley.server.turns.text.pi_run_gate;

import std.exception : enforce;

import vibe.core.sync : LocalTaskSemaphore, createTaskSemaphore;

final class PiRunGate
{
    private LocalTaskSemaphore semaphore;

    this(long maxConcurrentRuns)
    {
        enforce(maxConcurrentRuns > 0, "pi.max_concurrent_runs must be positive");
        enforce(maxConcurrentRuns <= int.max, "pi.max_concurrent_runs is too large");
        semaphore = createTaskSemaphore(cast(int) maxConcurrentRuns);
    }

    void lock()
    {
        semaphore.lock();
    }

    void unlock()
    {
        semaphore.unlock();
    }

    uint available() const
    {
        return semaphore.available;
    }
}

unittest
{
    auto gate = new PiRunGate(2);
    assert(gate.available == 2);
    gate.lock();
    assert(gate.available == 1);
    gate.unlock();
    assert(gate.available == 2);
}
