module wheatley.common.runtime.windows_process;

version (Windows):

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, dur;

import std.algorithm : min;
import std.exception : enforce;
import std.process : escapeShellCommand;
import std.stdio : File;
import std.typecons : Nullable;

import vibe.core.core : sleep;
import vibe.core.stream : IOMode;

static import std.process;

struct WindowsProcessPipes
{
    WindowsProcessInput stdin;
    WindowsProcessOutput stdout;
    WindowsProcessOutput stderr;
    WindowsProcess process;
}

final class WindowsProcessInput
{
    private File stream;
    private Mutex mutex;
    private bool closed;

    this(File stream)
    {
        this.stream = stream;
        this.mutex = new Mutex;
    }

    void write(string data)
    {
        write(cast(const(ubyte)[]) data);
    }

    void write(const(ubyte)[] data)
    {
        mutex.lock();
        scope (exit) mutex.unlock();
        enforce(!closed, "Process stdin is closed");
        stream.rawWrite(data);
        stream.flush();
    }

    void close()
    {
        mutex.lock();
        scope (exit) mutex.unlock();
        if (closed) return;
        stream.close();
        closed = true;
    }
}

final class WindowsProcessOutput
{
    private File stream;
    private Mutex mutex;
    private Thread reader;
    private ubyte[] buffer;
    private size_t head;
    private bool ended;
    private string failure;

    this(File stream)
    {
        this.stream = stream;
        this.mutex = new Mutex;
        this.reader = new Thread(&readLoop);
        this.reader.start();
    }

    @property bool empty()
    {
        waitForData();
        mutex.lock();
        scope (exit) mutex.unlock();
        return availableBytes == 0 && ended;
    }

    @property size_t leastSize()
    {
        waitForData();
        mutex.lock();
        scope (exit) mutex.unlock();
        return availableBytes;
    }

    @property bool dataAvailableForRead()
    {
        mutex.lock();
        scope (exit) mutex.unlock();
        return availableBytes > 0;
    }

    size_t read(ubyte[] target)
    {
        waitForData();
        mutex.lock();
        scope (exit) mutex.unlock();
        auto count = min(target.length, availableBytes);
        if (!count) return 0;
        target[0 .. count] = buffer[head .. head + count];
        consume(count);
        return count;
    }

    size_t read(ubyte[] target, IOMode mode)
    {
        return read(target);
    }

    string readLine(size_t maxBytes, string delimiter)
    {
        enforce(delimiter == "\n", "Windows process output supports newline-delimited reads only");
        while (true) {
            mutex.lock();
            scope (exit) mutex.unlock();

            foreach (index, value; buffer[head .. $]) {
                if (value != '\n') continue;
                enforce(index <= maxBytes, "Process output line exceeds the configured limit");
                auto line = cast(string) buffer[head .. head + index].dup;
                consume(index + 1);
                return line;
            }

            enforce(availableBytes <= maxBytes, "Process output line exceeds the configured limit");
            if (ended) {
                if (failure.length) throw new Exception(failure);
                auto line = cast(string) buffer[head .. $].dup;
                consume(availableBytes);
                return line;
            }

            mutex.unlock();
            sleep(dur!"msecs"(5));
            mutex.lock();
        }
    }

    private void readLoop()
    {
        try {
            ubyte[64 * 1024] chunk;
            while (true) {
                auto data = stream.rawRead(chunk[]);
                if (!data.length) break;

                mutex.lock();
                compact();
                buffer ~= data;
                mutex.unlock();
            }
            finish("");
        } catch (Throwable error) {
            finish(error.msg);
        }
    }

    private void waitForData()
    {
        while (true) {
            mutex.lock();
            auto ready = availableBytes > 0 || ended;
            auto message = availableBytes == 0 && ended ? failure : "";
            mutex.unlock();

            if (message.length) throw new Exception(message);
            if (ready) return;
            sleep(dur!"msecs"(5));
        }
    }

    private void finish(string message)
    {
        mutex.lock();
        failure = message;
        ended = true;
        mutex.unlock();
    }

    private @property size_t availableBytes() const
    {
        return buffer.length - head;
    }

    private void consume(size_t count)
    {
        head += count;
        if (head == buffer.length) {
            buffer = null;
            head = 0;
        }
    }

    private void compact()
    {
        if (!head) return;
        buffer = buffer[head .. $].dup;
        head = 0;
    }
}

final class WindowsProcess
{
    private std.process.Pid pid;
    private Mutex mutex;
    private Nullable!int status;

    this(std.process.Pid pid)
    {
        this.pid = pid;
        this.mutex = new Mutex;
    }

    @property bool exited()
    {
        return !poll().isNull;
    }

    int wait()
    {
        while (true) {
            auto result = poll();
            if (!result.isNull) return result.get;
            sleep(dur!"msecs"(5));
        }
    }

    Nullable!int wait(Duration timeout)
    {
        auto deadline = MonoTime.currTime + timeout;
        while (MonoTime.currTime < deadline) {
            auto result = poll();
            if (!result.isNull) return result;
            sleep(dur!"msecs"(5));
        }
        return Nullable!int();
    }

    void kill()
    {
        terminate();
    }

    void forceKill()
    {
        terminate();
    }

    private Nullable!int poll()
    {
        mutex.lock();
        scope (exit) mutex.unlock();
        if (!status.isNull) return status;

        auto result = std.process.tryWait(pid);
        if (result.terminated) status = Nullable!int(result.status);
        return status;
    }

    private void terminate()
    {
        mutex.lock();
        scope (exit) mutex.unlock();
        if (!status.isNull) return;

        auto result = std.process.tryWait(pid);
        if (result.terminated) {
            status = Nullable!int(result.status);
            return;
        }
        std.process.kill(pid);
    }
}

WindowsProcessPipes pipeWindowsProcess(
    string[] command,
    const string[string] env,
    bool replaceEnvironment,
    string workDir,
    bool shell,
    bool mergeStderr,
)
{
    auto redirect = std.process.Redirect.stdin | std.process.Redirect.stdout;
    redirect |= mergeStderr
        ? std.process.Redirect.stderrToStdout
        : std.process.Redirect.stderr;
    auto config = replaceEnvironment ? std.process.Config.newEnv : std.process.Config.none;
    auto pipes = shell
        ? std.process.pipeShell(escapeShellCommand(command), redirect, env, config, workDir)
        : std.process.pipeProcess(command, redirect, env, config, workDir);

    return WindowsProcessPipes(
        new WindowsProcessInput(pipes.stdin),
        new WindowsProcessOutput(pipes.stdout),
        mergeStderr ? null : new WindowsProcessOutput(pipes.stderr),
        new WindowsProcess(pipes.pid),
    );
}
