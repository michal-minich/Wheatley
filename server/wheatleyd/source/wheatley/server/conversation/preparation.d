module wheatley.server.conversation.preparation;

import std.exception : enforce;

import vibe.core.sync :
    LocalManualEvent,
    TaskMutex,
    createManualEvent,
    scopedMutexLock;

import wheatley.common.api.session : SessionKey;

final class ConversationPreparation
{
    private LocalManualEvent finished;
    private bool completed;
    private string failure;

    this()
    {
        finished = createManualEvent();
    }

    void wait()
    {
        while (!completed) {
            auto emitCount = finished.emitCount;
            if (!completed) finished.wait(emitCount);
        }
        enforce(!failure.length, failure);
    }

    private void finish(string failure)
    {
        this.failure = failure;
        completed = true;
        finished.emit();
    }
}

final class ConversationPreparationGate
{
    private TaskMutex mutex;
    private ConversationPreparation[][string] active;

    this()
    {
        mutex = new TaskMutex;
    }

    ConversationPreparation begin(SessionKey session)
    {
        auto preparation = new ConversationPreparation;
        auto guard = scopedMutexLock(mutex);
        active[session.value] ~= preparation;
        return preparation;
    }

    void finish(
        SessionKey session,
        ConversationPreparation preparation,
        string error = "",
    )
    {
        preparation.finish(error);
        auto guard = scopedMutexLock(mutex);
        auto key = session.value;
        auto current = key in active;
        if (current is null) return;
        foreach (index, item; *current) {
            if (item !is preparation) continue;
            (*current) = (*current)[0 .. index] ~ (*current)[index + 1 .. $];
            if (!(*current).length) active.remove(key);
            return;
        }
    }

    void wait(SessionKey session)
    {
        while (true) {
            ConversationPreparation[] preparations;
            {
                auto guard = scopedMutexLock(mutex);
                auto current = session.value in active;
                if (current is null) return;
                preparations = (*current).dup;
            }
            foreach (preparation; preparations) preparation.wait();
        }
    }
}
