module wheatley.server.voice.session_coordinator;

import std.conv : to;
import std.exception : enforce;

import wheatley.common.conversation.events : ConversationEventKind;

enum VoiceSessionPhase
{
    starting,
    listening,
    endpointReached,
    transcribingFinal,
    transcriptAccepted,
    responsePending,
    responseStreaming,
    completed,
    cancelled,
    failed,
}

/// Owns the semantic lifecycle of one live Voice session. Audio capture,
/// recognition, and transport remain adapters driven by this coordinator.
final class VoiceSessionCoordinator
{
    private VoiceSessionPhase current = VoiceSessionPhase.starting;

    VoiceSessionPhase phase() const @safe nothrow
    {
        return current;
    }

    bool terminal() const @safe nothrow
    {
        return current == VoiceSessionPhase.completed
            || current == VoiceSessionPhase.cancelled
            || current == VoiceSessionPhase.failed;
    }

    void beginListening()
    {
        requirePhase(VoiceSessionPhase.starting, VoiceSessionPhase.listening);
        current = VoiceSessionPhase.listening;
    }

    void rejectCandidate()
    {
        requirePhase(
            VoiceSessionPhase.listening,
            VoiceSessionPhase.endpointReached,
            VoiceSessionPhase.transcribingFinal,
        );
        current = VoiceSessionPhase.listening;
    }

    void reachEndpoint()
    {
        requirePhase(VoiceSessionPhase.listening);
        current = VoiceSessionPhase.endpointReached;
    }

    void beginFinalTranscription()
    {
        requirePhase(VoiceSessionPhase.endpointReached);
        current = VoiceSessionPhase.transcribingFinal;
    }

    void acceptTranscript()
    {
        requirePhase(VoiceSessionPhase.endpointReached, VoiceSessionPhase.transcribingFinal);
        current = VoiceSessionPhase.transcriptAccepted;
    }

    void awaitResponse()
    {
        requirePhase(VoiceSessionPhase.transcriptAccepted);
        current = VoiceSessionPhase.responsePending;
    }

    void observeConversation(ConversationEventKind kind)
    {
        if (terminal) return;
        final switch (kind) {
            case ConversationEventKind.status:
            case ConversationEventKind.assistantDelta:
            case ConversationEventKind.reasoning:
            case ConversationEventKind.tool:
            case ConversationEventKind.artifact:
                requirePhase(
                    VoiceSessionPhase.responsePending,
                    VoiceSessionPhase.responseStreaming,
                );
                current = VoiceSessionPhase.responseStreaming;
                break;
            case ConversationEventKind.completed:
                requirePhase(
                    VoiceSessionPhase.responsePending,
                    VoiceSessionPhase.responseStreaming,
                );
                current = VoiceSessionPhase.completed;
                break;
            case ConversationEventKind.failed:
                fail();
                break;
        }
    }

    void complete()
    {
        enforce(!terminal, "Voice session is already terminal");
        current = VoiceSessionPhase.completed;
    }

    void cancel() @safe nothrow
    {
        if (!terminal) current = VoiceSessionPhase.cancelled;
    }

    void fail() @safe nothrow
    {
        if (!terminal) current = VoiceSessionPhase.failed;
    }

    private void requirePhase(VoiceSessionPhase[] allowed...)
    {
        foreach (candidate; allowed) {
            if (current == candidate) return;
        }
        throw new Exception("Invalid Voice lifecycle transition from " ~ current.to!string);
    }
}

unittest
{
    auto voice = new VoiceSessionCoordinator;
    voice.beginListening();
    voice.reachEndpoint();
    voice.beginFinalTranscription();
    voice.rejectCandidate();
    voice.reachEndpoint();
    voice.beginFinalTranscription();
    voice.acceptTranscript();
    voice.awaitResponse();
    voice.observeConversation(ConversationEventKind.status);
    voice.observeConversation(ConversationEventKind.assistantDelta);
    voice.observeConversation(ConversationEventKind.completed);
    assert(voice.phase == VoiceSessionPhase.completed);
}

unittest
{
    import std.exception : assertThrown;

    auto voice = new VoiceSessionCoordinator;
    assertThrown(voice.acceptTranscript());
    voice.beginListening();
    voice.reachEndpoint();
    voice.acceptTranscript();
    voice.awaitResponse();
    voice.observeConversation(ConversationEventKind.failed);
    assert(voice.phase == VoiceSessionPhase.failed);
}
