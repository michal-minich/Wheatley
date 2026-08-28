module wheatley.client.console.speech.playback_events;

import wheatley.common.api.audio_playback : AudioPlaybackEventKind;

/// Per automatic-answer output fact gate. The caller supplies synchronization.
struct ConsolePlaybackEventState
{
    private bool queued;
    private bool started;
    private bool terminal;

    bool observe(AudioPlaybackEventKind kind)
    {
        if (terminal) return false;
        if (kind == AudioPlaybackEventKind.queued) {
            if (queued) return false;
            queued = true;
            return true;
        }
        if (!queued) return false;
        if (kind == AudioPlaybackEventKind.started) {
            if (started) return false;
            started = true;
            return true;
        }
        terminal = true;
        return true;
    }
}

unittest
{
    auto state = ConsolePlaybackEventState();
    assert(!state.observe(AudioPlaybackEventKind.started));
    assert(state.observe(AudioPlaybackEventKind.queued));
    assert(!state.observe(AudioPlaybackEventKind.queued));
    assert(state.observe(AudioPlaybackEventKind.started));
    assert(!state.observe(AudioPlaybackEventKind.started));
    assert(state.observe(AudioPlaybackEventKind.finished));
    assert(!state.observe(AudioPlaybackEventKind.cancelled));

    auto failure = ConsolePlaybackEventState();
    assert(failure.observe(AudioPlaybackEventKind.queued));
    assert(failure.observe(AudioPlaybackEventKind.failed));
    assert(!failure.observe(AudioPlaybackEventKind.finished));
}
