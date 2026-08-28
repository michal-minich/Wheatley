module wheatley.server.api.wheatley_api;

import std.conv : to;
import std.exception : enforce;
import std.file : readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.string : strip;

import vibe.http.common : HTTPStatus;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
import vibe.http.websockets : WebSocket;

import wheatley.server.api.runtime.turn_responses :
    acceptedVoiceCommitStreamResponse,
    clientTurnMetricsResponse,
    imageTurnStreamResponse,
    speechInterruptTranscriptionResponse,
    stopTurnSpeechResponse,
    stopTextTurnResponse,
    synthesizeSpeechResponse,
    stageUserImageResponse,
    turnSpeechStreamResponse,
    textTurnStreamResponse,
    presentationImageResponse,
    presentationScreenCaptureModelResponse,
    turnScreenCaptureModelResponse,
    uploadedImageResponse,
    userImageResponse;
import wheatley.server.api.runtime.audio_playback_responses : audioPlaybackEventResponse;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.reasoning : ReasoningMode, parseReasoningMode, reasoningModeText;
import wheatley.server.api.runtime.requests : profileMemoryAppendRequest;
import wheatley.server.api.runtime.startup_response : profileStartupStreamResponse;
import wheatley.server.api.runtime.sync_responses :
    completedTurnImportResponse,
    latestSessionSyncFileResponse,
    latestSessionSyncManifestResponse,
    profileReplicaSyncResponse;
import wheatley.server.api.runtime.remote_turn_sync_responses :
    remoteTurnFileResponse,
    remoteTurnManifestResponse,
    remoteTurnSessionHandoffResponse;
import wheatley.server.api.runtime.accepted_voice_sync_response :
    acceptedVoiceSyncResponse;
import wheatley.common.api.profile_startup : profileStartupStateJson;
import wheatley.server.startup.profile_startup : loadProfileStartupState;
import wheatley.server.api.http.json_response : addCommonHeaders, handleJson, writeError;
import wheatley.server.api.runtime.client_tool_responses :
    advertiseClientToolClientResponse,
    clientToolArtifactResponse,
    clientToolRequestDetailResponse,
    clientToolRequestsResponse,
    completeClientToolRequestResponse,
    createClientToolRequestResponse,
    uploadClientToolArtifactResponse;
import wheatley.server.api.runtime.codex_responses :
    codexMessageResponse,
    codexStatusResponse,
    codexEventsResponse,
    sessionPresentationResponse;
import wheatley.server.api.runtime.session_turn_responses : sessionTurnEventsResponse;
import wheatley.server.api.runtime.session_queue_responses :
    sessionQueueResponse,
    cancelSessionQueueItemResponse,
    compactSessionQueueResponse,
    failSessionQueuePreparationResponse,
    reserveSessionQueueItemResponse,
    touchSessionQueuePreparationResponse;
import wheatley.server.api.runtime.media_responses :
    audioArtifactResponse,
    acceptedVoiceAudioResponse,
    generatedAudioArtifactResponse,
    listeningChimeResponse,
    thinkingMusicAssetResponse,
    thinkingMusicNextResponse;
import wheatley.server.api.runtime.profile_identity : requireProfileId;
import wheatley.server.api.core.config : ServerConfig;
import wheatley.common.json.object : jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.choice : requireChoice;
import wheatley.common.json.read : Json;
import wheatley.server.api.http.request_params : queryParam;
import wheatley.server.client_tools.store : ClientToolStore;
import wheatley.server.codex.client : CodexWorkerClient;
import wheatley.server.codex.port : CodexSessionPort;
import wheatley.server.config.app_config_store : AppConfigStore;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.store.llm_requests : LlmRequestCapture;
import wheatley.server.pi.models : PiModels;
import wheatley.server.profile.runtime : ProfileRuntime;
import wheatley.server.media.thinking_music : ThinkingMusicLibrary;
import wheatley.server.profiles.config_properties :
    indexProfileConfigProperties,
    requiredConfigInt,
    requiredConfigBool,
    requiredConfigTextList,
    requiredConfigText;
import wheatley.server.tts.on_demand : OnDemandTts;
import wheatley.server.tts.turn_speech_registry : TurnSpeechRegistry;
import wheatley.server.tts.turn_speech_stream : TurnSpeechStream;
import wheatley.server.voice.runtime : VoiceRuntime;
import wheatley.server.voice.accepted_replica :
    AcceptedVoiceReplica,
    FfmpegAcceptedVoiceOpusValidator;
