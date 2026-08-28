module wheatley.server.api.server;

import vibe.http.common : HTTPMethod;
import vibe.http.router : URLRouter;
import vibe.http.server :
    HTTPServerRequest,
    HTTPServerRequestDelegate,
    HTTPServerResponse,
    HTTPServerSettings,
    listenHTTP;
import vibe.http.websockets : WebSocket, handleWebSockets;
import vibe.vibe : runApplication;

import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.api.wheatley_api : WheatleyApi;
import wheatley.server.config.app_config_store : AppConfigStore;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.history.store : HistoryStore;

private enum maxRequestBytes = 64UL * 1024 * 1024;

int runApiServer(
    ServerConfig config,
    AppConfigStore appConfig,
    HistoryStore store,
    RuntimeFiles files,
    ref string[] runtimeArgs,
)
{
    auto router = new URLRouter;
    auto api = new WheatleyApi(config, appConfig, store, files);
    scope(exit) api.shutdown();
    registerApiRoutes(router, api);

    auto settings = new HTTPServerSettings;
    settings.bindAddresses = [config.host];
    settings.port = config.port;
    settings.maxRequestSize = maxRequestBytes;

    // Complete durable recovery and migration before accepting requests. A
    // startup failure must never expose a briefly available, half-started API.
    api.start();
    listenHTTP(settings, router);
    return runApplication(&runtimeArgs);
}

