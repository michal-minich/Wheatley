module wheatley.server.turns.audio.user_text;

import std.string : strip;

string combinedAudioUserText(string typedText, string transcriptText)
{
    auto typed = typedText.strip;
    auto transcript = transcriptText.strip;
    if (!typed.length) return transcript;
    if (!transcript.length) return typed;
    return typed ~ "\n\nAudio transcript:\n" ~ transcript;
}
