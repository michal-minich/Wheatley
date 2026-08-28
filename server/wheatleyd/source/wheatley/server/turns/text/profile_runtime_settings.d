module wheatley.server.turns.text.profile_runtime_settings;

import std.exception : enforce;
import std.path : buildPath;

import wheatley.common.api.reasoning :
    ReasoningMode,
    nearestReasoningMode,
    parseReasoningMode;
import wheatley.server.i18n.product_translations : productTranslationText;
import wheatley.server.image_generation.config : loadImageGenerationConfig;
import wheatley.server.image_generation.types : ImagePreset;
import wheatley.server.pi.models : PiModelInfo;
import wheatley.server.profile.runtime : ResolvedSessionConfig;
import wheatley.server.profiles.config_properties :
    ProfileConfigIndex,
    languageConfigText,
    requiredConfigBool,
    requiredConfigInt,
    requiredConfigText;
import wheatley.server.turns.text.pi_runtime : piRuntimeModelName;
import wheatley.server.turns.text.generation_settings : resolveGenerationSettings;
import wheatley.server.tools.progress :
    ToolProgressMessages,
    loadToolProgressMessages;

struct ProfileRuntimeSettings
{
    string language;
    string defaultResponseLanguage;
    string piCommand;
    string piProvider;
    string piModel;
    string piModelName;
    long piContextWindow;
    long piImageLongEdgePx;
    long screenCaptureModelMaxLongEdgePx;
    double screenCaptureModelPixelsPerLogicalPixel;
    string assistantModel;
    string piModelMessage;
    string piUnavailableMessage;
    string piUnavailableDetailTemplate;
    string thinkingMessage;
    string toolsCurrentMessageTemplate;
    string toolsLimitedMessage;
    string memoryUpdateStartMessage;
    string memoryUpdateDoneMessage;
    string memoryUpdateFailedMessage;
    string reasoningWaitMessage;
    ToolProgressMessages toolProgress;
    ImagePreset[string] imageGenerationPresets;
    ProfileToolAvailability tools;
    string screenCaptureScope;
    ReasoningMode reasoningDefaultMode;
    ReasoningMode reasoningMemoryMode;
    ReasoningMode reasoningPrewarmMode;
    bool promptPrewarmEnabled;
    bool memoryAutoEnabled;
    long memoryAutoTriggerBytes;
    long memoryAutoMaxPendingHours;
    long maxToolCallsPerTurn;
    long maxOutputTokens;
    string providerRequestOverridesJson;
    string piGenerationExtensionPath;
}

struct ProfileToolAvailability
{
    bool read;
    bool write;
    bool edit;
    bool bash;
    bool webSearch;
    bool fetchContent;
    bool remember;
    bool capturePhoto;
    bool captureScreen;
    bool codexMessage;
    bool codexStatus;
    bool generateImage;
    bool imageSearch;
    bool scheduledTasks;
}

ProfileRuntimeSettings loadProfileRuntimeSettings(
    ResolvedSessionConfig resolved,
    PiModelInfo model,
    bool imageGenerationAvailable,
    ReasoningMode reasoningMode = ReasoningMode.off,
)
{
    auto props = resolved.configIndex;
    auto resourcesRoot = resolved.resourcesRoot;

    ProfileRuntimeSettings settings;
    settings.language = resolved.language;
    settings.maxToolCallsPerTurn = requiredConfigInt(props, "tools.max_calls_per_turn", 1, 1_000);
    settings.promptPrewarmEnabled = requiredConfigBool(
        props,
        "session.prompt_prewarm_enabled",
    );
    settings.piCommand = requiredConfigText(props, "pi.command");
    settings.piProvider = model.provider;
    settings.piModel = model.model;
    settings.piModelName = model.name;
    settings.piContextWindow = model.contextWindow;
    settings.piImageLongEdgePx = requiredConfigInt(
        props,
        "pi.image_long_edge_px",
        0,
        8192,
    );
    settings.screenCaptureModelMaxLongEdgePx = props.intValue(
        "screen_capture.model_max_long_edge_px",
        2560,
    );
    enforce(settings.screenCaptureModelMaxLongEdgePx >= 1
        && settings.screenCaptureModelMaxLongEdgePx <= 8192,
        "Screen capture model long edge is out of range");
    settings.screenCaptureModelPixelsPerLogicalPixel = props.realValue(
        "screen_capture.model_pixels_per_logical_pixel",
        1.0,
    );
    enforce(settings.screenCaptureModelPixelsPerLogicalPixel > 0
        && settings.screenCaptureModelPixelsPerLogicalPixel <= 4,
        "Screen capture model pixels per logical pixel is out of range");
    settings.assistantModel = piRuntimeModelName(model.provider, model.model);
    applyGenerationSettings(settings, props, model, reasoningMode);
    settings.piGenerationExtensionPath = buildPath(
        resourcesRoot,
        "pi",
        "extensions",
        "wheatley-generation.ts",
    );
    settings.reasoningDefaultMode = supportedReasoningMode(model, requiredConfigText(
        props,
        "reasoning.default_mode",
    ));
    settings.reasoningMemoryMode = supportedReasoningMode(model, requiredConfigText(
        props,
        "reasoning.memory_mode",
    ));
    settings.reasoningPrewarmMode = supportedReasoningMode(model, requiredConfigText(
        props,
        "reasoning.prewarm_mode",
    ));
    settings.memoryAutoEnabled = requiredConfigBool(props, "memory.auto_enabled");
    settings.memoryAutoTriggerBytes = requiredPositiveConfigInt(
        props,
        "memory.auto_trigger_bytes",
    );
    settings.memoryAutoMaxPendingHours = requiredPositiveConfigInt(
        props,
        "memory.auto_max_pending_hours",
    );
    settings.defaultResponseLanguage = languageConfigText(props, settings.language, "response_language");
    settings.piModelMessage = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.startup.piModel",
    );
    settings.piUnavailableMessage = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.startup.piUnavailable",
    );
    settings.piUnavailableDetailTemplate = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.startup.piUnavailableDetail",
    );
    settings.thinkingMessage = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.runtime.thinking",
    );
    settings.toolsCurrentMessageTemplate = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.startup.currentTools",
    );
    settings.toolsLimitedMessage = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.startup.limitedTools",
    );
    settings.memoryUpdateStartMessage = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.memory.updateStart",
    );
    settings.memoryUpdateDoneMessage = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.memory.updateDone",
    );
    settings.memoryUpdateFailedMessage = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.memory.updateFailed",
    );
    settings.reasoningWaitMessage = productTranslationText(
        resourcesRoot,
        settings.language,
        "speech.reasoning.wait",
    );
    settings.toolProgress = loadToolProgressMessages(resourcesRoot, settings.language);
    settings.tools = profileToolAvailability(props);
    settings.tools.generateImage = settings.tools.generateImage && imageGenerationAvailable;
    if (settings.tools.generateImage)
        settings.imageGenerationPresets = loadImageGenerationConfig(props).presets;
    if (!model.vision) settings.tools.imageSearch = false;
    return settings;
}