import wheatley.server.turns.text.pi_runtime :
    PiAvailability,
    checkPiAvailability;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.runtime.deployment :
    DeploymentComposition,
    deploymentCompositionText;
import wheatley.common.runtime.conversation_placement :
    ConversationPlacement,
    conversationPlacementText;
import wheatley.server.conversation.pi_agent_runtime : PiAgentRuntime;
import wheatley.server.conversation.port : ConversationPort, ConversationPreparationPort;
import wheatley.server.conversation.runtime : ConversationRuntime;
import wheatley.server.conversation.remote_http_port : RemoteConversationHttpPort;
import wheatley.server.turns.text.pi_run_gate : PiRunGate;
import wheatley.server.turns.text.session_work_lanes : SessionWorkLanes;
import wheatley.server.session_use_registry : SessionUseRegistry;
import wheatley.server.sync.service : ProfileSyncService;
import wheatley.server.stt.whisper_cpp : WhisperCppWorkers;
import wheatley.server.image_generation.config : loadImageGenerationConfig;
import wheatley.server.image_generation.remote_http_port : RemoteImageGeneratorHttpPort;
import wheatley.server.image_generation.runtime : ImageGenerationRuntime;
import wheatley.common.api.generated_image : generatedImageArtifactJson;
import wheatley.server.web_images.runtime : WebImageRuntime;
import wheatley.common.api.web_image : webImageArtifactJson;
import wheatley.server.scheduled_tasks.store : ScheduledTaskStore;
import wheatley.server.scheduled_tasks.scheduler : Scheduler;
import wheatley.server.scheduled_tasks.presence : ActiveChatPresenceRegistry;
import wheatley.server.queue.session_queue_migration : SessionQueueMigrator;

class WheatleyApi
{
    private ServerConfig config;
    private AppConfigStore appConfig;
    private HistoryStore store;
    private ProfileRuntime profileRuntime;
    private RuntimeFiles files;
    private OnDemandTts tts;
    private TurnSpeechStream speech;
    private ConversationPort conversations;
    private ConversationPreparationPort conversationPreparation;
    private ConversationRuntime localConversations;
    private VoiceRuntime voice;
    private ClientToolStore clientTools;
    private PiRunGate piRuns;
    private SessionUseRegistry sessionUses;
    private PiModels piModels;
    private CodexSessionPort codex;
    private WhisperCppWorkers stt;
    private ThinkingMusicLibrary thinkingMusicLibrary;
    private ProfileSyncService profileSync;
    private AcceptedVoiceReplica acceptedVoiceReplica;
    private ImageGenerationRuntime imageGeneration;
    private WebImageRuntime webImages;
    private ScheduledTaskStore scheduledTasks;
    private Scheduler scheduler;
    private ActiveChatPresenceRegistry scheduledTaskPresence;

