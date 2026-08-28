module wheatley.server.sync.service;

import core.time : dur;
import std.algorithm : sort;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.uuid : randomUUID;

import vibe.core.core : Timer, setTimer;
import vibe.core.log : logWarn;
import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.api.session_sync : SessionSyncManifest, SessionSyncManifestFile;
import wheatley.common.json.read : Json;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.history.store.sync : CompletedTurnImport;
import wheatley.server.history.store.sync_export : SyncCompletedTurnExport;
import wheatley.server.history.store.sync_paths : parseSyncSessionPath, parseSyncTurnPath;
import wheatley.server.sync.http_client : ProfileSyncHttpClient;
import wheatley.server.sync.outbox : ProfileSyncOutbox;
import wheatley.server.sync.profile_replica : ProfileReplicaStore;
import wheatley.server.sync.remote_turn_gate : RemoteTurnSyncGate;
import wheatley.server.sync.retention : pruneAcknowledgedReplicaSessions;
import wheatley.server.voice.accepted_pending : hasPendingAcceptedVoiceArtifacts;

final class ProfileSyncService
{
    private HistoryStore store;
    private ProfileSyncOutbox outbox;
    private ProfileReplicaStore replicas;
    private ProfileSyncHttpClient remote;
    private RemoteTurnSyncGate remoteTurns;
    private TaskMutex mutex;
    private int intervalSeconds;
    private Timer timer;

    this(
        HistoryStore store,
        RuntimeFiles files,
        string outboxRoot,
        string upstreamApiBase,
        int intervalSeconds,
    )
    {
        enforce(store !is null, "Profile sync history store is required");
        enforce(files !is null, "Profile sync runtime files are required");
        enforce(upstreamApiBase.length, "Profile sync upstream API is required");
        enforce(intervalSeconds > 0, "Profile sync interval must be positive");
        this.store = store;
        this.store.enableSyncedProfileReplicaDocuments();
        this.outbox = new ProfileSyncOutbox(outboxRoot);
        this.replicas = new ProfileReplicaStore(buildPath(dirName(outboxRoot), "replica"));
        this.remote = new ProfileSyncHttpClient(upstreamApiBase);
        this.mutex = new TaskMutex;
        this.remoteTurns = new RemoteTurnSyncGate(
            store,
            outbox,
            remote,
            (session, excluded) => hasPendingAcceptedVoiceArtifacts(
                files,
                session,
                excluded,
            ),
            mutex,
        );
        this.intervalSeconds = intervalSeconds;
    }

    void start()
    {
        if (timer) return;
        timer = setTimer(dur!"seconds"(intervalSeconds), () {
            syncSafely();
        }, true);
    }

    void stop() nothrow
    {
        if (timer) timer.stop();
    }

    RemoteTurnSyncGate remoteTurnGate()
    {
        return remoteTurns;
    }

    void syncNow()
    {
        foreach (profileId; store.syncProfileIds()) {
            try {
                syncProfile(profileId);
            } catch (Exception error) {
                logWarn("Profile %s synchronization will retry: %s", profileId, error.msg);
            }
        }
    }

    private void syncSafely() nothrow
    {
        try {
            syncNow();
        } catch (Exception error) {
            logWarn("Profile synchronization will retry: %s", error.msg);
        }
    }

    private void syncProfile(string profileId)
    {
        auto guard = scopedMutexLock(mutex);
        foreach (turn; store.exportReadyTurns(profileId)) uploadIfNeeded(turn);
        auto replica = remote.profileReplica(profileId);
        replicas.acknowledge(replica);
        if (canApplyReplicaDocuments(profileId))
            store.applySyncedProfileDocuments(replica);
        pullLatestSession(profileId);
        pruneAcknowledgedReplicaSessions(store, outbox, profileId);
    }

    private bool canApplyReplicaDocuments(string profileId)
    {
        if (outbox.hasPendingProfileWork(profileId)) return false;
        foreach (turn; store.exportReadyTurns(profileId)) {
            if (!outbox.acknowledged(profileId, turn.sessionPath, turn.turnPath)) return false;
            if (turn.piSessionJsonlPath.length && !outbox.piAcknowledged(profileId, turn.sessionPath))
                return false;
        }
        return true;
    }