private void registerApiRoutes(URLRouter router, WheatleyApi api)
{
    router.get("/api/health", route((req, res) { api.health(req, res); }));
    router.get("/api/status", route((req, res) { api.status(req, res); }));
    router.get("/api/models", route((req, res) { api.models(req, res); }));
    router.get("/api/listening-chimes/:kind", route((req, res) { api.listeningChime(req, res); }));
    router.match(
        HTTPMethod.HEAD,
        "/api/listening-chimes/:kind",
        route((req, res) { api.listeningChime(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/thinking-music",
        route((req, res) { api.thinkingMusicNext(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/thinking-music/:code/:revision",
        route((req, res) { api.thinkingMusicAsset(req, res); }),
    );
    router.match(
        HTTPMethod.HEAD,
        "/api/profiles/:profile_id/thinking-music/:code/:revision",
        route((req, res) { api.thinkingMusicAsset(req, res); }),
    );
    router.get("/api/profiles", route((_, res) { api.profiles(res); }));
    router.get("/api/translations/:language", route((req, res) { api.translations(req, res); }));
    router.get(
        "/api/config/clients/:client_id",
        route((req, res) { api.clientConfig(req, res); }),
    );
    router.match(
        HTTPMethod.PUT,
        "/api/config/clients/:client_id",
        route((req, res) { api.updateClientConfig(req, res); }),
    );
    router.get(
        "/api/image-generation/health",
        route((req, res) { api.imageGenerationHealth(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/image-generation",
        route((req, res) { api.generateImage(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/web-images",
        route((req, res) { api.persistWebImage(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/memory/remember",
        route((req, res) { api.appendProfileMemory(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/scheduled-tasks",
        route((req, res) { api.scheduledTaskList(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/scheduled-tasks/presence",
        route((req, res) { api.reportScheduledTaskPresence(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/scheduled-tasks",
        route((req, res) { api.createScheduledTask(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/scheduled-tasks/:task_id",
        route((req, res) { api.scheduledTask(req, res); }),
    );
    router.match(
        HTTPMethod.PUT,
        "/api/profiles/:profile_id/scheduled-tasks/:task_id",
        route((req, res) { api.updateScheduledTask(req, res); }),
    );
    router.match(
        HTTPMethod.PUT,
        "/api/profiles/:profile_id/scheduled-tasks/:task_id/enabled",
        route((req, res) { api.setScheduledTaskEnabled(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/scheduled-tasks/:task_id/run-now",
        route((req, res) { api.runScheduledTaskNow(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/scheduled-tasks/current/next",
        route((req, res) { api.scheduleCurrentTaskNext(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/scheduled-tasks/current/complete",
        route((req, res) { api.completeCurrentScheduledTask(req, res); }),
    );
    router.match(
        HTTPMethod.DELETE,
        "/api/profiles/:profile_id/scheduled-tasks/:task_id",
        route((req, res) { api.deleteScheduledTask(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/instructions",
        route((req, res) { api.instructionDocuments(req, res); }),
    );
    router.match(
        HTTPMethod.PUT,
        "/api/profiles/:profile_id/instructions",
        route((req, res) { api.saveInstructionDocuments(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/codex/message",
        route((req, res) { api.codexMessage(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/codex/status",
        route((req, res) { api.codexStatus(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/codex/events",
        route((req, res) { api.codexEvents(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/presentation",
        route((req, res) { api.sessionPresentation(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/generated-images",
        route((req, res) { api.generatedImages(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/compaction",
        route((req, res) { api.compactSession(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/branches",
        route((req, res) { api.branchSession(req, res); }),
    );
    router.get("/api/profiles/:profile_id/startup", route((req, res) { api.profileStartup(req, res); }));
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/startup/stream",
        route((req, res) { api.profileStartupStream(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/tts",
        route((req, res) { api.synthesizeSpeech(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/turns/:turn_id/speech/stream",
        route((req, res) { api.turnSpeechStream(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/speech/:speech_id/stop",
        route((req, res) { api.stopTurnSpeech(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/audio/playback-events",
        route((req, res) { api.audioPlaybackEvent(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/turns/text/stream",
        route((req, res) { api.textTurnStream(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/turns/image/stream",
        route((req, res) { api.imageTurnStream(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/user-images/:submission_id",
        route((req, res) { api.stageUserImage(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/turns/:turn_id/images/:filename",
        route((req, res) { api.userImage(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/turns/:turn_id/images/:filename/model",
        route((req, res) { api.turnScreenCaptureModel(req, res); }),
    );
    router.get(
        "/chat/:profile_id/:session_id/:image_kind/:image_index",
        route((req, res) { api.presentationImage(req, res); }),
    );
    router.match(
        HTTPMethod.HEAD,
        "/chat/:profile_id/:session_id/:image_kind/:image_index",
        route((req, res) { api.presentationImage(req, res); }),
    );
    router.get(
        "/chat/:profile_id/:session_id/screenshot/:image_index/model",
        route((req, res) { api.presentationScreenCaptureModel(req, res); }),
    );
    router.get(
        "/chat/:profile_id/:session_id/image/:image_index/:filename",
        route((req, res) { api.uploadedImage(req, res); }),
    );
    router.match(
        HTTPMethod.HEAD,
        "/chat/:profile_id/:session_id/image/:image_index/:filename",
        route((req, res) { api.uploadedImage(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/turns/text/:turn_id/stop",
        route((req, res) { api.stopTextTurn(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/speech-interrupt/transcribe",
        route((req, res) { api.transcribeSpeechInterrupt(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/accepted-voice/:submission_id/audio",
        route((req, res) { api.acceptedVoiceAudio(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/accepted-voice/:submission_id/commit/stream",
        route((req, res) { api.acceptedVoiceCommit(req, res); }),
    );
    router.get("/api/profiles/:profile_id/turns/audio/live", handleWebSockets(delegate(scope WebSocket socket) {
        api.liveAudioTurn(socket);
    }));
    router.get(
        "/api/profiles/:profile_id/session-turns/stream",
        route((req, res) { api.sessionTurnEvents(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/queue",
        route((req, res) { api.sessionQueue(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/queue/reserve",
        route((req, res) { api.reserveSessionQueueItem(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/queue/compact",
        route((req, res) { api.compactSessionQueue(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/queue/:item_id/preparation/touch",
        route((req, res) { api.touchSessionQueuePreparation(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/queue/:item_id/preparation/fail",
        route((req, res) { api.failSessionQueuePreparation(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/queue/:item_id/cancel",
        route((req, res) { api.cancelSessionQueueItem(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/session-turns",
        route((req, res) { api.sessionTurns(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/sync/turns",
        route((req, res) { api.importCompletedTurn(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/sync/latest-session",
        route((req, res) { api.latestSessionSyncManifest(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/sync/profile-replica",
        route((req, res) { api.profileReplicaSync(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/sync/files",
        route((req, res) { api.latestSessionSyncFile(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/sync/remote-turn/session",
        route((req, res) { api.remoteTurnSessionHandoff(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/sync/remote-turn/manifest",
        route((req, res) { api.remoteTurnManifest(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/sync/remote-turn/files",
        route((req, res) { api.remoteTurnFile(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/sync/remote-turn/accepted-voice",
        route((req, res) { api.acceptedVoiceSync(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/recent-sessions",
        route((req, res) { api.recentSessions(req, res); }),
    );
    router.match(
        HTTPMethod.DELETE,
        "/api/profiles/:profile_id/session",
        route((req, res) { api.deleteSession(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/turns/:turn_id/tools/:call_index",
        route((req, res) { api.toolDetail(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/turns/:turn_id/llm-requests",
        route((req, res) { api.captureLlmRequest(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/turns/:turn_id/reasoning",
        route((req, res) { api.reasoningDetail(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/client-tools/clients",
        route((req, res) { api.advertiseClientToolClient(req, res); }),
    );
    router.get("/api/profiles/:profile_id/client-tools/requests", route((req, res) {
        api.clientToolRequests(req, res);
    }));
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/client-tools/requests",
        route((req, res) { api.createClientToolRequest(req, res); }),
    );
    router.get("/api/profiles/:profile_id/client-tools/requests/:request_id", route((req, res) {
        api.clientToolRequestDetail(req, res);
    }));
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/client-tools/requests/:request_id/artifacts",
        route((req, res) { api.uploadClientToolArtifact(req, res); }),
    );
    router.get(
        "/api/profiles/:profile_id/client-tools/requests/:request_id/artifacts/:artifact_id",
        route((req, res) { api.clientToolArtifact(req, res); }),
    );
    router.match(
        HTTPMethod.HEAD,
        "/api/profiles/:profile_id/client-tools/requests/:request_id/artifacts/:artifact_id",
        route((req, res) { api.clientToolArtifact(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/client-tools/requests/:request_id/result",
        route((req, res) { api.completeClientToolRequest(req, res); }),
    );
    router.match(
        HTTPMethod.POST,
        "/api/profiles/:profile_id/turns/:turn_id/client-metrics",
        route((req, res) { api.clientTurnMetrics(req, res); }),
    );
    router.get("/api/audio/:artifact_id", route((req, res) { api.audio(req, res); }));
    router.match(HTTPMethod.HEAD, "/api/audio/:artifact_id", route((req, res) { api.audio(req, res); }));
    router.get(
        "/api/profiles/:profile_id/generated-audio/:artifact_id",
        route((req, res) { api.generatedAudio(req, res); }),
    );
    router.match(
        HTTPMethod.HEAD,
        "/api/profiles/:profile_id/generated-audio/:artifact_id",
        route((req, res) { api.generatedAudio(req, res); }),
    );
    router.match(HTTPMethod.OPTIONS, "*", route((req, res) { api.options(req, res); }));
}

private HTTPServerRequestDelegate route(void delegate(HTTPServerRequest req, HTTPServerResponse res) handler)
{
    return cast(HTTPServerRequestDelegate) handler;
}