void applyGenerationSettings(
    ref ProfileRuntimeSettings settings,
    ProfileConfigIndex props,
    PiModelInfo model,
    ReasoningMode reasoningMode,
)
{
    auto generation = resolveGenerationSettings(props, model, reasoningMode);
    settings.maxOutputTokens = generation.maxOutputTokens;
    settings.providerRequestOverridesJson = generation.providerRequestJson;
}

private ReasoningMode supportedReasoningMode(PiModelInfo model, string configuredMode)
{
    if (!model.reasoning) return ReasoningMode.off;
    return nearestReasoningMode(model.reasoningModes, parseReasoningMode(configuredMode));
}

private long requiredPositiveConfigInt(ProfileConfigIndex props, string path)
{
    auto value = requiredConfigInt(props, path);
    enforce(value > 0, "Config value must be positive: " ~ path);
    return value;
}

ProfileToolAvailability profileToolAvailability(ProfileConfigIndex props)
{
    return ProfileToolAvailability(
        requiredToolAvailability(props, "read"),
        requiredToolAvailability(props, "write"),
        requiredToolAvailability(props, "edit"),
        requiredToolAvailability(props, "bash"),
        requiredToolAvailability(props, "web_search"),
        requiredToolAvailability(props, "fetch_content"),
        requiredToolAvailability(props, "remember"),
        requiredToolAvailability(props, "capture_photo"),
        props.boolValue("tools.available.capture_screen", true),
        requiredToolAvailability(props, "codex_message"),
        requiredToolAvailability(props, "codex_status"),
        requiredToolAvailability(props, "generate_image"),
        requiredToolAvailability(props, "image_search"),
        props.boolValue("tools.available.scheduled_tasks", true),
    );
}

/** The two lifecycle controls are deliberately scoped to a scheduler-owned
    invocation.  They must be part of the worker command fingerprint: Pi loads
    extensions only at process start, so reusing a normal-chat worker would
    otherwise leave an agent-managed occurrence unable to advance itself. */
string[] enabledPiToolNames(ProfileToolAvailability tools, bool scheduledTaskRun = false)
{
    string[] names;
    if (tools.read) names ~= "read";
    if (tools.write) names ~= "write";
    if (tools.edit) names ~= "edit";
    if (tools.bash) names ~= "bash";
    if (tools.webSearch) names ~= "web_search";
    if (tools.fetchContent) names ~= "fetch_content";
    if (tools.remember) names ~= "remember";
    if (tools.capturePhoto) names ~= "capture_photo";
    if (tools.captureScreen) names ~= "capture_screen";
    if (tools.codexMessage) names ~= "codex_message";
    if (tools.codexStatus) names ~= "codex_status";
    if (tools.generateImage) names ~= "generate_image";
    if (tools.imageSearch) names ~= "image_search";
    if (tools.scheduledTasks) {
        names ~= "create_scheduled_task";
        names ~= "list_scheduled_tasks";
        names ~= "get_scheduled_task";
        names ~= "update_scheduled_task";
        names ~= "set_scheduled_task_enabled";
        names ~= "run_scheduled_task_now";
        names ~= "delete_scheduled_task";
        if (scheduledTaskRun) {
            names ~= "schedule_next_occurrence";
            names ~= "complete_current_scheduled_task";
        }
    }
    return names;
}

private bool requiredToolAvailability(ProfileConfigIndex props, string toolName)
{
    return requiredConfigBool(props, "tools.available." ~ toolName);
}
