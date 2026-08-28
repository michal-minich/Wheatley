module wheatley.client.console.conversation.local_submissions;

import core.sync.mutex : Mutex;

// Module globals are thread-local in D unless explicitly shared. These values
// are intentionally process-wide because the foreground runner and background
// presentation observer use them together under the mutex.
private __gshared Mutex mutex;
private __gshared bool[string] submissions;

shared static this()
{
    mutex = new Mutex;
}

void markLocalSubmission(string submissionId)
{
    synchronized (mutex) submissions[submissionId] = true;
}

void clearLocalSubmission(string submissionId)
{
    synchronized (mutex) submissions.remove(submissionId);
}

bool isLocalSubmission(string submissionId)
{
    synchronized (mutex) return submissions.get(submissionId, false);
}

unittest
{
    import core.thread : Thread;

    enum id = "thread-visible-submission";
    markLocalSubmission(id);
    bool observed;
    auto observer = new Thread({ observed = isLocalSubmission(id); });
    observer.start();
    observer.join();
    assert(observed);
    clearLocalSubmission(id);
    assert(!isLocalSubmission(id));
}