    private void uploadIfNeeded(SyncCompletedTurnExport turn)
    {
        if (outbox.acknowledged(turn.profileId, turn.sessionPath, turn.turnPath)) return;
        outbox.markPending(turn.profileId, turn.sessionPath, turn.turnPath);
        auto includePi = turn.piSessionJsonlPath.length &&
            !outbox.piAcknowledged(turn.profileId, turn.sessionPath);
        if (includePi) outbox.markPiPending(turn.profileId, turn.sessionPath);
        remote.uploadCompletedTurn(turn, includePi);
        outbox.acknowledge(turn.profileId, turn.sessionPath, turn.turnPath);
        if (includePi) outbox.acknowledgePi(turn.profileId, turn.sessionPath);
    }

    private void pullLatestSession(string profileId)
    {
        auto manifest = remote.latestSession(profileId);
        parseSyncSessionPath(manifest.sessionPath);
        auto missingTurns = missingManifestTurns(store, profileId, manifest);
        if (!missingTurns.length) return;
        auto stageRoot = buildPath(
            tempDir(),
            "wheatley-session-sync-" ~ randomUUID().toString(),
        );
        scope(exit) if (exists(stageRoot)) rmdirRecurse(stageRoot);
        mkdirRecurse(stageRoot);
        auto downloaded = downloadManifest(
            remote,
            profileId,
            manifest,
            missingTurns,
            stageRoot,
        );
        importDownloadedSession(store, profileId, manifest.sessionPath, downloaded);
    }

}

private struct DownloadedTurn
{
    string turnJsonPath;
    string turnMarkdownPath;
    string userOpusPath;
    string errorsJsonPath;
    string toolsJsonPath;
    string llmRequestsJsonPath;
}

private struct DownloadedSession
{
    string sessionJsonPath;
    string piSessionJsonlPath;
    DownloadedTurn[string] turns;
}

private DownloadedSession downloadManifest(
    ProfileSyncHttpClient remote,
    string profileId,
    SessionSyncManifest manifest,
    string[] wantedTurnPaths,
    string stageRoot,
)
{
    DownloadedSession result;
    bool[string] wanted;
    foreach (turnPath; wantedTurnPaths) wanted[turnPath] = true;
    foreach (file; manifest.files) {
        if (!file.turnPath.length) {
            if (file.name != "session.json" && file.name != "pi_session.jsonl") continue;
            auto target = buildPath(stageRoot, file.name);
            remote.downloadSessionFile(profileId, manifest.sessionPath, file, target);
            if (file.name == "session.json") result.sessionJsonPath = target;
            else result.piSessionJsonlPath = target;
            continue;
        }

        parseSyncTurnPath(file.turnPath);
        enforce(isTurnFile(file.name), "Unexpected synchronized turn file");
        if (!(file.turnPath in wanted)) continue;
        auto target = buildPath(stageRoot, "turns", file.turnPath, file.name);
        remote.downloadSessionFile(profileId, manifest.sessionPath, file, target);
        auto turn = result.turns.get(file.turnPath, DownloadedTurn());
        setTurnFile(turn, file.name, target);
        result.turns[file.turnPath] = turn;
    }
    enforce(result.sessionJsonPath.length, "Synchronized session.json is missing");
    return result;
}

private string[] missingManifestTurns(
    HistoryStore store,
    string profileId,
    SessionSyncManifest manifest,
)
{
    string[] result;
    bool[string] seen;
    foreach (file; manifest.files) {
        if (!file.turnPath.length) continue;
        parseSyncTurnPath(file.turnPath);
        enforce(isTurnFile(file.name), "Unexpected synchronized turn file");
        if (file.turnPath in seen) continue;
        seen[file.turnPath] = true;
        if (!store.hasSyncTurn(profileId, manifest.sessionPath, file.turnPath))
            result ~= file.turnPath;
    }
    sort(result);
    return result;
}

private bool isTurnFile(string name)
{
    return name == "turn.json" || name == "turn.md" || name == "user.opus" ||
        name == "errors.json" || name == "tools.json" || name == "llm-requests.json";
}

private void setTurnFile(ref DownloadedTurn turn, string name, string path)
{
    if (name == "turn.json") turn.turnJsonPath = path;
    else if (name == "turn.md") turn.turnMarkdownPath = path;
    else if (name == "user.opus") turn.userOpusPath = path;
    else if (name == "errors.json") turn.errorsJsonPath = path;
    else if (name == "tools.json") turn.toolsJsonPath = path;
    else if (name == "llm-requests.json") turn.llmRequestsJsonPath = path;
}

