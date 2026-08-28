module wheatley.server.api.runtime.media_responses;

import std.exception : enforce;
import std.file : exists, remove;
import std.path : buildPath;
import std.string : indexOf;
import std.uri : encodeComponent;

import wheatley.common.api.media :
    ThinkingMusicAssetSelection,
    thinkingMusicAssetSelectionJson;
import wheatley.common.choice : requireChoice;

import vibe.http.common : HTTPMethod, HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.server.api.http.file_response : sendPayloadFile;
import wheatley.server.api.http.json_response : handleJson, writeError;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.history.files : FilePayload;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.media.thinking_music : ThinkingMusicLibrary;
import wheatley.server.voice.accepted_manifest : loadAcceptedVoiceManifest;

void audioArtifactResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    RuntimeFiles files,
    string corsOrigin,
)
{
    try {
        auto artifactId = audioArtifactId(req.params["artifact_id"]);
        auto artifact = store.artifactRef(artifactId);
        enforce(artifact.found, "Artifact not found");
        auto payload = files.resolveArtifact(artifact.relativePath, artifact.mediaType);
        sendPayloadFile(req, res, payload, corsOrigin);
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "not_found", error.msg, corsOrigin);
    }
}

private string audioArtifactId(string routeValue)
{
    return routeValue.indexOf(":") >= 0 ? routeValue : routeValue ~ ":user_audio";
}

void listeningChimeResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    string resourcesRoot,
    string corsOrigin,
)
{
    try {
        auto kind = requireChoice!("start", "stop", "capture")(req.params["kind"], "kind");
        auto path = buildPath(
            resourcesRoot,
            "assets",
            "audio",
            "chimes",
            kind == "capture" ? "capture.wav" : "listening-" ~ kind ~ ".wav",
        );
        enforce(exists(path), "Listening chime does not exist");
        sendPayloadFile(req, res, FilePayload(path, "audio/wav"), corsOrigin);
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "not_found", error.msg, corsOrigin);
    }
}

void thinkingMusicNextResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    ThinkingMusicLibrary thinkingMusic,
    HistoryStore store,
    string corsOrigin,
)
{
    res.headers["Cache-Control"] = "private, no-store";
    handleJson(res, corsOrigin, () {
        auto profileId = requireProfileId(req, store);
        auto selection = thinkingMusic.takeNext(profileId);
        selection.asset.url = "/api/profiles/" ~ encodeComponent(profileId) ~
            "/thinking-music/" ~ encodeComponent(selection.asset.code) ~
            "/" ~ encodeComponent(selection.asset.revision);
        return thinkingMusicAssetSelectionJson(ThinkingMusicAssetSelection(
            selection.asset,
            selection.title,
            selection.gainDb,
        ));
    });
}

void thinkingMusicAssetResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    ThinkingMusicLibrary thinkingMusic,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        requireProfileId(req, store);
        auto selection = thinkingMusic.requireAsset(
            req.params["code"],
            req.params["revision"],
        );
        res.headers["Cache-Control"] = "public, max-age=31536000, immutable";
        res.headers["ETag"] = "\"" ~ selection.asset.sha256 ~ "\"";
        sendPayloadFile(req, res, FilePayload(selection.path, selection.asset.mediaType), corsOrigin);
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "not_found", error.msg, corsOrigin);
    }
}

void generatedAudioArtifactResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    RuntimeFiles files,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto artifactId = req.params["artifact_id"];
        auto payload = files.resolveGeneratedTts(profileId, artifactId);
        scope(exit) if (req.method == HTTPMethod.GET) removeQuietly(payload.path);
        sendPayloadFile(req, res, payload, corsOrigin);
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "not_found", error.msg, corsOrigin);
    }
}

void acceptedVoiceAudioResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    RuntimeFiles files,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto submissionId = req.params["submission_id"];
        auto payload = files.resolveStagedUserAudio(profileId, submissionId);
        auto manifest = loadAcceptedVoiceManifest(payload.path);
        enforce(manifest.profileId == profileId, "Accepted voice profile changed");
        enforce(manifest.submissionId == submissionId, "Accepted voice submission changed");
        enforce(
            manifest.audio.stagedPath == payload.path,
            "Accepted voice staging path changed",
        );
        sendPayloadFile(req, res, payload, corsOrigin);
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "not_found", error.msg, corsOrigin);
    }
}

private void removeQuietly(string path) nothrow
{
    try {
        if (exists(path)) remove(path);
    } catch (Throwable) {
    }
}