    this(
        ServerConfig config,
        AppConfigStore appConfig,
        HistoryStore store,
        RuntimeFiles files,
    )
    {
        this.config = config;
        this.appConfig = appConfig;
        this.store = store;
        this.profileRuntime = new ProfileRuntime(store);
        this.files = files;
        this.tts = new OnDemandTts(config, store, profileRuntime, files);
        auto speechTurns = new TurnSpeechRegistry;
        this.speech = new TurnSpeechStream(store, files, tts, speechTurns);
        this.clientTools = new ClientToolStore(config.profilesRoot, store);
        this.webImages = new WebImageRuntime(store);
        this.scheduledTasks = new ScheduledTaskStore(config.profilesRoot);
        this.scheduledTaskPresence = new ActiveChatPresenceRegistry;
        auto appProperties = appConfig.properties();
        auto appProps = indexProfileConfigProperties(appProperties);
        if (requiredConfigBool(appProps, "tools.available.generate_image")) {
            auto imageToken = environment.get("WHEATLEY_IMAGE_API_TOKEN", "");
            enforce(imageToken.length, "WHEATLEY_IMAGE_API_TOKEN is required when image generation is enabled");
            auto imageConfig = loadImageGenerationConfig(appProps);
            this.imageGeneration = new ImageGenerationRuntime(
                store,
                new RemoteImageGeneratorHttpPort(
                    imageConfig.endpoint,
                    imageToken,
                    imageConfig.timeoutSeconds,
                ),
                imageConfig,
            );
        }
        this.piModels = new PiModels(
            requiredConfigText(appProps, "pi.command"),
            config.appDataRoot,
            requiredConfigTextList(appProperties, "memory.models.[]"),
        );
        this.piRuns = new PiRunGate(requiredConfigInt(appProps, "pi.max_concurrent_runs"));
        this.sessionUses = new SessionUseRegistry;
        this.codex = new CodexWorkerClient(config.codexSocket);
        this.stt = new WhisperCppWorkers;
        this.thinkingMusicLibrary = new ThinkingMusicLibrary(config.resourcesRoot, appConfig);
        this.acceptedVoiceReplica = new AcceptedVoiceReplica(
            files,
            new FfmpegAcceptedVoiceOpusValidator(config.appDataRoot),
            (artifact) {
                auto session = SessionKey(artifact.profileId, artifact.sessionId);
                auto turn = store.findTurnBySubmission(session, artifact.submissionId);
                return turn.id.length
                    && (turn.status == "completed" || turn.status == "failed"
                        || turn.status == "stopped");
            },
        );
        if (config.deploymentComposition == DeploymentComposition.syncedHybrid) {
            this.profileSync = new ProfileSyncService(
                store,
                files,
                buildPath(config.appDataRoot, "device-data", "profile-sync", "outbox"),
                config.syncUpstreamApiBase,
                config.syncIntervalSeconds,
            );
        }
        final switch (config.conversationPlacement) {
            case ConversationPlacement.local:
                auto agent = new PiAgentRuntime(config, store, piRuns);
                auto localConversations = new ConversationRuntime(
                    store,
                    profileRuntime,
                    agent,
                    speechTurns,
                    new SessionWorkLanes,
                    piModels,
                    clientTools,
                    () => imageGeneration !is null && imageGeneration.healthy(),
                );
                this.localConversations = localConversations;
                this.conversations = localConversations;
                this.conversationPreparation = localConversations;
                break;
            case ConversationPlacement.remote:
                enforce(profileSync !is null,
                    "Remote Conversation placement requires profile synchronization");
                auto remoteConversations = new RemoteConversationHttpPort(
                    config.conversationRemoteApiBase,
                    profileSync.remoteTurnGate(),
                    speechTurns,
                );
                this.conversations = remoteConversations;
                this.conversationPreparation = remoteConversations;
                break;
        }
        this.voice = new VoiceRuntime(
            config,
            store,
            profileRuntime,
            conversations,
            conversationPreparation,
            sessionUses,
            stt,
        );
        this.scheduler = new Scheduler(
            store,
            scheduledTasks,
            conversations,
            scheduledTaskPresence,
            piModels,
        );
    }

    void start()
    {
        if (localConversations !is null) {
            // Only the selected Conversation authority owns queue storage.
            // Migration runs before local recovery and dispatch; a remote
            // placement performs the same work on its paired host.
            (new SessionQueueMigrator(store)).migrateAll();
            localConversations.recoverInterruptedTurns();
            localConversations.startPreparationWatchdog();
        }
        scheduler.recoverAbandonedClaims();
        if (profileSync !is null) profileSync.start();
        scheduler.start();
    }

    void shutdown()
    {
        scheduler.stop();
        if (profileSync !is null) profileSync.stop();
        conversations.shutdown();
        stt.shutdown();
    }

