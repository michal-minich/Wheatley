module wheatley.server.api.runtime.turn_responses;

import core.time : MonoTime;
import std.algorithm.comparison : min;
import std.algorithm : all;
import std.ascii : isAlphaNum, isDigit;
import std.array : split;
import std.conv : to;
import std.format : format;
import std.file : exists;
import std.json : JSONType, JSONValue;
import std.exception : enforce;
import std.string : endsWith, startsWith;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonStringField;
import wheatley.common.api.accepted_voice_artifact : AcceptedVoiceArtifact;
import wheatley.common.api.generated_image : GeneratedImageArtifact;
import wheatley.common.api.text_turn : TextTurnRequest;
import wheatley.common.api.reasoning : ReasoningMode;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.speech_interrupt :
    SpeechInterruptTranscription,
    speechInterruptTranscriptionJson;
import wheatley.common.api.tts : ttsResponseJson;
import wheatley.common.safe_token : enforceSafeToken;
import wheatley.common.json.read : Json;
import wheatley.server.api.runtime.requests :
    imageTurnRequest,
    SpeechInterruptHttpRequest,
    speechInterruptRequest,
    speechStreamRequest,
    sessionRequest,
    textTurnRequest,
    ttsRequest,
    userImageUpload;
import wheatley.server.api.http.json_response :
    addCommonHeaders,
    apiErrorJson,
    writeError,
    writeJson;
import wheatley.server.api.http.file_response : sendPayloadFile;
import wheatley.server.api.http.request_params : queryParam;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.api.runtime.detached_conversation : streamDetachedConversation;
import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.api.http.sse : startSse, writeSse;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.profile.runtime : ProfileRuntime;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.history.rows.image_artifact_record : UserImageArtifactRecord;
import wheatley.server.stt.runtime_settings : loadPreviewSttRuntimeSettings;
import wheatley.server.stt.whisper_cpp : WhisperCppWorkers;
import wheatley.server.tts.on_demand : OnDemandTts;
import wheatley.server.tts.turn_speech_stream : TurnSpeechStream;
import wheatley.server.turns.image.input_image_artifacts :
    loadStagedUserImage,
    persistUploadedUserImage;
import wheatley.server.turns.image.screen_capture_model : renderScreenCaptureModel;
import wheatley.server.conversation.port : ConversationPort;
import wheatley.server.conversation.turn_request :
    ConversationTurnRequest,
    conversationTurnSource,
    conversationTurnRequest;
import wheatley.server.session_use_registry : SessionUseRegistry;
import wheatley.server.history.files : FilePayload, RuntimeFiles;
import wheatley.server.voice.accepted_manifest :
    AcceptedVoiceManifest,
    loadAcceptedVoiceManifest;

void synthesizeSpeechResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    OnDemandTts tts,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto request = ttsRequest(req);
        auto result = tts.synthesize(profileId, request.text, request.language);
        writeJson(res, ttsResponseJson(result), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.serviceUnavailable, "tts_unavailable", error.msg, corsOrigin);
    }
}

void turnSpeechStreamResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    TurnSpeechStream speech,
    SessionUseRegistry sessionUses,
    string corsOrigin,
)
{
    string profileId;
    string speechId;
    string source;
    string itemId;
    bool includeReasoningStatus;
    bool startAfterExisting;
    SessionKey session;
    bool sessionUseActive;
    try {
        profileId = requireProfileId(req, store);
        auto request = speechStreamRequest(req);
        speechId = request.speechId;
        source = request.source;
        itemId = request.itemId;
        includeReasoningStatus = request.includeReasoningStatus;
        startAfterExisting = request.startAfterExisting;
        session = SessionKey(profileId, request.sessionId);
        sessionUses.begin(session);
        sessionUseActive = true;
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
        return;
    }

    startSse(res, corsOrigin);
    try {
        speech.stream(
            session,
            req.params["turn_id"],
            speechId,
            source,
            itemId,
            includeReasoningStatus,
            startAfterExisting,
            (eventName, dataJson) {
            writeSse(res, eventName, dataJson);
        });
    } catch (Exception error) {
        writeSse(res, "error", apiErrorJson("speech", error.msg));
    } finally {
        finalizeObserverQuietly(res);
        if (sessionUseActive) sessionUses.finish(session);
    }
}

void stopTurnSpeechResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    TurnSpeechStream speech,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, sessionRequest(req, "Stop turn speech").sessionId);
        auto speechId = req.params["speech_id"];
        enforceSafeToken(speechId, "speech_id");
        speech.stop(session, speechId);
        writeJson(res, jsonObject([
            jsonBoolField("ok", true),
            jsonStringField("speech_id", speechId),
        ]), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
    }
}

void acceptedVoiceCommitStreamResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    ServerConfig config,
    HistoryStore store,
    RuntimeFiles files,
    ConversationPort conversations,
    SessionUseRegistry sessionUses,
    string corsOrigin,
)
{
    string profileId;
    SessionKey session;
    bool sessionUseActive;
    try {
        profileId = requireProfileId(req, store);
        auto submissionId = req.params["submission_id"];
        auto stagedAudioPath = files.stagedUserAudioPath(profileId, submissionId);
        auto manifest = loadAcceptedVoiceManifest(stagedAudioPath);
        enforce(manifest.profileId == profileId, "Accepted voice profile changed");
        enforce(manifest.submissionId == submissionId, "Accepted voice submission changed");
        auto json = Json.bodyObject(req);
        auto afterSequence = json.integer("after_sequence", 0);
        auto reasoningMode = json.enumeration!ReasoningMode("reasoning_mode");
        auto model = json.text("model");
        session = SessionKey(profileId, manifest.sessionId);
        store.requireResumableSession(session);
        auto existing = store.findTurnBySubmission(session, submissionId);
        if (!existing.id.length) {
            enforce(exists(stagedAudioPath), "Accepted voice audio does not exist");
        }
        sessionUses.begin(session);
        sessionUseActive = true;
        auto request = acceptedVoiceCommitRequest(manifest, reasoningMode, model, afterSequence);
        request.userImage = acceptedVoiceUserImage(config, store, session, submissionId);
        request.hasUserImage = request.userImage.filename.length > 0;
        streamDetachedConversation(res, corsOrigin, sessionUses, session, (sink) {
            conversations.runWithUserAudio(
                session,
                request,
                manifest.audio,
                sink,
                manifest.artifact.source,
            );
        });
        sessionUseActive = false;
    } catch (Exception error) {
        if (!res.headerWritten) writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
        else writeSse(res, "error", apiErrorJson("accepted_voice", error.msg));
    } finally {
        finalizeObserverQuietly(res);
        if (sessionUseActive) sessionUses.finish(session);
    }
}

private UserImageArtifactRecord acceptedVoiceUserImage(
    ServerConfig config,
    HistoryStore store,
    SessionKey session,
    string submissionId,
)
{
    auto staged = loadStagedUserImage(config, session.profileId, submissionId);
    if (staged.filename.length) return staged;
    auto turn = store.findTurnBySubmission(session, submissionId);
    if (!turn.hasUserImage) return UserImageArtifactRecord();
    return UserImageArtifactRecord(
        turn.userImageFilename,
        turn.userImageMediaType,
        "",
        "",
        turn.userImageBytes,
    );
}

private ConversationTurnRequest acceptedVoiceCommitRequest(
    const ref AcceptedVoiceManifest manifest,
    ReasoningMode reasoningMode,
    string model,
    long afterSequence,
)
{
    enforce(reasoningMode == manifest.artifact.reasoningMode,
        "Accepted voice reasoning mode changed");
    enforce(model == manifest.artifact.model, "Accepted voice model changed");
    auto result = conversationTurnRequest(TextTurnRequest(
        manifest.artifact.sessionId,
        manifest.artifact.userText,
        manifest.artifact.submissionId,
        manifest.artifact.deviceId,
        manifest.artifact.language,
        manifest.artifact.source,
        manifest.artifact.loadMemory,
        reasoningMode, model, afterSequence,
    ));
    result.startedAtOverride = manifest.artifact.startedAtOverride;
    result.audioMetricsJson = manifest.artifact.audioMetricsJson;
    result.sttMetricsJson = manifest.artifact.sttMetricsJson;
    result.turnMetricsJson = manifest.artifact.turnMetricsJson;
    return result;
}

void textTurnStreamResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ConversationPort conversations,
    SessionUseRegistry sessionUses,
    string corsOrigin,
)
{
    ConversationTurnRequest request;
    string profileId;
    SessionKey session;
    bool sessionUseActive;
    try {
        profileId = requireProfileId(req, store);
        request = textTurnRequest(req);
        session = SessionKey(profileId, request.sessionId);
        sessionUses.begin(session);
        sessionUseActive = true;
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
        return;
    }

    try {
        streamDetachedConversation(res, corsOrigin, sessionUses, session, (sink) {
            conversations.run(session, request, sink);
        });
        sessionUseActive = false;
    } finally {
        if (sessionUseActive) sessionUses.finish(session);
    }
}

void imageTurnStreamResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    ServerConfig config,
    HistoryStore store,
    ConversationPort conversations,
    SessionUseRegistry sessionUses,
    string corsOrigin,
)
{
    ConversationTurnRequest request;
    string profileId;
    SessionKey session;
    bool sessionUseActive;
    try {
        profileId = requireProfileId(req, store);
        auto incoming = imageTurnRequest(req);
        request = incoming.turn;
        request.userImage = persistUploadedUserImage(
            config,
            profileId,
            request.submissionId,
            incoming.image.path,
            incoming.image.filename,
            incoming.image.mediaType,
        );
        request.hasUserImage = true;
        session = SessionKey(profileId, request.sessionId);
        sessionUses.begin(session);
        sessionUseActive = true;
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
        return;
    }

    try {
        streamDetachedConversation(res, corsOrigin, sessionUses, session, (sink) {
            conversations.run(session, request, sink);
        });
        sessionUseActive = false;
    } finally {
        if (sessionUseActive) sessionUses.finish(session);
    }
}

void stageUserImageResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    ServerConfig config,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto submissionId = req.params["submission_id"];
        auto upload = userImageUpload(req);
        auto image = persistUploadedUserImage(
            config,
            profileId,
            submissionId,
            upload.path,
            upload.filename,
            upload.mediaType,
        );
        writeJson(res, jsonObject([
            jsonStringField("filename", image.filename),
            jsonStringField("media_type", image.mediaType),
            jsonLongField("bytes", cast(long) image.bytes),
        ]), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
    }
}

void userImageResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, queryParam(req, "session_id"));
        auto filename = req.params["filename"];
        if (filename.startsWith("generated-") && filename.endsWith(".png")) {
            auto generated = store.generatedImage(session, req.params["turn_id"], filename);
            sendPayloadFile(req, res, FilePayload(generated.path, generated.mediaType), corsOrigin);
        } else if (filename.startsWith("screenshot-") && filename.endsWith(".png")) {
            auto capture = store.screenCapture(session, req.params["turn_id"], filename);
            sendPayloadFile(req, res, FilePayload(capture.path, capture.mediaType), corsOrigin);
        } else if (filename.startsWith("web-")
            && (filename.endsWith(".png") || filename.endsWith(".jpg"))) {
            auto webImage = store.webImage(session, req.params["turn_id"], filename);
            sendPayloadFile(req, res, FilePayload(webImage.path, webImage.mediaType), corsOrigin);
        } else {
            auto turn = store.findTurn(session, req.params["turn_id"]);
            enforce(turn.id.length && turn.hasUserImage, "Turn image not found");
            enforce(turn.userImageFilename == filename, "Turn image filename changed");
            enforce(exists(turn.userImagePath), "Turn image file does not exist");
            sendPayloadFile(
                req,
                res,
                FilePayload(turn.userImagePath, turn.userImageMediaType),
                corsOrigin,
            );
        }
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "image_not_found", error.msg, corsOrigin);
    }
}

void presentationImageResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, chatSessionId(req.params["session_id"]));
        auto imageIndex = presentationImageIndex(req.params["image_index"]);
        sendPayloadFile(
            req,
            res,
            store.presentationImage(session, req.params["image_kind"], imageIndex),
            corsOrigin,
        );
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "image_not_found", error.msg, corsOrigin);
    }
}

void turnScreenCaptureModelResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    ServerConfig config,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, queryParam(req, "session_id"));
        auto capture = store.screenCapture(session, req.params["turn_id"], req.params["filename"]);
        writeScreenCaptureModel(res, config, capture, corsOrigin);
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "image_not_found", error.msg, corsOrigin);
    }
}

void presentationScreenCaptureModelResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    ServerConfig config,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, chatSessionId(req.params["session_id"]));
        auto imageIndex = presentationImageIndex(req.params["image_index"]);
        auto capture = store.presentationScreenCapture(session, imageIndex);
        writeScreenCaptureModel(res, config, capture, corsOrigin);
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "image_not_found", error.msg, corsOrigin);
    }
}

private void writeScreenCaptureModel(
    HTTPServerResponse res,
    ServerConfig config,
    GeneratedImageArtifact capture,
    string corsOrigin,
)
{
    auto png = renderScreenCaptureModel(config, capture);
    addCommonHeaders(res, corsOrigin);
    res.headers["Cache-Control"] = "private, no-store";
    res.writeBody(png, "image/png");
}

void uploadedImageResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(profileId, chatSessionId(req.params["session_id"]));
        auto uploadIndex = uploadedImageIndex(req.params["image_index"]);
        sendPayloadFile(
            req,
            res,
            store.uploadedImage(session, req.params["filename"], uploadIndex),
            corsOrigin,
        );
    } catch (Exception error) {
        if (!res.headerWritten)
            writeError(res, HTTPStatus.notFound, "image_not_found", error.msg, corsOrigin);
    }
}

private string chatSessionId(string value)
{
    auto parts = value.split("-");
    enforce(parts.length == 4, "Chat session path is invalid");
    enforce(parts[0].length == 4 && parts[0].all!isDigit, "Chat session year is invalid");
    enforce(parts[1].length == 2 && parts[1].all!isDigit, "Chat session month is invalid");
    enforce(parts[2].length == 2 && parts[2].all!isDigit, "Chat session day is invalid");
    auto time = parts[3];
    enforce(time.length >= 8
        && time[0 .. 2].all!isDigit
        && time[2] == '_'
        && time[3 .. 5].all!isDigit
        && time[5] == '_'
        && time[6 .. 8].all!isDigit,
        "Chat session time is invalid");
    if (time.length > 8)
        enforce(time[8] == '_' && time[9 .. $].length
            && time[9 .. $].all!isAlphaNum, "Chat session suffix is invalid");
    return parts[0] ~ "/" ~ parts[1] ~ "/" ~ parts[2] ~ "/" ~ time;
}

private long presentationImageIndex(string value)
{
    enforce(value.length >= 2 && value.all!isDigit, "Image index is invalid");
    auto index = value.to!long;
    enforce(index > 0, "Image index must be positive");
    enforce(value == (index < 10 ? "0" : "") ~ index.to!string,
        "Image index must use at least two digits");
    return index;
}

private long uploadedImageIndex(string value)
{
    enforce(value.length && value.all!isDigit, "Uploaded image index is invalid");
    auto index = value.to!long;
    enforce(index > 0 && value == index.to!string,
        "Uploaded image index must be a positive unpadded number");
    return index;
}

unittest
{
    assert(chatSessionId("2026-08-13-17_50_07") == "2026/08/13/17_50_07");
    assert(chatSessionId("2026-08-13-17_50_07_atom") == "2026/08/13/17_50_07_atom");
    assert(presentationImageIndex("01") == 1);
    assert(presentationImageIndex("100") == 100);
    assert(uploadedImageIndex("1") == 1);
    assert(uploadedImageIndex("100") == 100);
}

void stopTextTurnResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    ConversationPort conversations,
    string corsOrigin,
)
{
    try {
        auto profileId = requireProfileId(req, store);
        auto session = SessionKey(
            profileId,
            sessionRequest(req, "Stop text turn").sessionId,
        );
        auto turnId = req.params["turn_id"];
        conversations.stop(session, turnId);
        writeJson(res, format!`{"ok":true,"turn_id":%s}`(JSONValue(turnId).toString()), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
    }
}

void speechInterruptTranscriptionResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    ServerConfig config,
    HistoryStore store,
    ProfileRuntime profiles,
    WhisperCppWorkers stt,
    string corsOrigin,
)
{
    string profileId;
    SpeechInterruptHttpRequest request;
    try {
        profileId = requireProfileId(req, store);
        request = speechInterruptRequest(req);
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
        return;
    }

    try {
        auto resolved = profiles.resolveSession(profileId, request.language);
        auto settings = loadPreviewSttRuntimeSettings(config, resolved);
        settings.requestTimeoutSeconds = min(settings.requestTimeoutSeconds, 3.0);
        auto started = MonoTime.currTime;
        auto transcription = stt.transcribe(settings, request.audioPath, "", false, true);
        auto durationMs = cast(long) (MonoTime.currTime - started).total!"msecs";
        writeJson(res, speechInterruptTranscriptionJson(SpeechInterruptTranscription(
            transcription.text,
            transcription.language,
            durationMs,
        )), corsOrigin);
    } catch (Exception error) {
        writeError(
            res,
            HTTPStatus.serviceUnavailable,
            "speech_interrupt_unavailable",
            error.msg,
            corsOrigin,
        );
    }
}

void clientTurnMetricsResponse(
    HTTPServerRequest req,
    HTTPServerResponse res,
    HistoryStore store,
    SessionUseRegistry sessionUses,
    string corsOrigin,
)
{
    SessionKey session;
    bool sessionUseActive;
    try {
        auto profileId = requireProfileId(req, store);
        auto turnId = req.params["turn_id"];
        auto payload = Json.bodyObject(req);
        session = SessionKey(profileId, payload.text("session_id"));
        sessionUses.begin(session);
        sessionUseActive = true;
        store.mergeClientTurnMetrics(session, turnId, payload.objectRaw("metrics"));
        writeJson(res, jsonObject([
            jsonBoolField("ok", true),
            jsonStringField("turn_id", turnId),
        ]), corsOrigin);
    } catch (Exception error) {
        writeError(res, HTTPStatus.badRequest, "bad_request", error.msg, corsOrigin);
    } finally {
        if (sessionUseActive) sessionUses.finish(session);
    }
}

private void finalizeObserverQuietly(HTTPServerResponse res)
{
    try {
        if (res.headerWritten) res.finalize();
    } catch (Exception) {
        // A response observer may disappear while server-owned work continues.
    }
}

unittest
{
    auto manifest = AcceptedVoiceManifest(
        "tester", "session-a", "submission-a", "device-a", "accepted words", "en", true,
        UserAudioArtifactRecord(
            "runtime-user-audio:submission-a", "tester", "2026-08-05T10:00:00Z", "/staged.opus",
            123, 4.25, true, 17, true,
        ),
        AcceptedVoiceArtifact(
            "tester", "session-a", "submission-a", "runtime-user-audio:submission-a",
            "audio_live", "accepted words", "en", "device-a", true,
            ReasoningMode.high, "model-a", "2026-08-05T10:00:00Z", 123,
            4.25, true, 17, true,
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "2026-08-05T10:00:00Z", "{\"accepted_seconds\":4.25}", "{}", "{}",
        ),
    );
    auto original = acceptedVoiceCommitRequest(manifest, ReasoningMode.high, "model-a", 0);
    auto replay = acceptedVoiceCommitRequest(manifest, ReasoningMode.high, "model-a", 4);

    // A client may reconnect after the original commit; only its event cursor
    // changes, so Conversation's canonical submission fence still matches.
    assert(original.submissionId == replay.submissionId);
    assert(original.text == replay.text);
    assert(original.loadMemory == replay.loadMemory);
    assert(original.reasoningMode == replay.reasoningMode);
    assert(original.model == replay.model);
    assert(replay.afterSequence == 4);
    assert(conversationTurnSource(original, "api_text") == "audio_live");
    assert(original.startedAtOverride == "2026-08-05T10:00:00Z");
    assert(original.audioMetricsJson == "{\"accepted_seconds\":4.25}");
    assert(original.sttMetricsJson == "{}");
    assert(original.turnMetricsJson == "{}");
}
