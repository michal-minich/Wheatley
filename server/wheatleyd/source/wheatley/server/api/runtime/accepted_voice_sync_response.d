module wheatley.server.api.runtime.accepted_voice_sync_response;

import std.exception : enforce;
import std.json : parseJSON;

import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.common.api.accepted_voice_artifact : acceptedVoiceArtifactFromJson;
import wheatley.common.api.session : SessionKey;
import wheatley.common.http.form : Form;
import wheatley.common.json.object : jsonBoolField, jsonObject, jsonStringField;
import wheatley.server.api.http.json_response : handleJson;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.voice.accepted_replica : AcceptedVoiceReplica;

void acceptedVoiceSyncResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    AcceptedVoiceReplica replica,
    string corsOrigin,
)
{
    handleJson(res, corsOrigin, () {
        auto profileId = requireProfileId(req, store);
        auto form = Form.from(req);
        auto artifact = acceptedVoiceArtifactFromJson(parseJSON(
            form.nonEmpty("artifact"),
        ));
        enforce(artifact.profileId == profileId,
            "Accepted voice upload profile changed");
        auto session = SessionKey(profileId, artifact.sessionId);
        store.requireResumableSession(session);
        auto upload = "audio" in req.files;
        replica.importOpus(
            artifact,
            upload is null ? "" : upload.tempPath.toString(),
        );
        return jsonObject([
            jsonBoolField("ok", true),
            jsonStringField("submission_id", artifact.submissionId),
        ]);
    });
}
