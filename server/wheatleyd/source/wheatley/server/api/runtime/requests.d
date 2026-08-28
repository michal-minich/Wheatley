module wheatley.server.api.runtime.requests;

import std.conv : to;
import std.exception : enforce;

import vibe.http.server : HTTPServerRequest;

import wheatley.common.http.form : Form;
import wheatley.common.api.reasoning : ReasoningMode;
import wheatley.common.choice : requireEnum;
import wheatley.common.json.read : Json;
import wheatley.common.api.profile_startup :
    ProfileStartupRequest,
    profileStartupRequestFromJson;
import wheatley.common.api.text_turn : textTurnRequestFromJson;
import wheatley.common.api.text_turn : TextTurnRequest;
import wheatley.common.api.tts :
    TtsRequest,
    ttsRequestFromJson;
import wheatley.common.api.client_tools :
    ClientToolAdvertisement,
    ClientToolRequestCreate,
    ClientToolResultCreate,
    clientToolAdvertisementFromJson,
    clientToolRequestCreateFromJson,
    clientToolResultCreateFromJson;
import wheatley.server.client_tools.store : ClientToolArtifactUpload;
import wheatley.server.api.http.request_params : headerValue;
import wheatley.server.conversation.turn_request :
    ConversationTurnRequest,
    conversationTurnRequest;

struct UserImageUpload
{
    string path;
    string filename;
    string mediaType;
}

struct ImageTurnHttpRequest
{
    ConversationTurnRequest turn;
    UserImageUpload image;
}

struct SpeechInterruptHttpRequest
{
    string audioPath;
    string audioFilename;
    string language;
}

struct SpeechStreamHttpRequest
{
    string speechId;
    string sessionId;
    string source;
    string itemId;
    bool includeReasoningStatus;
    bool startAfterExisting;
}

struct SessionHttpRequest
{
    string sessionId;
}


struct ProfileMemoryAppendRequest
{
    string memory;
}

ClientToolAdvertisement clientToolAdvertisement(HTTPServerRequest req)
{
    return clientToolAdvertisementFromJson(Json.bodyObject(req).value);
}

ClientToolRequestCreate clientToolRequestCreate(HTTPServerRequest req)
{
    return clientToolRequestCreateFromJson(Json.bodyObject(req).value);
}

ClientToolResultCreate clientToolResultCreate(HTTPServerRequest req)
{
    return clientToolResultCreateFromJson(Json.bodyObject(req).value);
}

ClientToolArtifactUpload clientToolArtifactUpload(HTTPServerRequest req)
{
    auto form = Form.from(req);
    auto uploaded = "artifact" in req.files;
    enforce(uploaded !is null, "Client tool artifact file is required");
    return ClientToolArtifactUpload(
        uploaded.tempPath.toString(),
        uploaded.filename.name,
        form.text("artifact_id"),
        form.text("kind"),
        form.text("mime_type"),
    );
}

ConversationTurnRequest textTurnRequest(HTTPServerRequest req)
{
    return conversationTurnRequest(textTurnRequestFromJson(Json.bodyObject(req).value));
}

ImageTurnHttpRequest imageTurnRequest(HTTPServerRequest req)
{
    auto form = Form.from(req);
    auto upload = requiredUserImageUpload(req, form);
    auto turn = conversationTurnRequest(TextTurnRequest(
        form.nonEmpty("session_id"),
        form.text("text"),
        form.nonEmpty("submission_id"),
        form.text("device_id"),
        form.token("language"),
        "browser_image",
        form.boolean("load_memory"),
        requireEnum!ReasoningMode(form.nonEmpty("reasoning_mode"), "reasoning_mode"),
        form.text("model"),
        form.nonNegativeInt("after_sequence"),
    ));
    return ImageTurnHttpRequest(turn, upload);
}

UserImageUpload userImageUpload(HTTPServerRequest req)
{
    return requiredUserImageUpload(req, Form.from(req));
}

TtsRequest ttsRequest(HTTPServerRequest req)
{
    return ttsRequestFromJson(Json.bodyObject(req).value);
}

SpeechStreamHttpRequest speechStreamRequest(HTTPServerRequest req)
{
    auto json = Json.bodyObject(req);
    auto speechId = json.token("speech_id");
    auto source = json.choice!("answer", "reasoning")("source");
    return SpeechStreamHttpRequest(
        speechId,
        json.text("session_id"),
        source,
        json.text("item_id"),
        json.boolean("include_reasoning_status"),
        json.boolean("start_after_existing"),
    );
}

SessionHttpRequest sessionRequest(HTTPServerRequest req, string label)
{
    return SessionHttpRequest(Json.bodyObject(req).text("session_id"));
}



ProfileMemoryAppendRequest profileMemoryAppendRequest(HTTPServerRequest req)
{
    return ProfileMemoryAppendRequest(Json.bodyObject(req).text("memory"));
}

ProfileStartupRequest profileStartupRequest(HTTPServerRequest req)
{
    return profileStartupRequestFromJson(Json.bodyObject(req).value);
}

private UserImageUpload requiredUserImageUpload(HTTPServerRequest req, Form form)
{
    auto upload = optionalUserImageUpload(req, form);
    enforce(upload.path.length, "Image file is required");
    return upload;
}

private UserImageUpload optionalUserImageUpload(HTTPServerRequest req, Form form)
{
    auto uploaded = "image" in req.files;
    if (uploaded is null) return UserImageUpload();
    return UserImageUpload(
        uploaded.tempPath.toString(),
        uploaded.filename.name,
        form.nonEmpty("image_media_type"),
    );
}

SpeechInterruptHttpRequest speechInterruptRequest(HTTPServerRequest req)
{
    auto contentLength = headerValue(req, "Content-Length");
    if (contentLength.length) {
        enforce(contentLength.to!ulong <= 512 * 1024, "Speech interrupt audio is too large");
    }
    auto form = Form.from(req);
    auto uploaded = "audio" in req.files;
    enforce(uploaded !is null, "Speech interrupt audio file is required");
    return SpeechInterruptHttpRequest(
        uploaded.tempPath.toString(),
        uploaded.filename.name,
        form.token("language"),
    );
}
