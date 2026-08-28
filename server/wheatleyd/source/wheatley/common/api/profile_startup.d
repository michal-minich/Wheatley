module wheatley.common.api.profile_startup;

import std.array : appender;
import std.json : JSONType, JSONValue, parseJSON;

import wheatley.common.api.reasoning :
    ReasoningMode,
    reasoningModeText;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

struct ProfileStartupRequest
{
    string language;
    string mode;
    string resumeSessionId;
    string model;
}

struct ProfileStartupSystemEvent
{
    string kind;
    string message;
}

struct ProfileStartupOpened
{
    bool resumedLastSession;
    string sessionId;
    string language;
    ReasoningMode reasoningMode;
}

struct ProfileStartupState
{
    bool canResumeLastSession;
    string lastSessionId;
    string language;
    string lastSessionLanguage;
    string[] languages;
    ProfileSessionResumeAnswers resumeAnswers;
    ProfileStartupMessages messages;
}

struct ProfileSessionResumeAnswers
{
    string[] yesWords;
    string[] noWords;
    string[] yesAnswers;
    string[] noAnswers;
}

struct ProfileStartupMessages
{
    string textResumePrompt;
    string textResumeUnclear;
    string voiceResumePrompt;
    string voiceResumeUnclear;
}

struct ProfileStartupResult
{
    bool ok;
    bool resumedLastSession;
    string sessionId;
    string language;
    ReasoningMode reasoningMode;
    long memoryProcessedTurns;
    long memoryProcessedSessions;
    bool memoryFailed;
}

ProfileStartupState profileStartupStateFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    auto messages = json.object("messages");
    return ProfileStartupState(
        json.boolean("can_resume_last_session"),
        json.text("last_session_id"),
        json.text("language"),
        json.text("last_session_language"),
        json.nonEmptyTexts("languages"),
        sessionResumeAnswersFromJson(json),
        ProfileStartupMessages(
            messages.text("text_resume_prompt"),
            messages.text("text_resume_unclear"),
            messages.text("voice_resume_prompt"),
            messages.text("voice_resume_unclear"),
        ),
    );
}

string profileStartupStateJson(ProfileStartupState state)
{
    return jsonObject([
        jsonBoolField("can_resume_last_session", state.canResumeLastSession),
        jsonStringField("last_session_id", state.lastSessionId),
        jsonStringField("language", state.language),
        jsonStringField("last_session_language", state.lastSessionLanguage),
        jsonRawField("languages", stringArrayJson(state.languages)),
        jsonRawField("resume_answers", sessionResumeAnswersJson(state.resumeAnswers)),
        jsonRawField("messages", jsonObject([
            jsonStringField("text_resume_prompt", state.messages.textResumePrompt),
            jsonStringField("text_resume_unclear", state.messages.textResumeUnclear),
            jsonStringField("voice_resume_prompt", state.messages.voiceResumePrompt),
            jsonStringField("voice_resume_unclear", state.messages.voiceResumeUnclear),
        ])),
    ]);
}

private ProfileSessionResumeAnswers sessionResumeAnswersFromJson(Json json)
{
    auto answers = json.object("resume_answers");
    return ProfileSessionResumeAnswers(
        answers.nonEmptyTexts("yes_words"),
        answers.nonEmptyTexts("no_words"),
        answers.nonEmptyTexts("yes_answers"),
        answers.nonEmptyTexts("no_answers"),
    );
}

ProfileStartupRequest profileStartupRequestFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ProfileStartupRequest(
        json.text("language"),
        json.text("mode"),
        json.text("resume_session_id"),
        json.text("model"),
    );
}

private string sessionResumeAnswersJson(ProfileSessionResumeAnswers answers)
{
    return jsonObject([
        jsonRawField("yes_words", stringArrayJson(answers.yesWords)),
        jsonRawField("no_words", stringArrayJson(answers.noWords)),
        jsonRawField("yes_answers", stringArrayJson(answers.yesAnswers)),
        jsonRawField("no_answers", stringArrayJson(answers.noAnswers)),
    ]);
}

private string stringArrayJson(string[] values)
{
    auto output = appender!string;
    output.put("[");
    foreach (index, value; values) {
        if (index) output.put(",");
        output.put(JSONValue(value).toString());
    }
    output.put("]");
    return output.data;
}