private void importDownloadedSession(
    HistoryStore store,
    string profileId,
    string sessionPath,
    DownloadedSession downloaded,
)
{
    auto turnPaths = downloaded.turns.keys;
    sort(turnPaths);
    foreach (index, turnPath; turnPaths) {
        auto turn = downloaded.turns[turnPath];
        enforce(turn.turnJsonPath.length, "Synchronized turn.json is missing");
        enforce(turn.turnMarkdownPath.length, "Synchronized turn.md is missing");
        auto metadata = Json.object(parseJSON(readText(turn.turnJsonPath)));
        auto userAudioRequired = metadata.boolean("user_audio_required");
        store.importCompletedTurn(CompletedTurnImport(
            profileId,
            sessionPath,
            turnPath,
            downloaded.sessionJsonPath,
            turn.turnJsonPath,
            turn.turnMarkdownPath,
            index == 0 ? downloaded.piSessionJsonlPath : "",
            turn.userOpusPath,
            turn.errorsJsonPath,
            turn.toolsJsonPath,
            turn.llmRequestsJsonPath,
            userAudioRequired,
        ));
    }
}

unittest
{
    import std.file : write;
    import wheatley.server.config.app_config_store : AppConfigStore;
    import wheatley.server.history.store.json : writeTextFile;
    import wheatley.server.history.store.markdown : turnMarkdown;

    auto root = buildPath(tempDir(), "wheatley-sync-service-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(
        profilesRoot,
        new AppConfigStore(configPath),
        root,
    );

    auto staged = buildPath(root, "downloaded");
    auto sessionJson = buildPath(staged, "session.json");
    auto piSession = buildPath(staged, "pi_session.jsonl");
    writeTextFile(
        sessionJson,
        `{"client":"offline","language":"en","model":"","reasoning_mode":"off"}`,
    );
    writeTextFile(piSession, "pi\n");

    auto textRoot = buildPath(staged, "turns", "10_00_01_000001");
    auto textJson = buildPath(textRoot, "turn.json");
    auto textMarkdown = buildPath(textRoot, "turn.md");
    writeTextFile(textJson,
        `{"source":"offline","status":"completed","completed_at":"2026-08-05T10:00:01.000001Z","user_audio_required":false,"reasoning_mode":"off"}`);
    writeTextFile(textMarkdown, turnMarkdown("text prompt", "text answer"));

    auto voiceRoot = buildPath(staged, "turns", "10_00_02_000001");
    auto voiceJson = buildPath(voiceRoot, "turn.json");
    auto voiceMarkdown = buildPath(voiceRoot, "turn.md");
    auto voiceAudio = buildPath(voiceRoot, "user.opus");
    writeTextFile(voiceJson,
        `{"source":"offline","status":"completed","completed_at":"2026-08-05T10:00:02.000001Z","user_audio_required":true,"reasoning_mode":"off"}`);
    writeTextFile(voiceMarkdown, turnMarkdown("voice prompt", "voice answer"));
    write(voiceAudio, cast(ubyte[]) [1, 2, 3]);

    DownloadedSession downloaded;
    downloaded.sessionJsonPath = sessionJson;
    downloaded.piSessionJsonlPath = piSession;
    downloaded.turns["10_00_01_000001"] = DownloadedTurn(textJson, textMarkdown);
    downloaded.turns["10_00_02_000001"] = DownloadedTurn(
        voiceJson,
        voiceMarkdown,
        voiceAudio,
    );
    importDownloadedSession(
        store,
        "tester",
        "2026/08/05/10_00_00",
        downloaded,
    );

    auto exported = store.exportReadyTurns("tester");
    assert(exported.length == 2);
    assert(exported[0].turnPath == "10_00_01_000001");
    assert(exported[1].turnPath == "10_00_02_000001");
    assert(exported[1].userAudioRequired);
    assert(exists(exported[1].userOpusPath));

    auto manifest = SessionSyncManifest(
        "2026/08/05/10_00_00",
        [
            SessionSyncManifestFile("10_00_01_000001", "turn.json"),
            SessionSyncManifestFile("10_00_02_000001", "user.opus"),
        ],
    );
    assert(!missingManifestTurns(store, "tester", manifest).length);
    manifest.files ~= SessionSyncManifestFile("10_00_03_000001", "turn.json");
    assert(missingManifestTurns(store, "tester", manifest) == ["10_00_03_000001"]);
}
