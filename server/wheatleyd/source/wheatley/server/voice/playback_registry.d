module wheatley.server.voice.playback_registry;

import core.sync.mutex : Mutex;

import std.exception : enforce;

import wheatley.common.api.audio_playback :
    AudioPlaybackEvent,
    AudioPlaybackEventKind,
    AudioPlaybackSource;
import wheatley.common.api.session : SessionKey;

struct AudioPlaybackReceipt
{
    string turnId;
    string outputId;
    AudioPlaybackEventKind kind;
    bool speaking;
}

/// Process-local Voice state derived from device playback facts.
final class VoicePlaybackRegistry
{
    private Mutex mutex;
    private AudioPlaybackEvent[string] active;

    this()
    {
        mutex = new Mutex;
    }

    AudioPlaybackReceipt observe(AudioPlaybackEvent event)
    {
        auto key = playbackKey(event.session, event.outputId);
        mutex.lock();
        scope(exit) mutex.unlock();

        auto current = key in active;
        if (current is null) {
            if (terminal(event.kind))
                return receipt(event, speakingLocked(event.session));
            enforce(
                event.kind == AudioPlaybackEventKind.queued,
                "Playback output must be queued before later events",
            );
            retireStaleOutputs(event);
            active[key] = event;
        } else {
            enforce(current.turnId == event.turnId, "Playback output turn changed");
            enforce(current.source == event.source, "Playback output source changed");
            enforce(current.adapter == event.adapter, "Playback output adapter changed");
            if (current.kind == event.kind)
                return receipt(event, speakingLocked(event.session));
            validateTransition(current.kind, event.kind);
            if (terminal(event.kind))
                active.remove(key);
            else
                active[key] = event;
        }
        return receipt(event, speakingLocked(event.session));
    }

    bool speaking(SessionKey session)
    {
        mutex.lock();
        scope(exit) mutex.unlock();
        return speakingLocked(session);
    }

    private bool speakingLocked(SessionKey session)
    {
        foreach (event; active.byValue) {
            if (event.session == session && event.kind == AudioPlaybackEventKind.started)
                return true;
        }
        return false;
    }

    private void retireStaleOutputs(AudioPlaybackEvent replacement)
    {
        // One adapter owns one synthesized output in a session. A new queue is
        // also the reconciliation signal when the previous terminal POST was lost.
        string[] staleKeys;
        foreach (key, event; active) {
            if (event.session == replacement.session && event.adapter == replacement.adapter)
                staleKeys ~= key;
        }
        foreach (key; staleKeys)
            active.remove(key);
    }
}

private AudioPlaybackReceipt receipt(AudioPlaybackEvent event, bool speaking)
{
    return AudioPlaybackReceipt(event.turnId, event.outputId, event.kind, speaking);
}

private void validateTransition(AudioPlaybackEventKind current, AudioPlaybackEventKind next)
{
    final switch (current) {
        case AudioPlaybackEventKind.queued:
            enforce(
                next == AudioPlaybackEventKind.started
                    || next == AudioPlaybackEventKind.finished
                    || next == AudioPlaybackEventKind.cancelled
                    || next == AudioPlaybackEventKind.failed,
                "Invalid queued playback transition",
            );
            return;
        case AudioPlaybackEventKind.started:
            enforce(
                next == AudioPlaybackEventKind.finished
                    || next == AudioPlaybackEventKind.cancelled
                    || next == AudioPlaybackEventKind.failed,
                "Invalid started playback transition",
            );
            return;
        case AudioPlaybackEventKind.finished:
        case AudioPlaybackEventKind.cancelled:
        case AudioPlaybackEventKind.failed:
            throw new Exception("Terminal playback output cannot transition");
    }
}

private bool terminal(AudioPlaybackEventKind kind)
{
    return kind == AudioPlaybackEventKind.finished
        || kind == AudioPlaybackEventKind.cancelled
        || kind == AudioPlaybackEventKind.failed;
}

private string playbackKey(SessionKey session, string outputId)
{
    return session.value ~ ":" ~ outputId;
}

unittest
{
    import std.exception : assertThrown;

    auto registry = new VoicePlaybackRegistry;
    auto session = SessionKey("tester", "12_00_00");
    auto event = AudioPlaybackEvent(
        session,
        "turn-1",
        "speech-1",
        AudioPlaybackSource.answer,
        AudioPlaybackEventKind.queued,
        "web_audio",
        "",
    );
    assert(!registry.observe(event).speaking);
    event.kind = AudioPlaybackEventKind.started;
    assert(registry.observe(event).speaking);

    auto second = event;
    second.outputId = "speech-2";
    second.kind = AudioPlaybackEventKind.queued;
    registry.observe(second);
    second.kind = AudioPlaybackEventKind.started;
    registry.observe(second);

    event.kind = AudioPlaybackEventKind.finished;
    assert(registry.observe(event).speaking);
    second.kind = AudioPlaybackEventKind.cancelled;
    assert(!registry.observe(second).speaking);
    assert(!registry.speaking(session));

    // Lost responses are harmless: active and terminal events are idempotent.
    auto duplicate = event;
    duplicate.outputId = "speech-duplicate";
    duplicate.kind = AudioPlaybackEventKind.queued;
    registry.observe(duplicate);
    registry.observe(duplicate);
    duplicate.kind = AudioPlaybackEventKind.started;
    registry.observe(duplicate);
    registry.observe(duplicate);
    duplicate.kind = AudioPlaybackEventKind.finished;
    registry.observe(duplicate);
    registry.observe(duplicate);

    // A later output from one session/adapter reconciles a lost terminal event.
    auto stale = event;
    stale.outputId = "speech-stale";
    stale.kind = AudioPlaybackEventKind.queued;
    registry.observe(stale);
    stale.kind = AudioPlaybackEventKind.started;
    assert(registry.observe(stale).speaking);
    auto replacement = stale;
    replacement.outputId = "speech-replacement";
    replacement.kind = AudioPlaybackEventKind.queued;
    assert(!registry.observe(replacement).speaking);
    replacement.kind = AudioPlaybackEventKind.started;
    assert(registry.observe(replacement).speaking);
    replacement.kind = AudioPlaybackEventKind.cancelled;
    assert(!registry.observe(replacement).speaking);

    auto invalid = event;
    invalid.outputId = "speech-3";
    invalid.kind = AudioPlaybackEventKind.started;
    assertThrown(registry.observe(invalid));
}
