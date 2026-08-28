module wheatley.server.session_use_registry;

import core.sync.mutex : Mutex;
import std.exception : assertThrown, enforce;

import wheatley.common.api.session : SessionKey;

final class SessionUseRegistry
{
    private struct State
    {
        size_t active;
        bool deleting;
    }

    private Mutex mutex;
    private State[string] states;

    this()
    {
        mutex = new Mutex;
    }

    void begin(SessionKey session)
    {
        synchronized (mutex) {
            auto state = stateFor(session);
            enforce(!state.deleting, "Session is being deleted");
            state.active++;
        }
    }

    void finish(SessionKey session)
    {
        synchronized (mutex) {
            auto state = session.value in states;
            enforce(state !is null && state.active > 0, "Session use is not active");
            state.active--;
            prune(session, *state);
        }
    }

    bool beginDelete(SessionKey session)
    {
        synchronized (mutex) {
            auto state = stateFor(session);
            if (state.active > 0 || state.deleting) return false;
            state.deleting = true;
            return true;
        }
    }

    void finishDelete(SessionKey session)
    {
        synchronized (mutex) {
            auto state = session.value in states;
            enforce(state !is null && state.deleting, "Session deletion is not active");
            state.deleting = false;
            prune(session, *state);
        }
    }

    private State* stateFor(SessionKey session)
    {
        auto key = session.value;
        if (key !in states) states[key] = State();
        return key in states;
    }

    private void prune(SessionKey session, State state)
    {
        if (state.active == 0 && !state.deleting) states.remove(session.value);
    }
}

unittest
{
    auto uses = new SessionUseRegistry;
    auto session = SessionKey("tester", "2026/07/14/10_00_00");
    uses.begin(session);
    assert(!uses.beginDelete(session));
    uses.finish(session);
    assert(uses.beginDelete(session));
    assertThrown!Exception(uses.begin(session));
    uses.finishDelete(session);
    uses.begin(session);
    uses.finish(session);
}
