module wheatley.client.console.background_worker;

import core.sync.mutex : Mutex;
import core.thread : Thread;

final class ConsoleStopToken
{
    private Mutex mutex;
    private bool stopRequested;

    this()
    {
        mutex = new Mutex;
    }

    void requestStop()
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        stopRequested = true;
    }

    bool stopping()
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return stopRequested;
    }
}

final class ConsoleBackgroundWorker
{
    private ConsoleStopToken token;
    private Thread thread;

    this(string name, void delegate(ConsoleStopToken) run)
    {
        token = new ConsoleStopToken;
        thread = new Thread({ run(token); });
        thread.isDaemon = true;
        thread.name = name;
        thread.start();
    }

    void requestStop()
    {
        token.requestStop();
    }

    void join()
    {
        thread.join();
    }
}

unittest
{
    import core.time : dur;

    auto worker = new ConsoleBackgroundWorker("wheatley-worker-test", (stop) {
        while (!stop.stopping()) Thread.sleep(dur!"msecs"(1));
    });
    worker.requestStop();
    worker.join();
}
