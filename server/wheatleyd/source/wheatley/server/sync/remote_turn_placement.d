module wheatley.server.sync.remote_turn_placement;

import wheatley.common.api.session : SessionKey;
import wheatley.common.api.accepted_voice_artifact : AcceptedVoiceArtifact;

/// Profile/sync prerequisite owned outside the Conversation transport.
interface RemoteTurnPlacementGate
{
    void prepare(SessionKey session);
    void prepareAcceptedVoice(
        SessionKey session,
        AcceptedVoiceArtifact artifact,
        string opusPath,
    );
    void materializeTerminalTurn(SessionKey session, string turnId);
}
