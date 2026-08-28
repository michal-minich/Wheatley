module wheatley.server.startup.profile_startup;

import std.array : join;
import std.exception : enforce;
import std.string : replace, strip;

import vibe.core.sync : TaskMutex;

import wheatley.common.api.profile_startup :
    ProfileStartupRequest,
    ProfileStartupMessages,
    ProfileStartupState,
    profileStartupDoneJson,
    profileStartupOpenedJson,
    profileStartupSystemJson;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.reasoning : ReasoningMode;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.pi.models : PiModels;
import wheatley.server.profile.runtime : ProfileRuntime;
import wheatley.server.history.documents.profile_auto_memory_types : SessionAutoMemoryPlan;
import wheatley.server.memory.session_auto_memory :
    SessionAutoMemoryResult,
    hasSessionAutoMemoryWork,
    planSessionAutoMemory,
    runPlannedSessionAutoMemory;
import wheatley.server.i18n.product_translations : productTranslationText;
import wheatley.server.profiles.config_properties : supportedProfileLanguages;
import wheatley.server.startup.session_resume_answers : loadSessionResumeAnswers;
import wheatley.server.turns.text.profile_runtime_settings : ProfileRuntimeSettings,
    applyGenerationSettings,
    loadProfileRuntimeSettings;
import wheatley.server.turns.text.pi_runtime : checkPiAvailability;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.conversation.port : ConversationPreparationPort;
import wheatley.server.turns.text.pi_run_gate : PiRunGate;
import wheatley.server.session_use_registry : SessionUseRegistry;

void streamProfileStartup(
    HistoryStore store,
    ProfileRuntime profiles,
    string profileId,
    ProfileStartupRequest request,
    string resourcesRoot,
    ConversationPreparationPort conversationPreparation,
    PiRunGate piRuns,
    SessionUseRegistry sessionUses,
    PiModels models,
    bool delegate() imageGenerationAvailable,
    void delegate(string eventName, string dataJson) emit,
)
{
    auto sessionStartedAt = nowIso();
    SessionKey session;
    bool sessionUseActive;
    scope(exit) if (sessionUseActive) sessionUses.finish(session);
    if (request.resumeSessionId.length) {
        session = SessionKey(profileId, request.resumeSessionId);
        sessionUses.begin(session);
        sessionUseActive = true;
        session = store.resumeProfileSession(profileId, request.resumeSessionId, request.mode);
    }
    auto resumedSessionLanguage = session.sessionId.length ? store.sessionLanguage(session) : "";
    auto requestedLanguage = resumedSessionLanguage.length
        ? resumedSessionLanguage
        : request.language;
    auto requestedModel = request.model.length
        ? request.model
        : (session.sessionId.length ? store.sessionModel(session) : "");
    auto chatModel = models.chatModel(requestedModel);
    auto resolved = profiles.resolveSession(profileId, requestedLanguage);
    auto imageAvailable = imageGenerationAvailable();
    auto settings = loadProfileRuntimeSettings(resolved, chatModel, imageAvailable);
    auto resumed = session.sessionId.length > 0;
    if (resumed) {
        store.setSessionLanguage(session, settings.language);
        store.setSessionModel(session, chatModel.key);
    } else {
        session = store.startProfileSession(
            profileId,
            sessionStartedAt,
            request.mode,
            settings.language,
            settings.reasoningDefaultMode,
            chatModel.key,
        );
        sessionUses.begin(session);
        sessionUseActive = true;
    }
    auto preparation = conversationPreparation.beginSessionPreparation(session);
    auto localAgentStartup = conversationPreparation.performsLocalAgentStartup();
    TaskMutex memoryMutex;
    bool memoryLocked;
    if (localAgentStartup && !resumed) {
        memoryMutex = store.sessionAutoMemoryMutex(profileId);
        memoryMutex.lock();
        memoryLocked = true;
    }
    SessionAutoMemoryPlan memoryPlan;
    if (localAgentStartup && !resumed) {
        memoryPlan = planSessionAutoMemory(store, session, settings);
    }
    ProfileRuntimeSettings memorySettings;
    if (localAgentStartup) {
        memorySettings = loadProfileRuntimeSettings(
            resolved,
            models.memoryModel(chatModel),
            imageAvailable,
        );
        applyGenerationSettings(
            memorySettings,
            resolved.configIndex,
            models.memoryModel(chatModel),
            memorySettings.reasoningMemoryMode,
        );
    }

    try {
        if (localAgentStartup) {
            auto pi = checkPiAvailability(settings.piCommand);
            if (!pi.available)
            {
                emitSystem(emit, "pi_unavailable", localizedPiUnavailable(settings, pi.detail));
                emitStartupDone(
                    emit,
                    false,
                    resumed,
                    session.sessionId,
                    settings.language,
                    store.sessionReasoningMode(session),
                    SessionAutoMemoryResult(),
                );
                if (memoryLocked) {
                    memoryMutex.unlock();
                    memoryLocked = false;
                }
                conversationPreparation.finishSessionPreparation(session, preparation);
                return;
            }
        }

        if (hasSessionAutoMemoryWork(memoryPlan)) {
            emitSystem(emit, "memory_update_start", settings.memoryUpdateStartMessage);
        }
        emitSystem(emit, "model_selection", modelSelectionMessage(resourcesRoot, settings, request.mode));
        emitSystem(emit, "tools", piToolsMessage(resourcesRoot, settings));
        emit("opened", profileStartupOpenedJson(
            resumed,
            session.sessionId,
            settings.language,
            store.sessionReasoningMode(session),
        ));
        SessionAutoMemoryResult memory;
        if (localAgentStartup) {
            memory = runPlannedSessionAutoMemory(
                store,
                session,
                resourcesRoot,
                memoryPlan,
                memorySettings,
                piRuns,
                (kind, message) { emitSystem(emit, kind, message); },
                false,
            );
        }
        if (memoryLocked) {
            memoryMutex.unlock();
            memoryLocked = false;
        }
        emitStartupDone(
            emit,
            true,
            resumed,
            session.sessionId,
            settings.language,
            store.sessionReasoningMode(session),
            memory,
        );
        conversationPreparation.finishSessionPreparation(session, preparation);
    } catch (Exception error) {
        if (memoryLocked) memoryMutex.unlock();
        conversationPreparation.finishSessionPreparation(session, preparation, error.msg);
        throw error;
    }
}

