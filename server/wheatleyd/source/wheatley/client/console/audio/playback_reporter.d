module wheatley.client.console.audio.playback_reporter;

import core.sync.mutex : Mutex;
import core.time : dur;

import vibe.core.core : Task, runTask, sleep;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.common.api.audio_playback : AudioPlaybackEvent, AudioPlaybackEventKind;

private enum idlePollMillis = 20;
private enum retryDelayMillis = 80;
private enum deliveryAttempts = 2;

alias PlaybackEventSender = void delegate(AudioPlaybackEvent event);

/// Delivers one output's playback facts in order without delaying speech work.
/// A failed fact stops later delivery because the server rejects broken event
/// sequences; the next output's queue is the later reconciliation point.
final class ConsoleAudioPlaybackReporter
{
    private PlaybackEventSender send;
    private Mutex lock;
    private AudioPlaybackEvent[] pending;
    private bool closed;
    private bool deliveryFailed;
    private Task task;

    this(ConsoleApiClient client)
    {
        this((AudioPlaybackEvent event) {
            client.reportAudioPlayback(event);
        });
    }

    this(PlaybackEventSender send)
    {
        this.send = send;
        lock = new Mutex;
        task = runTask(() nothrow {
            deliverPending();
        });
    }

    void submit(AudioPlaybackEvent event) nothrow
    {
        try {
            lock.lock();
            scope(exit) lock.unlock();
            if (!closed && !deliveryFailed) pending ~= event;
        } catch (Throwable) {
        }
    }

    /// Lets the worker finish queued best-effort delivery without blocking the
    /// capture, TTS, or native playback paths.
    void close() nothrow
    {
        try {
            lock.lock();
            scope(exit) lock.unlock();
            closed = true;
        } catch (Throwable) {
        }
    }

    private void deliverPending() nothrow
    {
        try {
            while (true) {
                AudioPlaybackEvent event;
                bool hasEvent;
                bool done;
                {
                    lock.lock();
                    scope(exit) lock.unlock();
                    if (pending.length) {
                        event = pending[0];
                        pending = pending[1 .. $];
                        hasEvent = true;
                    } else {
                        done = closed || deliveryFailed;
                    }
                }

                if (hasEvent) {
                    if (!deliver(event)) {
                        {
                            lock.lock();
                            scope(exit) lock.unlock();
                            deliveryFailed = true;
                            pending = [];
                        }
                    }
                    continue;
                }
                if (done) return;
                sleep(dur!"msecs"(idlePollMillis));
            }
        } catch (Throwable) {
        }
    }

    private bool deliver(AudioPlaybackEvent event) nothrow
    {
        foreach (attempt; 0 .. deliveryAttempts) {
            try {
                send(event);
                return true;
            } catch (Throwable) {
                if (attempt + 1 < deliveryAttempts) {
                    try sleep(dur!"msecs"(retryDelayMillis));
                    catch (Throwable) {}
                }
            }
        }
        return false;
    }

    private void join()
    {
        task.join();
    }
}

unittest
{
    AudioPlaybackEventKind[] delivered;
    auto reporter = new ConsoleAudioPlaybackReporter((AudioPlaybackEvent event) {
        delivered ~= event.kind;
    });
    auto event = AudioPlaybackEvent();
    reporter.submit(event);
    event.kind = AudioPlaybackEventKind.started;
    reporter.submit(event);
    event.kind = AudioPlaybackEventKind.finished;
    reporter.submit(event);
    reporter.close();
    reporter.join();

    assert(delivered == [
        AudioPlaybackEventKind.queued,
        AudioPlaybackEventKind.started,
        AudioPlaybackEventKind.finished,
    ]);
}

unittest
{
    size_t attempts;
    auto reporter = new ConsoleAudioPlaybackReporter((AudioPlaybackEvent event) {
        attempts++;
        throw new Exception("offline");
    });
    reporter.submit(AudioPlaybackEvent());
    auto later = AudioPlaybackEvent();
    later.kind = AudioPlaybackEventKind.started;
    reporter.submit(later);
    reporter.close();
    reporter.join();

    assert(attempts == deliveryAttempts);
}