    void health(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () => healthJson());
    }

    void status(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () => store.statusJson());
    }

    void models(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () => piModels.json());
    }

    void listeningChime(HTTPServerRequest req, HTTPServerResponse res)
    {
        listeningChimeResponse(req, res, config.resourcesRoot, config.corsOrigin);
    }

    void thinkingMusicNext(HTTPServerRequest req, HTTPServerResponse res)
    {
        thinkingMusicNextResponse(
            req,
            res,
            thinkingMusicLibrary,
            store,
            config.corsOrigin,
        );
    }

    void thinkingMusicAsset(HTTPServerRequest req, HTTPServerResponse res)
    {
        thinkingMusicAssetResponse(
            req,
            res,
            thinkingMusicLibrary,
            store,
            config.corsOrigin,
        );
    }

    void profiles(HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () => store.profilesJson());
    }

    void clientConfig(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () => appConfig.clientConfigJson(req.params["client_id"]));
    }


    void translations(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () {
            const language = req.params["language"];
            requireChoice!("en", "sk", "de")(language, "language");
            return readText(buildPath(
                config.resourcesRoot,
                "translations",
                language ~ ".json",
            ));
        });
    }

    void updateClientConfig(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () => appConfig.saveClientConfig(
            req.params["client_id"],
            Json.bodyObject(req).value,
        ));
    }






    void appendProfileMemory(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto request = profileMemoryAppendRequest(req);
            store.appendUserPreference(profileId, request.memory, nowIso());
            return jsonObject([
                jsonBoolField("ok", true),
                jsonStringField("profile_id", profileId),
                jsonStringField("remembered", request.memory),
            ]);
        });
    }

    void scheduledTaskList(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () => scheduledTasks.listJson(
            requireProfileId(req, store),
        ));
    }

    void generatedImages(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto session = SessionKey(profileId, queryParam(req, "session_id"));
            store.requireSession(session);
            return jsonObject([jsonRawField(
                "images",
                store.sessionGeneratedImagesJson(session),
            )]);
        });
    }

    void reportScheduledTaskPresence(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto body = Json.bodyObject(req);
            auto yieldRequested = scheduledTaskPresence.report(profileId, body.value);
            // Only a visible client reports a presentation as seen.  A silent
            // background tab continues to carry the Home marker.
            if (body.boolean("visible")) store.markScheduledSessionSeen(
                SessionKey(profileId, body.nonEmpty("session_id")),
            );
            return jsonObject([
                jsonBoolField("ok", true),
                jsonBoolField("yield_requested", yieldRequested),
            ]);
        });
    }

    void createScheduledTask(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto input = Json.bodyObject(req);
            auto sessionId = input.nonEmpty("session_id");
            auto turnId = input.nonEmpty("turn_id");
            auto session = SessionKey(profileId, sessionId);
            store.requireSession(session);
            enforce(store.findTurn(session, turnId).id.length, "Turn not found");
            auto model = store.sessionModel(session);
            enforce(model.length, "Current chat has no selected model.");
            auto reasoningMode = reasoningModeText(store.sessionReasoningMode(session));
            return scheduledTasks.create(
                profileId,
                sessionId,
                turnId,
                model,
                reasoningMode,
                input.object("task").value,
                (task) { validateScheduledTaskDefinition(task); },
            );
        });
    }

    void scheduledTask(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () => scheduledTasks.getJson(
            requireProfileId(req, store),
            req.params["task_id"],
        ));
    }

    void updateScheduledTask(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto input = Json.bodyObject(req);
            auto sessionId = input.opt.textOrEmpty("session_id");
            SessionKey session;
            if (sessionId.length) {
                session = SessionKey(profileId, sessionId);
                store.requireSession(session);
            }
            auto turnId = input.opt.textOrEmpty("turn_id");
            if (turnId.length) {
                enforce(sessionId.length, "Turn requires a session");
                enforce(store.findTurn(session, turnId).id.length, "Turn not found");
            }
            auto model = input.opt.textOrEmpty("model");
            if (!model.length && sessionId.length) model = store.sessionModel(session);
            return scheduledTasks.update(
                profileId, req.params["task_id"], sessionId, turnId, model,
                input.object("patch").value, true,
                (task) { validateScheduledTaskDefinition(task); },
            );
        });
    }

    void setScheduledTaskEnabled(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () => scheduledTasks.setEnabled(
            requireProfileId(req, store),
            req.params["task_id"],
            Json.bodyObject(req).boolean("enabled"),
        ));
    }

    void runScheduledTaskNow(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () => scheduledTasks.runNow(
            requireProfileId(req, store),
            req.params["task_id"],
        ));
    }

    void scheduleCurrentTaskNext(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto body = Json.bodyObject(req);
            auto session = SessionKey(profileId, body.nonEmpty("session_id"));
            auto turn = store.findTurn(session, body.nonEmpty("turn_id"));
            enforce(turn.id.length && turn.source == "scheduled_task", "No current scheduled task run");
            return scheduledTasks.scheduleNextForSubmission(
                profileId, turn.submissionId, body.object("when").value,
            );
        });
    }

    void completeCurrentScheduledTask(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto body = Json.bodyObject(req);
            auto session = SessionKey(profileId, body.nonEmpty("session_id"));
            auto turn = store.findTurn(session, body.nonEmpty("turn_id"));
            enforce(turn.id.length && turn.source == "scheduled_task", "No current scheduled task run");
            auto reason = body.opt.textOrEmpty("reason").strip;
            enforce(reason.length <= 500, "Completion reason is too long");
            return scheduledTasks.completeForSubmission(profileId, turn.submissionId, reason);
        });
    }

    void deleteScheduledTask(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () => scheduledTasks.deleteTask(
            requireProfileId(req, store),
            req.params["task_id"],
        ));
    }

    void instructionDocuments(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            return store.instructionDocumentsJson(profileId);
        });
    }

    void saveInstructionDocuments(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            return store.saveInstructionDocuments(profileId, Json.bodyObject(req));
        });
    }

    void imageGenerationHealth(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () => jsonObject([
            jsonBoolField("ok", imageGeneration !is null && imageGeneration.healthy()),
            jsonBoolField("configured", imageGeneration !is null),
        ]));
    }

    void generateImage(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            enforce(imageGeneration !is null, "Image generation is not configured");
            auto profileId = requireProfileId(req, store);
            return generatedImageArtifactJson(
                imageGeneration.generate(profileId, Json.bodyObject(req)),
            );
        });
    }

    void persistWebImage(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            return webImageArtifactJson(
                webImages.persist(profileId, Json.bodyObject(req)),
            );
        });
    }

    void codexMessage(HTTPServerRequest req, HTTPServerResponse res)
    {
        codexMessageResponse(req, res, store, profileRuntime, codex, config.corsOrigin);
    }

    void codexStatus(HTTPServerRequest req, HTTPServerResponse res)
    {
        codexStatusResponse(req, res, store, profileRuntime, codex, config.corsOrigin);
    }



    void codexEvents(HTTPServerRequest req, HTTPServerResponse res)
    {
        codexEventsResponse(req, res, store, codex, config.corsOrigin);
    }

    void sessionPresentation(HTTPServerRequest req, HTTPServerResponse res)
    {
        sessionPresentationResponse(req, res, store, codex, config.corsOrigin);
    }

    void compactSession(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto session = SessionKey(profileId, Json.bodyObject(req).text("session_id"));
            store.requireSession(session);
            sessionUses.begin(session);
            scope(exit) sessionUses.finish(session);
            return conversations.compact(session);
        });
    }

    void branchSession(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto body = Json.bodyObject(req);
            auto source = SessionKey(profileId, body.text("session_id"));
            store.requireSession(source);
            sessionUses.begin(source);
            scope(exit) sessionUses.finish(source);
            auto branch = store.branchProfileSession(
                profileId,
                source.sessionId,
                body.text("turn_id"),
                body.choice!("user", "reasoning", "assistant", "artifact")("kind"),
                body.text("item_id"),
            );
            return jsonObject([
                jsonStringField("session_id", branch.sessionId),
                jsonStringField("language", store.sessionLanguage(branch)),
            ]);
        });
    }

    void profileStartupStream(HTTPServerRequest req, HTTPServerResponse res)
    {
        profileStartupStreamResponse(
            req,
            res,
            store,
            profileRuntime,
            conversationPreparation,
            piRuns,
            sessionUses,
            piModels,
            () => imageGeneration !is null && imageGeneration.healthy(),
            config.resourcesRoot,
            config.corsOrigin,
        );
    }

    void profileStartup(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto state = loadProfileStartupState(
                store,
                profileRuntime,
                profileId,
                queryParam(req, "language"),
            );
            return profileStartupStateJson(state);
        });
    }

    void sessionTurns(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto session = SessionKey(
                profileId,
                queryParam(req, "session_id"),
            );
            sessionUses.begin(session);
            scope(exit) sessionUses.finish(session);
            // A newly opened chat has a durable session root before its first
            // turn, so its canonical empty transcript is readable already.
            store.requireSession(session);
            return store.sessionTurnsJson(session);
        });
    }

    void sessionTurnEvents(HTTPServerRequest req, HTTPServerResponse res)
    {
        sessionTurnEventsResponse(req, res, store, config.corsOrigin);
    }

    void sessionQueue(HTTPServerRequest req, HTTPServerResponse res)
    {
        sessionQueueResponse(req, res, store, conversations, config.corsOrigin);
    }

    void cancelSessionQueueItem(HTTPServerRequest req, HTTPServerResponse res)
    {
        cancelSessionQueueItemResponse(req, res, store, conversations, config.corsOrigin);
    }

    void reserveSessionQueueItem(HTTPServerRequest req, HTTPServerResponse res)
    {
        reserveSessionQueueItemResponse(req, res, store, config.corsOrigin);
    }

    void touchSessionQueuePreparation(HTTPServerRequest req, HTTPServerResponse res)
    {
        touchSessionQueuePreparationResponse(req, res, store, config.corsOrigin);
    }

    void failSessionQueuePreparation(HTTPServerRequest req, HTTPServerResponse res)
    {
        failSessionQueuePreparationResponse(req, res, store, config.corsOrigin);
    }

    void compactSessionQueue(HTTPServerRequest req, HTTPServerResponse res)
    {
        compactSessionQueueResponse(req, res, store, config.corsOrigin);
    }

    void importCompletedTurn(HTTPServerRequest req, HTTPServerResponse res)
    {
        completedTurnImportResponse(req, res, store, config.corsOrigin);
    }

    void latestSessionSyncManifest(HTTPServerRequest req, HTTPServerResponse res)
    {
        latestSessionSyncManifestResponse(req, res, store, config.corsOrigin);
    }

    void profileReplicaSync(HTTPServerRequest req, HTTPServerResponse res)
    {
        profileReplicaSyncResponse(req, res, store, config.corsOrigin);
    }

    void latestSessionSyncFile(HTTPServerRequest req, HTTPServerResponse res)
    {
        latestSessionSyncFileResponse(req, res, store, config.corsOrigin);
    }

    void remoteTurnSessionHandoff(HTTPServerRequest req, HTTPServerResponse res)
    {
        remoteTurnSessionHandoffResponse(req, res, store, config.corsOrigin);
    }

    void remoteTurnManifest(HTTPServerRequest req, HTTPServerResponse res)
    {
        remoteTurnManifestResponse(req, res, store, config.corsOrigin);
    }

    void remoteTurnFile(HTTPServerRequest req, HTTPServerResponse res)
    {
        remoteTurnFileResponse(req, res, store, config.corsOrigin);
    }

    void acceptedVoiceSync(HTTPServerRequest req, HTTPServerResponse res)
    {
        acceptedVoiceSyncResponse(
            req,
            res,
            store,
            acceptedVoiceReplica,
            config.corsOrigin,
        );
    }

    void recentSessions(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            return store.recentSessionsJson(profileId);
        });
    }

    void deleteSession(HTTPServerRequest req, HTTPServerResponse res)
    {
        SessionKey session;
        bool deleting;
        bool resolved;
        try {
            auto profileId = requireProfileId(req, store);
            session = SessionKey(profileId, queryParam(req, "session_id"));
            store.requireResumableSession(session);
            resolved = true;
            if (!sessionUses.beginDelete(session)) {
                writeError(res, HTTPStatus.conflict, "session_busy", "Session is busy", config.corsOrigin);
                return;
            }
            deleting = true;
            store.deleteSession(session);
            addCommonHeaders(res, config.corsOrigin);
            res.statusCode = HTTPStatus.noContent;
            res.writeVoidBody();
        } catch (Exception error) {
            writeError(
                res,
                resolved ? HTTPStatus.internalServerError : HTTPStatus.notFound,
                resolved ? "session_delete_failed" : "session_not_found",
                error.msg,
                config.corsOrigin,
            );
        } finally {
            if (deleting) sessionUses.finishDelete(session);
        }
    }

    void toolDetail(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto session = SessionKey(profileId, queryParam(req, "session_id"));
            sessionUses.begin(session);
            scope(exit) sessionUses.finish(session);
            return store.toolDetailJson(
                session,
                req.params["turn_id"],
                req.params["call_index"].to!long,
            );
        });
    }

    void captureLlmRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto session = SessionKey(profileId, queryParam(req, "session_id"));
            sessionUses.begin(session);
            scope(exit) sessionUses.finish(session);
            auto body = Json.bodyObject(req);
            auto index = store.appendLlmRequest(
                session,
                req.params["turn_id"],
                LlmRequestCapture(
                    body.nonEmpty("captured_at"),
                    body.nonEmpty("pi_version"),
                    body.object("request").value,
                ),
            );
            return jsonObject([jsonLongField("request_index", index)]);
        });
    }

    void reasoningDetail(HTTPServerRequest req, HTTPServerResponse res)
    {
        res.headers["Cache-Control"] = "private, no-store";
        handleJson(res, config.corsOrigin, () {
            auto profileId = requireProfileId(req, store);
            auto session = SessionKey(profileId, queryParam(req, "session_id"));
            sessionUses.begin(session);
            scope(exit) sessionUses.finish(session);
            return store.turnReasoningJson(
                session,
                req.params["turn_id"],
                queryParam(req, "item_id"),
            );
        });
    }

    void clientTurnMetrics(HTTPServerRequest req, HTTPServerResponse res)
    {
        clientTurnMetricsResponse(req, res, store, sessionUses, config.corsOrigin);
    }



    void advertiseClientToolClient(HTTPServerRequest req, HTTPServerResponse res)
    {
        advertiseClientToolClientResponse(req, res, store, clientTools, config.corsOrigin);
    }

    void clientToolRequests(HTTPServerRequest req, HTTPServerResponse res)
    {
        clientToolRequestsResponse(req, res, store, clientTools, config.corsOrigin);
    }

    void createClientToolRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        createClientToolRequestResponse(req, res, store, clientTools, config.corsOrigin);
    }

    void clientToolRequestDetail(HTTPServerRequest req, HTTPServerResponse res)
    {
        clientToolRequestDetailResponse(req, res, store, clientTools, config.corsOrigin);
    }

    void completeClientToolRequest(HTTPServerRequest req, HTTPServerResponse res)
    {
        completeClientToolRequestResponse(req, res, store, clientTools, config.corsOrigin);
    }

    void uploadClientToolArtifact(HTTPServerRequest req, HTTPServerResponse res)
    {
        uploadClientToolArtifactResponse(req, res, store, clientTools, config.corsOrigin);
    }

    void clientToolArtifact(HTTPServerRequest req, HTTPServerResponse res)
    {
        clientToolArtifactResponse(req, res, store, clientTools, config.corsOrigin);
    }

    void audio(HTTPServerRequest req, HTTPServerResponse res)
    {
        audioArtifactResponse(req, res, store, files, config.corsOrigin);
    }

    void generatedAudio(HTTPServerRequest req, HTTPServerResponse res)
    {
        generatedAudioArtifactResponse(req, res, store, files, config.corsOrigin);
    }

    void acceptedVoiceAudio(HTTPServerRequest req, HTTPServerResponse res)
    {
        acceptedVoiceAudioResponse(req, res, store, files, config.corsOrigin);
    }

    void acceptedVoiceCommit(HTTPServerRequest req, HTTPServerResponse res)
    {
        acceptedVoiceCommitStreamResponse(
            req, res, config, store, files, conversations, sessionUses, config.corsOrigin,
        );
    }

    void synthesizeSpeech(HTTPServerRequest req, HTTPServerResponse res)
    {
        synthesizeSpeechResponse(req, res, store, tts, config.corsOrigin);
    }

    void turnSpeechStream(HTTPServerRequest req, HTTPServerResponse res)
    {
        turnSpeechStreamResponse(req, res, store, speech, sessionUses, config.corsOrigin);
    }

    void stopTurnSpeech(HTTPServerRequest req, HTTPServerResponse res)
    {
        stopTurnSpeechResponse(req, res, store, speech, config.corsOrigin);
    }

    void audioPlaybackEvent(HTTPServerRequest req, HTTPServerResponse res)
    {
        audioPlaybackEventResponse(req, res, store, voice, config.corsOrigin);
    }

    void textTurnStream(HTTPServerRequest req, HTTPServerResponse res)
    {
        textTurnStreamResponse(req, res, store, conversations, sessionUses, config.corsOrigin);
    }

    void imageTurnStream(HTTPServerRequest req, HTTPServerResponse res)
    {
        imageTurnStreamResponse(
            req, res, config, store, conversations, sessionUses, config.corsOrigin,
        );
    }

    void stageUserImage(HTTPServerRequest req, HTTPServerResponse res)
    {
        stageUserImageResponse(req, res, config, store, config.corsOrigin);
    }

    void userImage(HTTPServerRequest req, HTTPServerResponse res)
    {
        userImageResponse(req, res, store, config.corsOrigin);
    }

    void presentationImage(HTTPServerRequest req, HTTPServerResponse res)
    {
        presentationImageResponse(req, res, store, config.corsOrigin);
    }

    void turnScreenCaptureModel(HTTPServerRequest req, HTTPServerResponse res)
    {
        turnScreenCaptureModelResponse(req, res, config, store, config.corsOrigin);
    }

    void presentationScreenCaptureModel(HTTPServerRequest req, HTTPServerResponse res)
    {
        presentationScreenCaptureModelResponse(req, res, config, store, config.corsOrigin);
    }

    void uploadedImage(HTTPServerRequest req, HTTPServerResponse res)
    {
        uploadedImageResponse(req, res, store, config.corsOrigin);
    }

    void stopTextTurn(HTTPServerRequest req, HTTPServerResponse res)
    {
        stopTextTurnResponse(req, res, store, conversations, config.corsOrigin);
    }

    void transcribeSpeechInterrupt(HTTPServerRequest req, HTTPServerResponse res)
    {
        speechInterruptTranscriptionResponse(
            req,
            res,
            config,
            store,
            profileRuntime,
            stt,
            config.corsOrigin,
        );
    }

    void liveAudioTurn(scope WebSocket socket)
    {
        voice.run(socket);
    }

    void options(HTTPServerRequest req, HTTPServerResponse res)
    {
        addCommonHeaders(res, config.corsOrigin);
        res.statusCode = HTTPStatus.noContent;
        res.writeVoidBody();
    }

    private string healthJson()
    {
        auto storage = parseJSON(store.healthJson());
        if (config.conversationPlacement == ConversationPlacement.remote) {
            return jsonObject([
                jsonBoolField("ok", boolField(storage, "ok")),
                jsonStringField("storage", stringField(storage, "storage")),
                jsonStringField("profiles_root", stringField(storage, "profiles_root")),
                jsonLongField("profiles", Json.object(storage).integer("profiles")),
                jsonStringField(
                    "deployment_composition",
                    deploymentCompositionText(config.deploymentComposition),
                ),
                jsonStringField(
                    "conversation_placement",
                    conversationPlacementText(config.conversationPlacement),
                ),
                jsonRawField("pi", remotePiStatusJson()),
            ]);
        }
        auto pi = checkPiAvailability(appPiCommand());
        return jsonObject([
            jsonBoolField("ok", boolField(storage, "ok") && pi.available),
            jsonStringField("storage", stringField(storage, "storage")),
            jsonStringField("profiles_root", stringField(storage, "profiles_root")),
            jsonLongField("profiles", Json.object(storage).integer("profiles")),
            jsonStringField(
                "deployment_composition",
                deploymentCompositionText(config.deploymentComposition),
            ),
            jsonStringField(
                "conversation_placement",
                conversationPlacementText(config.conversationPlacement),
            ),
            jsonRawField("pi", piStatusJson(pi)),
        ]);
    }

    private string remotePiStatusJson()
    {
        return jsonObject([
            jsonStringField("model", appPiModel()),
            jsonStringField("model_provider", appPiProvider()),
            jsonStringField("command", appPiCommand()),
            jsonStringField("binary", ""),
            jsonStringField("resolved_binary", ""),
            jsonStringField("check", "remote"),
            jsonStringField("detail", "Conversation executes on the configured remote authority."),
            jsonStringField("version", ""),
            jsonLongField("exit_status", 0),
            jsonBoolField("timed_out", false),
            jsonBoolField("output_truncated", false),
            jsonBoolField("available", false),
            jsonBoolField("critical", false),
        ]);
    }

    private string piStatusJson(PiAvailability pi)
    {
        return jsonObject([
            jsonStringField("model", appPiModel()),
            jsonStringField("model_provider", appPiProvider()),
            jsonStringField("command", pi.command),
            jsonStringField("binary", pi.resolvedPath.length ? pi.resolvedPath : pi.command),
            jsonStringField("resolved_binary", pi.resolvedPath),
            jsonStringField("check", "launch"),
            jsonStringField("detail", pi.detail),
            jsonStringField("version", pi.available ? pi.output : ""),
            jsonLongField("exit_status", pi.exitStatus),
            jsonBoolField("timed_out", pi.timedOut),
            jsonBoolField("output_truncated", pi.outputTruncated),
            jsonBoolField("available", pi.available),
            jsonBoolField("critical", true),
        ]);
    }

    private string appPiModel()
    {
        return piModels.defaultModel.model;
    }

    private void validateScheduledTaskDefinition(JSONValue task)
    {
        auto definition = Json.object(task, "scheduled task");
        auto target = definition.object("target");
        if (target.text("kind") != "new_session") return;
        piModels.requireExactReasoning(
            target.text("model"),
            parseReasoningMode(definition.text("reasoning_mode")),
        );
    }

    private string appPiProvider()
    {
        return piModels.defaultModel.provider;
    }

    private string appPiCommand()
    {
        auto props = indexProfileConfigProperties(appConfig.properties());
        return requiredConfigText(props, "pi.command");
    }

}

private JSONValue* field(JSONValue value, string name)
{
    if (value.type != JSONType.object) return null;
    auto object = value.objectNoRef;
    return name in object;
}

private bool boolField(JSONValue value, string name)
{
    auto item = field(value, name);
    return item !is null && item.type == JSONType.true_;
}

private string stringField(JSONValue value, string name)
{
    auto item = field(value, name);
    return item !is null && item.type == JSONType.string ? item.str : "";
}
