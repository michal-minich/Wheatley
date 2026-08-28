module wheatley.client.console.audio.output_state;

import std.exception : enforce;

struct ConsoleOutputState
{
    bool capturing;
    bool thinking;
    bool speaking;

    void beginCapture() @safe nothrow
    {
        capturing = true;
        thinking = false;
        speaking = false;
    }

    void releaseCapture()
    {
        enforce(capturing, "Console audio is not capturing");
        capturing = false;
    }

    bool beginThinking() @safe nothrow
    {
        if (capturing) return false;
        thinking = true;
        return true;
    }

    void beginSpeaking()
    {
        enforce(!capturing, "Speech cannot start during capture");
        speaking = true;
    }

    void stopThinking() @safe nothrow
    {
        thinking = false;
    }

    void finish() @safe nothrow
    {
        capturing = false;
        thinking = false;
        speaking = false;
    }
}

unittest
{
    auto output = ConsoleOutputState();
    output.beginCapture();
    assert(!output.beginThinking());
    output.releaseCapture();
    assert(output.beginThinking());
    output.stopThinking();
    output.beginSpeaking();
    assert(output.speaking);
    output.finish();
    assert(!output.capturing && !output.thinking && !output.speaking);
}

unittest
{
    import std.exception : assertThrown;

    auto output = ConsoleOutputState();
    assertThrown(output.releaseCapture());
    output.beginCapture();
    assertThrown(output.beginSpeaking());
}
