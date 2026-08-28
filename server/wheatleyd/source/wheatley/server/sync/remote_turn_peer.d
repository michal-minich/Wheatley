module wheatley.server.sync.remote_turn_peer;

import wheatley.common.api.remote_turn_sync : RemoteTurnSessionHandoff;
import wheatley.common.api.accepted_voice_artifact : AcceptedVoiceArtifact;
import wheatley.common.api.session_sync :
    SessionSyncManifest,
    SessionSyncManifestFile;
import wheatley.server.history.store.sync_export : SyncCompletedTurnExport;

/// Upstream Profile boundary required before and after remote Conversation.
interface RemoteTurnSyncPeer
{
    void uploadCompletedTurn(SyncCompletedTurnExport turn, bool includePi);
    void ensureSession(string profileId, RemoteTurnSessionHandoff handoff);
    void importAcceptedVoice(AcceptedVoiceArtifact artifact, string opusPath);
    SessionSyncManifest exactTurn(
        string profileId,
        string sessionPath,
        string turnPath,
    );
    void downloadExactTurnFile(
        string profileId,
        string sessionPath,
        string turnPath,
        SessionSyncManifestFile file,
        string targetPath,
    );
}