ProfileStartupState loadProfileStartupState(
    HistoryStore store,
    ProfileRuntime profiles,
    string profileId,
    string requestedLanguage,
)
{
    auto canResume = store.canResumeLastProfileSession(profileId);
    auto lastSessionLanguage = canResume ? store.lastSessionLanguage(profileId) : "";
    auto resolved = profiles.resolveSession(
        profileId,
        requestedLanguage.length ? requestedLanguage : lastSessionLanguage,
    );
    auto props = resolved.configIndex;
    auto language = resolved.language;
    return ProfileStartupState(
        canResume,
        canResume ? store.lastSessionId(profileId) : "",
        language,
        lastSessionLanguage,
        supportedProfileLanguages(props),
        loadSessionResumeAnswers(props, language),
        startupMessages(store.resourcesRoot, language),
    );
}

private ProfileStartupMessages startupMessages(string resourcesRoot, string language)
{
    return ProfileStartupMessages(
        productTranslationText(resourcesRoot, language, "speech.session.textResumePrompt"),
        productTranslationText(resourcesRoot, language, "speech.session.textResumeUnclear"),
        productTranslationText(resourcesRoot, language, "speech.session.voiceResumePrompt"),
        productTranslationText(resourcesRoot, language, "speech.session.voiceResumeUnclear"),
    );
}

private void emitStartupDone(
    void delegate(string eventName, string dataJson) emit,
    bool ok,
    bool resumedLastSession,
    string sessionId,
    string language,
    ReasoningMode reasoningMode,
    SessionAutoMemoryResult memory,
)
{
    emit("done", profileStartupDoneJson(
        ok,
        resumedLastSession,
        sessionId,
        language,
        reasoningMode,
        memory.processedMessages,
        memory.processedSessions,
        memory.failed,
    ));
}

private string modelSelectionMessage(
    string resourcesRoot,
    ProfileRuntimeSettings settings,
    string mode,
)
{
    auto model = settings.piModelMessage;
    if (mode != "voice")
    {
        return ensureSentence(model.replace("{model}", settings.piModelName));
    }
    auto stt = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.startup.localStt",
    );
    auto templateText = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.startup.modelSelectionTemplate",
    );
    auto message = templateText;
    message = message.replace("{model}", model.replace("{model}", settings.piModelName));
    message = message.replace("{stt}", stt);
    return ensureSentence(message);
}

private string piToolsMessage(string resourcesRoot, ProfileRuntimeSettings settings)
{
    string[] labels;

    void add(bool enabled, string toolName)
    {
        if (enabled) labels ~= toolLabel(resourcesRoot, settings.language, toolName);
    }

    add(settings.tools.read, "read");
    add(settings.tools.write, "write");
    add(settings.tools.edit, "edit");
    add(settings.tools.bash, "bash");
    add(settings.tools.webSearch, "web_search");
    add(settings.tools.fetchContent, "fetch_content");
    add(settings.tools.remember, "remember");
    add(settings.tools.capturePhoto, "capture_photo");
    add(settings.tools.captureScreen, "capture_screen");
    add(settings.tools.codexMessage, "codex_message");
    add(settings.tools.codexStatus, "codex_status");
    add(settings.tools.generateImage, "generate_image");
    add(settings.tools.imageSearch, "image_search");

    if (!labels.length) {
        return settings.toolsLimitedMessage;
    }
    return ensureSentence(settings.toolsCurrentMessageTemplate.replace("{tools}", labels.join(", ")));
}

private string localizedPiUnavailable(ProfileRuntimeSettings settings, string detail)
{
    auto message = settings.piUnavailableMessage;
    auto cleanDetail = detail.strip;
    if (!cleanDetail.length)
        return message;
    return settings.piUnavailableDetailTemplate
        .replace("{message}", message)
        .replace("{detail}", cleanDetail);
}

private string toolLabel(string resourcesRoot, string language, string toolName)
{
    return productTranslationText(
        resourcesRoot,
        language,
        "speech.startup.toolLabels." ~ toolName,
    );
}

private void emitSystem(void delegate(string eventName, string dataJson) emit, string kind, string message)
{
    auto clean = message.strip;
    if (!clean.length)
        return;
    emit("system", profileStartupSystemJson(kind, clean));
}

private string ensureSentence(string text)
{
    auto clean = text.strip;
    if (!clean.length)
        return "";
    auto last = clean[$ - 1];
    if (last == '.' || last == '!' || last == '?')
        return clean;
    return clean ~ ".";
}