string profileStartupRequestJson(ProfileStartupRequest request)
{
    return jsonObject([
        jsonStringField("language", request.language),
        jsonStringField("mode", request.mode),
        jsonStringField("resume_session_id", request.resumeSessionId),
        jsonStringField("model", request.model),
    ]);
}

ProfileStartupSystemEvent profileStartupSystemFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ProfileStartupSystemEvent(
        json.text("kind"),
        json.text("message"),
    );
}

string profileStartupSystemJson(string kind, string message)
{
    return jsonObject([
        jsonStringField("kind", kind),
        jsonStringField("message", message),
    ]);
}

ProfileStartupOpened profileStartupOpenedFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ProfileStartupOpened(
        json.boolean("resumed_last_session"),
        json.text("session_id"),
        json.text("language"),
        json.enumeration!ReasoningMode("reasoning_mode"),
    );
}

string profileStartupOpenedJson(
    bool resumedLastSession,
    string sessionId,
    string language,
    ReasoningMode reasoningMode,
)
{
    return jsonObject([
        jsonBoolField("resumed_last_session", resumedLastSession),
        jsonStringField("session_id", sessionId),
        jsonStringField("language", language),
        jsonStringField("reasoning_mode", reasoningModeText(reasoningMode)),
    ]);
}

string profileStartupDoneJson(
    bool ok,
    bool resumedLastSession,
    string sessionId,
    string language,
    ReasoningMode reasoningMode,
    long memoryProcessedTurns,
    long memoryProcessedSessions,
    bool memoryFailed,
)
{
    return jsonObject([
        jsonBoolField("ok", ok),
        jsonBoolField("resumed_last_session", resumedLastSession),
        jsonStringField("session_id", sessionId),
        jsonStringField("language", language),
        jsonStringField("reasoning_mode", reasoningModeText(reasoningMode)),
        jsonLongField("memory_processed_turns", memoryProcessedTurns),
        jsonLongField("memory_processed_sessions", memoryProcessedSessions),
        jsonBoolField("memory_failed", memoryFailed),
    ]);
}

ProfileStartupResult profileStartupResultFromJson(JSONValue payload)
{
    auto json = Json.object(payload);
    return ProfileStartupResult(
        json.boolean("ok"),
        json.boolean("resumed_last_session"),
        json.text("session_id"),
        json.text("language"),
        json.enumeration!ReasoningMode("reasoning_mode"),
        json.integer("memory_processed_turns"),
        json.integer("memory_processed_sessions"),
        json.boolean("memory_failed"),
    );
}

string profileStartupErrorJson(string message)
{
    return jsonObject([
        jsonRawField("error", jsonObject([
            jsonStringField("code", "startup"),
            jsonStringField("message", message),
        ])),
    ]);
}

string profileStartupErrorMessage(JSONValue payload)
{
    return Json.object(payload).object("error").text("message");
}

unittest
{
    auto state = ProfileStartupState(
        true,
        "2026/07/14/10_00_00",
        "sk",
        "sk",
        ["en", "sk"],
        ProfileSessionResumeAnswers(
            ["áno", "ano"],
            ["nie"],
            ["hej"],
            ["ne"],
        ),
        ProfileStartupMessages(
            "Pokračovať?",
            "Odpovedz áno alebo nie.",
            "Po signáli povedz áno alebo nie.",
            "Nerozumel som.",
        ),
    );
    state = profileStartupStateFromJson(parseJSON(profileStartupStateJson(state)));
    assert(state.canResumeLastSession);
    assert(state.language == "sk");
    assert(state.resumeAnswers.yesWords == ["áno", "ano"]);
    assert(state.messages.voiceResumeUnclear == "Nerozumel som.");

    auto request = ProfileStartupRequest("sk", "voice", "2026/07/14/10_00_00", "");
    auto decoded = profileStartupRequestFromJson(parseJSON(profileStartupRequestJson(request)));
    assert(decoded.language == "sk");
    assert(decoded.mode == "voice");
    assert(decoded.resumeSessionId == "2026/07/14/10_00_00");
}
