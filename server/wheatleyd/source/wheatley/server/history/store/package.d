module wheatley.server.history.store;

import core.time : MonoTime, dur;

import std.algorithm : any, canFind, filter, sort, startsWith;
import std.array : Appender, appender, array;
import std.datetime.systime : Clock, SysTime;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.conv : to;
import std.exception : assertThrown, enforce;
import std.file :
    SpanMode,
    copy,
    dirEntries,
    exists,
    getSize,
    mkdirRecurse,
    read,
    readText,
    remove,
    rename,
    rmdir,
    rmdirRecurse,
    tempDir,
    write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path :
    absolutePath,
    baseName,
    buildNormalizedPath,
    buildPath,
    dirName,
    dirSeparator,
    isAbsolute;
import std.string : endsWith, indexOf, replace, splitLines, strip;
import std.stdio : File;
import std.uuid : randomUUID;
import std.uri : encodeComponent;

import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonObjectRaw,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.reasoning :
    ReasoningMode,
    parseReasoningMode,
    reasoningModeText;
import wheatley.common.api.conversation_events :
    conversationEventFromJson,
    conversationEventJson;
import wheatley.common.conversation.events :
    ConversationEvent,
    ConversationEventKind,
    conversationEventKindText;
import wheatley.common.runtime.files : moveFileReplacing;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.common.runtime.temp_files : removeQuietly;
import wheatley.server.config.app_config_store : AppConfigStore;
import wheatley.server.history.files : FilePayload;
import wheatley.server.history.documents.profile_auto_memory_types :
    SessionAutoMemoryBacklog,
    SessionAutoMemoryFailure,
    SessionAutoMemorySave,
    SessionAutoMemoryTurn;
import wheatley.server.history.profiles.prompt_context_types : ProfilePromptDocuments;
import wheatley.server.history.rows.artifact_ref : ArtifactRef;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.history.rows.image_artifact_record : UserImageArtifactRecord;
import wheatley.server.history.rows.text_turn_record : TextTurnRecord;
import wheatley.server.history.store.json;
import wheatley.server.history.store.llm_requests;
import wheatley.server.history.store.locations;
import wheatley.server.history.store.markdown;
import wheatley.server.history.store.metrics;
import wheatley.server.history.store.model_input;
import wheatley.server.history.store.paths;
import wheatley.server.history.store.pi_session;
import wheatley.server.history.store.pi_tool_detail;
import wheatley.server.history.store.profile_documents;
import wheatley.server.history.store.reader;
import wheatley.server.history.store.recent_sessions : RecentSessionIndex;
import wheatley.server.history.store.session_branch : materializeSessionBranch;
import wheatley.server.history.store.sync :
    CompletedTurnImport,
    ImportedCompletedTurn,
    commitCompletedTurn,
    commitSyncedSession,
    syncTurnExists;
import wheatley.server.history.store.sync_export :
    SyncCompletedTurnExport,
    SyncSessionSnapshot,
    SyncSnapshotFile,
    loadExportReadyTurns,
    loadLatestSessionSnapshot,
    loadSessionTurnSnapshot,
    loadSyncSessionPaths,
    loadSyncProfileIds,
    resolveLatestSnapshotFile,
    resolveSessionTurnSnapshotFileImpl = resolveSessionTurnSnapshotFile;
import wheatley.server.history.store.sync_paths : parseSyncSessionPath;
import wheatley.server.history.store.sync_export :
    syncSessionFullyExportable = syncSessionIsFullyExportable;
import wheatley.server.profile.replica_snapshot : profileReplicaSnapshot;
import wheatley.server.presentation.store : appendPresentation, withSessionStorageLock;
import wheatley.server.queue.session_queue : SessionQueueStore;
import wheatley.common.api.profile_replica : ProfileReplicaSnapshot;
import wheatley.common.api.remote_turn_sync : RemoteTurnSessionHandoff;
import wheatley.server.history.store.tool_json;
import wheatley.server.history.store.types;
import wheatley.server.history.store.views;
import wheatley.server.instructions.documents : InstructionDocuments;
import wheatley.server.profiles.config_properties :
    ProfileConfigIndex,
    ProfileConfigProperty,
    indexProfileConfigProperties;
import wheatley.server.tools.types : ExecutedTool, ToolCall, ToolResult;
import wheatley.common.api.generated_image :
    GeneratedImageArtifact,
    assignMissingGeneratedImageIds,
    generatedImageArtifactFromJson,
    generatedImageArtifactJson;
import wheatley.common.api.web_image :
    WebImageArtifact,
    webImageArtifactFromJson;

private struct SessionActivity
{
    bool processing;
    bool scheduledTurn;
    bool toolUse;
    bool generatedImage;
    bool webSearch;
    bool compaction;
    bool screenCapture;
}

private struct ConversationEventTail
{
    ulong sequence;
    ConversationEventKind kind;
}

class HistoryStore
{
    private string profilesRoot;
    private string resourcesRoot_;
    private AppConfigStore appConfig;
    private HistoryStoreLocations locations;
    private HistoryStoreReader reader;
    private HistoryProfileDocuments profileDocuments;
    private InstructionDocuments instructionDocuments;
    private HistoryStoreViews views;
    private RecentSessionIndex recentSessions;
    private SessionMetadata[string] sessionMetadataByRoot;
    private string[string] sessionRootByKey;
    private PiSessionMetadata[string] piSessionByRoot;
    private string[string] turnRootById;
    private SessionActivity[string] sessionActivityByRoot;
    private ConversationEventTail[string] conversationEventTailByTurnRoot;
    private TaskMutex sessionActivityMutex;
    private TaskMutex conversationEventMutex;
    private TaskMutex documentMutexRegistry;
    private TaskMutex[string] profileDocumentMutexes;
    private TaskMutex autoMemoryMutexRegistry;
    private TaskMutex[string] profileAutoMemoryMutexes;
    private TaskMutex syncMutexRegistry;
    private TaskMutex[string] profileSyncMutexes;

    this(
        string profilesRoot,
        AppConfigStore appConfig,
        string displayRoot = "",
        string resourcesRoot = "",
    )
    {
        enforce(appConfig !is null, "App config store is required");
        auto rootForDisplay = displayRoot.length ? displayRoot : profilesRoot;
        this.locations = new HistoryStoreLocations(profilesRoot, rootForDisplay);
        this.profilesRoot = locations.profilesRoot;
        this.resourcesRoot_ = resourcesRoot;
        this.appConfig = appConfig;
        this.reader = new HistoryStoreReader(locations);
        this.profileDocuments = new HistoryProfileDocuments(locations);
        this.instructionDocuments = new InstructionDocuments(
            this.profilesRoot,
            buildPath(dirName(this.profilesRoot), "prompts"),
        );
        this.views = new HistoryStoreViews(locations, reader, resourcesRoot_);
        this.recentSessions = new RecentSessionIndex(locations, reader);
        this.sessionActivityMutex = new TaskMutex;
        this.conversationEventMutex = new TaskMutex;
        this.documentMutexRegistry = new TaskMutex;
        this.autoMemoryMutexRegistry = new TaskMutex;
        this.syncMutexRegistry = new TaskMutex;
    }

    string resourcesRoot() const
    {
        return resourcesRoot_;
    }

    string healthJson()
    {
        return jsonObject([
            jsonBoolField("ok", true),
            jsonStringField("storage", "filesystem"),
            jsonStringField("profiles_root", locations.displayRelative(profilesRoot)),
            jsonLongField("profiles", cast(long) reader.listProfiles().length),
        ]);
    }

    string statusJson()
    {
        return jsonObject([
            jsonStringField("status", "ok"),
            jsonStringField("storage", "filesystem"),
            jsonStringField("profiles_root", locations.displayRelative(profilesRoot)),
        ]);
    }

    bool profileExists(string profileId)
    {
        return reader.profileExists(profileId);
    }

    string profileFilesRoot(string profileId)
    {
        auto root = buildPath(locations.profileRoot(profileId), "files");
        mkdirRecurse(root);
        return root;
    }

    string profileWorkspaceRoot(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return instructionDocuments.workspaceRoot(profileId);
    }

    string sessionFolder(SessionKey session)
    {
        return baseName(sessionRoot(session));
    }

    string sessionDate(SessionKey session)
    {
        return isoDate(sessionStartFromPath(sessionRoot(session)));
    }

    string sessionRuntimeRoot(SessionKey session)
    {
        return sessionRoot(session);
    }

    SessionQueueStore sessionQueue(SessionKey session)
    {
        return new SessionQueueStore(sessionRoot(session), session.sessionId);
    }

    /** Ordered turns visible to the explicit queue migrator. Runtime callers
        should continue using the narrower turn lookup methods. */
    StoredTurn[] sessionTurns(SessionKey session)
    {
        return orderedSessionTurns(session);
    }

    SessionKey[] sessionKeys()
    {
        SessionKey[] result;
        foreach (profileId; reader.listProfiles()) {
            foreach (session; recentSessions.load(profileId)) {
                result ~= SessionKey(profileId, session.id);
            }
        }
        return result;
    }

    SessionKey startProfileSession(
        string profileId,
        string startedAt,
        string mode,
        string language,
        ReasoningMode reasoningMode = ReasoningMode.off,
        string model = "",
    )
    {
        enforce(profileExists(profileId), "Profile not found");
        auto root = createSessionRoot(profileId, startedAt.length ? startedAt : nowIso());
        writeSessionJson(root, mode, language, reasoningModeText(reasoningMode), model);
        auto session = SessionKey(profileId, locations.sessionIdFromSessionRoot(profileId, root));
        sessionRootByKey[session.value] = root;
        recentSessions.add(profileId, root, language);
        return session;
    }

    void markScheduledSessionOrigin(SessionKey session, string taskId, string occurrenceId)
    {
        requireSession(session);
        auto root = sessionRoot(session);
        withSessionStorageLock(root, {
            auto path = buildPath(root, "session.json");
            auto payload = parseJSON(readText(path));
            payload.object["scheduled_task"] = parseJSON(jsonObject([
                jsonStringField("task_id", taskId),
                jsonStringField("occurrence_id", occurrenceId),
            ]));
            payload.object["automatic_session_unseen"] = JSONValue(true);
            writeJsonFileAtomic(path, payload.toString());
        });
    }

    /** Existing sessions retain an unread turn marker; a newly-created
        automatic session instead uses its origin-level unread marker. */
    void markScheduledTurnUnseen(SessionKey session, string turnId)
    {
        requireSession(session);
        auto root = sessionRoot(session);
        withSessionStorageLock(root, {
            auto path = buildPath(root, "session.json");
            auto payload = parseJSON(readText(path));
            auto automatic = "automatic_session_unseen" in payload.object;
            if (automatic !is null && automatic.toString() == "true") return;
            JSONValue[] ids;
            if (auto existing = "unseen_scheduled_turn_ids" in payload.object) {
                if (existing.type == JSONType.array)
                    ids = payload.object["unseen_scheduled_turn_ids"].array.dup;
            }
            foreach (id; ids) if (id.str == turnId) return;
            ids ~= JSONValue(turnId);
            payload.object["unseen_scheduled_turn_ids"] = JSONValue(ids);
            writeJsonFileAtomic(path, payload.toString());
        });
    }

    void markScheduledSessionSeen(SessionKey session)
    {
        requireSession(session);
        auto root = sessionRoot(session);
        withSessionStorageLock(root, {
            auto path = buildPath(root, "session.json");
            auto payload = parseJSON(readText(path));
            bool changed;
            if ("automatic_session_unseen" in payload.object) {
                payload.object.remove("automatic_session_unseen");
                changed = true;
            }
            if ("unseen_scheduled_turn_ids" in payload.object) {
                payload.object.remove("unseen_scheduled_turn_ids");
                changed = true;
            }
            if (changed) writeJsonFileAtomic(path, payload.toString());
        });
    }

    bool canResumeLastProfileSession(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return resumableLastSessionRoot(profileId).length > 0;
    }

    string lastSessionLanguage(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto sessionRoot = resumableLastSessionRoot(profileId);
        return sessionRoot.length ? reader.loadSessionMetadata(sessionRoot).language : "";
    }

    string lastSessionId(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto root = resumableLastSessionRoot(profileId);
        return root.length ? locations.sessionIdFromSessionRoot(profileId, root) : "";
    }

    SessionKey resumeLastProfileSession(string profileId, string mode)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto root = resumableLastSessionRoot(profileId);
        if (!root.length) return SessionKey.init;
        writeSessionJson(root, mode);
        auto session = SessionKey(profileId, locations.sessionIdFromSessionRoot(profileId, root));
        sessionRootByKey[session.value] = root;
        return session;
    }

    SessionKey resumeProfileSession(string profileId, string sessionId, string mode)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto recent = recentSessions.get(profileId, sessionId);
        enforce(exists(buildPath(recent.root, "session.json")), "Session not found");
        writeSessionJson(recent.root, mode);
        auto session = SessionKey(profileId, recent.id);
        sessionRootByKey[session.value] = recent.root;
        return session;
    }

    SessionKey branchProfileSession(
        string profileId,
        string sourceSessionId,
        string sourceTurnId,
        string kind,
        string itemId,
    )
    {
        enforce(profileExists(profileId), "Profile not found");
        auto source = SessionKey(profileId, sourceSessionId);
        auto sourceRoot = sessionRoot(source);
        auto selected = findTurn(source, sourceTurnId);
        enforce(selected.id.length, "Chat branch turn not found");

        auto createdAt = nowIso();
        auto targetRoot = createSessionRoot(profileId, createdAt);
        scope(failure) if (exists(targetRoot)) rmdirRecurse(targetRoot);
        auto target = SessionKey(
            profileId,
            locations.sessionIdFromSessionRoot(profileId, targetRoot),
        );
        auto copied = materializeSessionBranch(
            locations,
            reader,
            profileId,
            sourceSessionId,
            target.sessionId,
            sourceRoot,
            targetRoot,
            selected,
            kind,
            itemId,
            "wheatley-branch-" ~ randomUUID().toString(),
            createdAt,
        );

        auto metadata = loadSessionMetadata(sourceRoot);
        sessionMetadataByRoot[targetRoot] = metadata;
        writeJsonFile(buildPath(targetRoot, "session.json"), jsonObject([
            jsonStringField("started_at", createdAt),
            jsonStringField("client", metadata.clientMode),
            jsonStringField("language", metadata.language),
            jsonStringField("model", metadata.model),
            jsonStringField("reasoning_mode", reasoningModeText(metadata.reasoningMode)),
            jsonRawField("codex", "null"),
            jsonRawField("branch", jsonObject([
                jsonStringField("source_session_id", sourceSessionId),
                jsonStringField("source_turn_id", sourceTurnId),
                jsonStringField("kind", kind),
                jsonStringField("item_id", itemId),
            ])),
        ]));
        sessionRootByKey[target.value] = targetRoot;
        recentSessions.add(profileId, targetRoot, metadata.language);
        recentSessions.setInitialUserText(profileId, targetRoot, copied.initialUserText);
        return target;
    }

    void requireResumableSession(SessionKey session)
    {
        recentSessions.get(session.profileId, session.sessionId);
    }

    string requireSession(SessionKey session)
    {
        return sessionRoot(session);
    }

    string recentSessionsJson(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto output = appender!string;
        output.put("[");
        foreach (index, session; recentSessions.load(profileId)) {
            if (index) output.put(",");
            auto activity = sessionActivity(session.root);
            auto unseenScheduledTurns = sessionUnseenScheduledCount(session.root);
            output.put(jsonObject([
                jsonStringField("session_id", session.id),
                jsonStringField("started_at", session.startedAt),
                jsonStringField("language", session.language),
                jsonStringField("initial_user_text", session.initialUserText),
                jsonBoolField("processing", activity.processing),
                jsonBoolField("has_scheduled_turn", activity.scheduledTurn),
                jsonBoolField("has_tool_use", activity.toolUse),
                jsonBoolField("has_generated_image", activity.generatedImage),
                jsonBoolField("has_web_search", activity.webSearch),
                jsonBoolField("has_compaction", activity.compaction),
                jsonBoolField("has_screen_capture", activity.screenCapture),
                sessionAutomaticUnseen(session.root) ? jsonBoolField("automatic_session_unseen", true) : "",
                unseenScheduledTurns
                    ? jsonLongField("unseen_scheduled_turn_count", unseenScheduledTurns) : "",
            ]));
        }
        output.put("]");
        return output.data;
    }

    private SessionActivity sessionActivity(string sessionRoot)
    {
        auto guard = scopedMutexLock(sessionActivityMutex);
        if (auto cached = sessionRoot in sessionActivityByRoot) return *cached;
        SessionActivity activity;
        activity.compaction = sessionHasCompletedCompaction(sessionRoot);
        auto turnsRoot = buildPath(sessionRoot, "turns");
        if (exists(turnsRoot)) {
            foreach (path; reader.turnJsonPaths(turnsRoot)) {
                auto payload = parseJSON(readText(path));
                auto status = jsonText(payload, "status");
                activity.processing = activity.processing
                    || status == "pending" || status == "running";
                activity.scheduledTurn = activity.scheduledTurn
                    || jsonText(payload, "source") == "scheduled_task";
                classifyTurnTools(dirName(path), activity);
            }
        }
        sessionActivityByRoot[sessionRoot] = activity;
        return activity;
    }

    private void invalidateSessionActivity(string sessionRoot)
    {
        auto guard = scopedMutexLock(sessionActivityMutex);
        sessionActivityByRoot.remove(sessionRoot);
    }

    private void classifyTurnTools(string turnRoot, ref SessionActivity activity)
    {
        auto path = toolsJsonPath(turnRoot);
        if (!exists(path)) return;
        foreach (tool; turnToolArray(parseJSON(readText(path))).array) {
            auto record = Json.object(tool);
            if (record.text("source") == "scheduler") continue;
            auto name = record.text("name");
            if (name == "generate_image") activity.generatedImage = true;
            else if (name == "web_search" || name == "image_search") activity.webSearch = true;
            else if (name == "capture_screen") activity.screenCapture = true;
            else activity.toolUse = true;
        }
    }

    private bool sessionHasCompletedCompaction(string sessionRoot)
    {
        bool completed;
        withSessionStorageLock(sessionRoot, {
            auto path = buildPath(sessionRoot, "presentation.jsonl");
            if (!exists(path)) return;
            foreach (line; readText(path).splitLines) {
                if (!line.strip.length) continue;
                auto entry = Json.object(parseJSON(line));
                if (entry.text("kind") != "compaction") continue;
                if (entry.object("payload").text("status") != "completed") continue;
                completed = true;
                break;
            }
        });
        return completed;
    }

    private bool sessionHasProcessingTurn(string sessionRoot)
    {
        auto turnsRoot = buildPath(sessionRoot, "turns");
        if (!exists(turnsRoot)) return false;
        foreach (path; reader.turnJsonPaths(turnsRoot)) {
            auto status = jsonText(parseJSON(readText(path)), "status");
            if (status == "pending" || status == "running") return true;
        }
        return false;
    }

    private bool sessionAutomaticUnseen(string sessionRoot)
    {
        return sessionFieldJson(sessionRoot, "automatic_session_unseen") == "true";
    }

    private long sessionUnseenScheduledCount(string sessionRoot)
    {
        auto unseen = sessionFieldJson(sessionRoot, "unseen_scheduled_turn_ids");
        if (unseen == "null") return 0;
        auto values = parseJSON(unseen);
        return values.type == JSONType.array ? cast(long) values.array.length : 0;
    }

    void deleteSession(SessionKey session)
    {
        auto recent = recentSessions.get(session.profileId, session.sessionId);
        enforce(!sessionHasProcessingTurn(recent.root),
            "Session cannot be deleted while Conversation work is active");
        auto trashRoot = buildPath(dirName(profilesRoot), "Trash", session.profileId);
        auto target = buildPath(trashRoot, session.sessionId.replace("/", dirSeparator));
        enforce(!exists(target), "Session Trash destination already exists");
        recentSessions.remove(session.profileId, session.sessionId, () {
            mkdirRecurse(dirName(target));
            rename(recent.root, target);
        });
        sessionRootByKey.remove(session.value);
        sessionMetadataByRoot.remove(recent.root);
        piSessionByRoot.remove(recent.root);
        string[] turnKeys;
        auto turnPrefix = recent.root ~ dirSeparator;
        foreach (key, root; turnRootById) {
            if (root.startsWith(turnPrefix)) turnKeys ~= key;
        }
        foreach (key; turnKeys) turnRootById.remove(key);
    }

    string sessionLanguage(SessionKey session)
    {
        return loadSessionMetadata(sessionRoot(session)).language;
    }

    void setSessionLanguage(SessionKey session, string language)
    {
        enforce(language.length, "Session language is required");
        writeSessionJson(sessionRoot(session), "", language);
    }

    string sessionModel(SessionKey session)
    {
        return loadSessionMetadata(sessionRoot(session)).model;
    }

    void setSessionModel(SessionKey session, string model)
    {
        enforce(model.length, "Session model is required");
        writeSessionJson(sessionRoot(session), "", "", "", model);
    }

    ReasoningMode sessionReasoningMode(SessionKey session)
    {
        return loadSessionMetadata(sessionRoot(session)).reasoningMode;
    }

    void setSessionReasoningMode(SessionKey session, ReasoningMode mode)
    {
        writeSessionJson(sessionRoot(session), "", "", reasoningModeText(mode));
    }

    void recordPiSession(
        SessionKey session,
        string model,
        string modelName,
        string sessionId,
        string sessionDir,
        string workingRoot,
        string workFolder,
        string extensionPath,
        string updatedAt,
    )
    {
        auto root = sessionRoot(session);
        piSessionByRoot[root] = PiSessionMetadata(
            model,
            modelName,
            sessionId,
            sessionDir,
            workingRoot,
            workFolder,
            extensionPath,
            updatedAt,
        );
        writeSessionJson(root);
    }

    void savePiSessionJsonl(SessionKey session, string sessionDir)
    {
        auto root = sessionRoot(session);
        if (absolutePath(buildNormalizedPath(sessionDir))
            == absolutePath(buildNormalizedPath(root))) return;
        auto source = reader.latestPiSessionJsonl(sessionDir);
        auto target = piSessionJsonlPath(root);

        if (!source.length) return;
        if (absolutePath(buildNormalizedPath(source)) != absolutePath(buildNormalizedPath(target))) {
            moveFileReplacing(source, target);
        }
    }

    string sessionPiSessionJsonl(SessionKey session)
    {
        auto path = piSessionJsonlPath(sessionRoot(session));
        return exists(path) ? readText(path) : "";
    }

    string sessionPiWorkingRoot(SessionKey session)
    {
        auto path = piSessionJsonlPath(sessionRoot(session));
        return exists(path) ? loadPiSessionTranscript(path).workingDirectory : "";
    }

    void restoreSessionPiSessionJsonl(SessionKey session, string jsonl)
    {
        enforce(jsonl.length, "Restored Pi session JSONL cannot be empty");
        auto root = sessionRoot(session);
        foreach (entry; dirEntries(root, SpanMode.shallow)) {
            if (entry.isFile && baseName(entry.name).endsWith(".jsonl")) remove(entry.name);
        }
        write(piSessionJsonlPath(root), jsonl);
        writeSessionJson(root);
    }

    void discardSessionPiSession(SessionKey session)
    {
        auto root = sessionRoot(session);
        foreach (entry; dirEntries(root, SpanMode.shallow)) {
            if (entry.isFile && baseName(entry.name).endsWith(".jsonl")) remove(entry.name);
        }
        piSessionByRoot.remove(root);
        writeSessionJson(root);
    }

    void saveSessionContext(SessionKey session, string context)
    {
        auto path = contextMarkdownPath(sessionRoot(session));
        if (exists(path)) return;
        writeTextFile(path, context.strip ~ "\n");
    }

    bool hasSessionContext(SessionKey session)
    {
        return exists(contextMarkdownPath(sessionRoot(session)));
    }

    string sessionContext(SessionKey session)
    {
        auto path = contextMarkdownPath(sessionRoot(session));
        return exists(path) ? readText(path).strip : "";
    }

    bool sessionPiSessionHasConversation(SessionKey session)
    {
        return reader.piSessionHasConversation(sessionRoot(session));
    }

    bool sessionHasPresentedModelContext(SessionKey session)
    {
        auto turnsRoot = buildPath(sessionRoot(session), "turns");
        if (!exists(turnsRoot)) return false;
        foreach (path; reader.turnJsonPaths(turnsRoot)) {
            auto input = loadModelInput(dirName(path));
            if (input.startingContext && input.prompt.length) return true;
        }
        return false;
    }

    ProfileConfigProperty[] effectiveConfigProperties(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto properties = appConfig.properties();
        properties ~= profileDocuments.configProperties(profileId);
        return properties;
    }

    ProfilePromptDocuments profilePromptDocuments(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return profileDocuments.promptDocuments(profileId);
    }

    ProfilePromptDocuments profilePromptDocumentsForSession(SessionKey session)
    {
        auto documents = profilePromptDocuments(session.profileId);
        auto sessionAutoMemory = readOptionalText(buildPath(sessionRoot(session), "memory_auto.md"));
        if (sessionAutoMemory.length) documents.autoMemory = sessionAutoMemory;
        return documents;
    }

    string instructionDocumentsJson(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return instructionDocuments.snapshotJson(profileId);
    }

    string saveInstructionDocuments(string profileId, Json request)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto guard = scopedMutexLock(profileDocumentMutex("__all_instructions__"));
        return instructionDocuments.saveJson(profileId, request);
    }

    string runtimePromptTemplate(string id)
    {
        return instructionDocuments.runtimeTemplate(id);
    }

    string sessionAutoMemoryCursor(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return profileDocuments.sessionAutoMemoryCursor(profileId);
    }

    string sessionAutoMemoryStateJson(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return profileDocuments.sessionAutoMemoryStateJson(profileId);
    }

    SessionAutoMemoryBacklog sessionAutoMemoryBacklog(string profileId, string currentSessionId)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto sessionsRoot = buildPath(locations.profileRoot(profileId), "sessions");
        if (!exists(sessionsRoot)) return SessionAutoMemoryBacklog(currentSessionId, "", 0, []);

        auto cursor = sessionAutoMemoryCursor(profileId);
        SessionAutoMemoryBacklog backlog;
        backlog.currentSessionId = currentSessionId;

        auto paths = reader.sessionJsonPaths(sessionsRoot);
        sort(paths);
        foreach (path; paths) {
            auto sessionRoot = dirName(path);
            auto sessionId = locations.sessionIdFromSessionRoot(profileId, sessionRoot);
            if (!sessionId.length) continue;
            if (cursor.length && sessionId <= cursor) continue;
            if (currentSessionId.length && sessionId >= currentSessionId) continue;

            auto before = backlog.messages.length;
            foreach (message; reader.normalUserMessages(profileId, sessionRoot, sessionId)) {
                backlog.messages ~= message;
            }
            if (backlog.messages.length > before) {
                backlog.sessionCount++;
                backlog.newestSessionId = sessionId;
            }
        }
        return backlog;
    }

    TaskMutex sessionAutoMemoryMutex(string profileId)
    {
        auto guard = scopedMutexLock(autoMemoryMutexRegistry);
        if (auto mutex = profileId in profileAutoMemoryMutexes) return *mutex;
        auto mutex = new TaskMutex;
        profileAutoMemoryMutexes[profileId] = mutex;
        return mutex;
    }

    bool sessionAutoMemoryRecoveryPending(SessionKey session)
    {
        auto guard = scopedMutexLock(profileDocumentMutex(session.profileId));
        auto processing = buildPath(profileRoot(session.profileId), "memory_auto_processing.md");
        return readOptionalText(processing).strip.length > 0;
    }

    string prepareSessionAutoMemoryBatch(
        SessionKey session,
        long triggerBytes,
        long maxPendingHours,
        string checkedAt,
    )
    {
        enforce(triggerBytes > 0, "Automatic-memory trigger bytes must be positive");
        enforce(maxPendingHours > 0, "Automatic-memory maximum pending hours must be positive");
        auto guard = scopedMutexLock(profileDocumentMutex(session.profileId));
        migrateSessionAutoMemoryInbox(session);

        auto processing = buildPath(profileRoot(session.profileId), "memory_auto_processing.md");
        auto pending = readOptionalText(processing).strip;
        if (pending.length) return pending ~ "\n";
        if (exists(processing)) remove(processing);

        auto todo = buildPath(profileRoot(session.profileId), "memory_auto_todo.md");
        auto todoMarkdown = readOptionalText(todo);
        pending = todoMarkdown.strip;
        if (!pending.length) {
            if (!exists(todo)) writeTextFile(todo, "");
            return "";
        }
        if (!sessionAutoMemoryTodoReady(
            todoMarkdown,
            triggerBytes,
            maxPendingHours,
            checkedAt,
        )) return "";

        rename(todo, processing);
        writeTextFile(todo, "");
        return pending ~ "\n";
    }

    void snapshotSessionAutoMemory(SessionKey session)
    {
        auto guard = scopedMutexLock(profileDocumentMutex(session.profileId));
        auto memory = readOptionalText(buildPath(profileRoot(session.profileId), "memory_auto.md"));
        writeTextFile(buildPath(sessionRoot(session), "memory_auto.md"), memory);
    }

    SessionAutoMemoryTurn createSessionAutoMemoryTurn(SessionKey session, string startedAt)
    {
        auto root = sessionRoot(session);
        auto turnRoot = createTurnRoot(root, startedAt, "memory_consolidation");
        auto turnId = locations.turnIdFromTurnRoot(turnRoot);
        turnRootById[turnId] = turnRoot;
        return SessionAutoMemoryTurn(
            turnId,
            session.sessionId,
            root,
            turnRoot,
            startedAt,
        );
    }

    void saveSessionAutoMemorySuccess(string profileId, SessionAutoMemorySave save)
    {
        enforce(profileExists(profileId), "Profile not found");
        writeTextFile(buildPath(save.turn.turnRoot, "memory_request.md"), save.requestMarkdown);
        savePiSessionJsonlTo(save.turn.turnRoot, save.piSessionDir, true);
        writeTextFile(buildPath(save.turn.turnRoot, "memory_auto.md"), save.outputMarkdown);
        writeSessionAutoMemoryTurnJson(
            save.turn.turnRoot,
            save.completedAt,
            save.sessionCount,
            save.messageCount,
            save.inputChars,
            save.outputChars,
            save.llmMetricsJson,
        );
        {
            auto guard = scopedMutexLock(profileDocumentMutex(profileId));
            writeTextFile(buildPath(locations.profileRoot(profileId), "memory_auto.md"), save.outputMarkdown);
            auto processing = buildPath(profileRoot(profileId), "memory_auto_processing.md");
            if (exists(processing)) remove(processing);
        }
        writeSessionJson(save.turn.sessionRoot);
    }

    void saveSessionAutoMemoryRequest(
        string profileId,
        SessionAutoMemoryTurn turn,
        string requestMarkdown,
        long sessionCount,
        long messageCount,
        long inputChars,
    )
    {
        enforce(profileExists(profileId), "Profile not found");
        writeTextFile(buildPath(turn.turnRoot, "memory_request.md"), requestMarkdown);
        writeSessionAutoMemoryRequestJson(turn.turnRoot, sessionCount, messageCount, inputChars);
        writeSessionJson(turn.sessionRoot);
    }

    void saveSessionAutoMemoryFailure(string profileId, SessionAutoMemoryFailure failure)
    {
        enforce(profileExists(profileId), "Profile not found");
        writeTextFile(buildPath(failure.turn.turnRoot, "memory_request.md"), failure.requestMarkdown);
        savePiSessionJsonlTo(failure.turn.turnRoot, failure.piSessionDir, false);
        writeSessionAutoMemoryFailureJson(
            failure.turn.turnRoot,
            failure.completedAt,
            failure.sessionCount,
            failure.messageCount,
            failure.inputChars,
            failure.llmMetricsJson,
            failure.errorMessage,
        );
        writeSessionJson(failure.turn.sessionRoot);
    }

    string beginTextTurn(TextTurnRecord turn)
    {
        enforce(profileExists(turn.profileId), "Profile not found");
        auto turnRoot = ensureTextTurnRoot(
            SessionKey(turn.profileId, turn.sessionId),
            turn.turnId,
            turn.startedAt,
        );
        auto sessionRoot = sessionRootFromTurnRoot(turnRoot);

        writeTextFile(buildPath(turnRoot, "turn.md"), turnMarkdown(turn.userText, ""));
        moveUserAudioIfPresent(turn, turnRoot);
        moveUserImageIfPresent(turn, turnRoot);
        writeTurnJson(turn, turnRoot);
        if (turn.source == "scheduled_task")
            markScheduledTurnUnseen(SessionKey(turn.profileId, turn.sessionId), turn.turnId);
        writeSessionJson(sessionRoot, "", turn.language);
        recentSessions.setInitialUserText(
            turn.profileId,
            sessionRoot,
            turn.userText.length ? turn.userText : turn.userImage.filename,
        );
        return locations.turnIdFromTurnRoot(turnRoot);
    }

    string saveTextTurn(TextTurnRecord turn)
    {
        enforce(profileExists(turn.profileId), "Profile not found");
        auto turnRoot = ensureTextTurnRoot(
            SessionKey(turn.profileId, turn.sessionId),
            turn.turnId,
            turn.startedAt,
        );
        auto sessionRoot = sessionRootFromTurnRoot(turnRoot);

        if (turn.executionId.length) {
            auto current = parseJSON(readText(buildPath(turnRoot, "turn.json")));
            enforce(
                jsonText(current, "execution_id") == turn.executionId,
                "Conversation execution claim changed",
            );
        }

        writeTextFile(buildPath(turnRoot, "turn.md"), turnMarkdown(turn.userText, turn.assistantText));
        moveUserAudioIfPresent(turn, turnRoot);
        moveUserImageIfPresent(turn, turnRoot);
        if (turn.errorsJson.length) writeJsonFile(errorsJsonPath(turnRoot), turn.errorsJson);
        writeSessionJson(sessionRoot, "", turn.language);
        writeTurnJson(turn, turnRoot);
        return locations.turnIdFromTurnRoot(turnRoot);
    }

    string claimConversationTurn(SessionKey session, string turnId)
    {
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Conversation turn not found");
        enforce(sessionRootFromTurnRoot(turnRoot) == sessionRoot(session), "Turn session mismatch");
        auto path = buildPath(turnRoot, "turn.json");
        auto payload = parseJSON(readText(path));
        enforce(jsonText(payload, "status") == "pending", "Conversation turn is not pending");
        enforce(!jsonText(payload, "execution_id").length, "Conversation turn is already claimed");
        auto executionId = randomUUID().toString();
        payload.object["status"] = JSONValue("running");
        payload.object["execution_id"] = JSONValue(executionId);
        writeJsonFileAtomic(path, payload.toString());
        invalidateSessionActivity(sessionRootFromTurnRoot(turnRoot));
        return executionId;
    }

    StoredTurn finishSteeredConversationTurn(
        SessionKey session,
        string turnId,
        string status,
        string completedAt,
        string assistantText,
        string metricsJson,
        string errorsJson = "",
    )
    {
        enforce(status == "completed" || status == "failed" || status == "stopped",
            "Invalid steered Conversation status");
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Steered Conversation turn not found");
        enforce(sessionRootFromTurnRoot(turnRoot) == sessionRoot(session),
            "Steered Conversation session mismatch");
        auto path = buildPath(turnRoot, "turn.json");
        auto payload = parseJSON(readText(path));
        enforce(jsonText(payload, "status") == "running",
            "Steered Conversation turn is not running");
        payload.object["status"] = JSONValue(status);
        payload.object["completed_at"] = JSONValue(completedAt);
        payload.object["metrics"] = parseJSON(jsonObjectRaw(metricsJson));
        writeTextFile(
            buildPath(turnRoot, "turn.md"),
            turnMarkdown(reader.loadTurn(turnRoot, true).userText, assistantText),
        );
        if (errorsJson.length) writeJsonFile(errorsJsonPath(turnRoot), errorsJson);
        writeJsonFileAtomic(path, payload.toString());
        invalidateSessionActivity(sessionRootFromTurnRoot(turnRoot));
        return reader.loadTurn(turnRoot, true);
    }

    void failInterruptedConversationTurn(
        SessionKey session,
        string turnId,
        string completedAt,
        string message,
    )
    {
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Conversation turn not found");
        enforce(sessionRootFromTurnRoot(turnRoot) == sessionRoot(session), "Turn session mismatch");
        auto path = buildPath(turnRoot, "turn.json");
        auto payload = parseJSON(readText(path));
        auto status = jsonText(payload, "status");
        enforce(status == "pending" || status == "running", "Conversation turn is terminal");
        payload.object["status"] = JSONValue("failed");
        payload.object["completed_at"] = JSONValue(completedAt);
        payload.object["execution_id"] = JSONValue("recovered-" ~ randomUUID().toString());
        writeJsonFileAtomic(path, payload.toString());
        appendTurnError(turnRoot, jsonObject([
            jsonStringField("stage", "conversation_recovery"),
            jsonStringField("recorded_at", completedAt),
            jsonStringField("message", message),
        ]));
        invalidateSessionActivity(sessionRootFromTurnRoot(turnRoot));
    }

    /** Closes an admitted turn whose queue item was cancelled before claim.
        Queue state carries the user-visible cancelled meaning; the existing
        stopped terminal status keeps history readers free of a second failure
        presentation. */
    void cancelPendingConversationTurn(
        SessionKey session,
        string turnId,
        string completedAt,
    )
    {
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Conversation turn not found");
        enforce(sessionRootFromTurnRoot(turnRoot) == sessionRoot(session), "Turn session mismatch");
        auto path = buildPath(turnRoot, "turn.json");
        auto payload = parseJSON(readText(path));
        enforce(jsonText(payload, "status") == "pending",
            "Only a pending Conversation turn may be queue-cancelled");
        payload.object["status"] = JSONValue("stopped");
        payload.object["completed_at"] = JSONValue(completedAt);
        writeJsonFileAtomic(path, payload.toString());
        invalidateSessionActivity(sessionRootFromTurnRoot(turnRoot));
    }

    size_t failInterruptedConversationTurns(string completedAt, string message)
    {
        size_t failed;
        foreach (profileId; reader.listProfiles()) {
            auto sessionsRoot = buildPath(locations.profileRoot(profileId), "sessions");
            if (!exists(sessionsRoot)) continue;
            foreach (path; reader.turnJsonPaths(sessionsRoot)) {
                auto payload = parseJSON(readText(path));
                if (!jsonText(payload, "submission_id").length) continue;
                auto status = jsonText(payload, "status");
                if (status != "pending" && status != "running") continue;
                auto turnRoot = dirName(path);
                auto sessionRoot = sessionRootFromTurnRoot(turnRoot);
                auto session = SessionKey(
                    profileId,
                    locations.sessionIdFromSessionRoot(profileId, sessionRoot),
                );
                failInterruptedConversationTurn(
                    session,
                    locations.turnIdFromTurnRoot(turnRoot),
                    completedAt,
                    message,
                );
                failed++;
            }
        }
        return failed;
    }

    long appendConversationEvent(ConversationEvent event)
    {
        auto eventGuard = scopedMutexLock(conversationEventMutex);
        auto turnRoot = existingTurnRoot(event.session.profileId, event.turnId);
        enforce(turnRoot.length, "Conversation turn not found for event");
        enforce(
            sessionRootFromTurnRoot(turnRoot) == sessionRoot(event.session),
            "Conversation event session mismatch",
        );
        auto previous = conversationEventTail(event.session, event.turnId, turnRoot);
        enforce(
            event.sequence == previous.sequence + 1,
            "Conversation event sequence must append exactly once",
        );
        if (previous.sequence) enforce(
            previous.kind != ConversationEventKind.completed
                && previous.kind != ConversationEventKind.failed,
            "Conversation event stream is already terminal",
        );
        auto eventJson = conversationEventJson(event);
        auto presentationUser = buildPath(turnRoot, ".presentation-user");
        bool eventPresented;
        long presentationSequence;
        if (!exists(presentationUser) && modelContextEvent(event)) {
            presentationSequence = appendPresentation(
                sessionRoot(event.session),
                "pi",
                conversationEventKindText(event.kind),
                event.turnId,
                presentationItemId(event),
                eventJson,
            );
            eventPresented = true;
            appendPresentation(
                sessionRoot(event.session),
                "pi",
                "user",
                event.turnId,
                "",
                "{}",
            );
            write(presentationUser, "recorded\n");
        } else if (!exists(presentationUser) && event.kind != ConversationEventKind.status) {
            appendPresentation(
                sessionRoot(event.session),
                "pi",
                "user",
                event.turnId,
                "",
                "{}",
            );
            write(presentationUser, "recorded\n");
        }
        if (!eventPresented) {
            presentationSequence = appendPresentation(
                sessionRoot(event.session),
                "pi",
                conversationEventKindText(event.kind),
                event.turnId,
                presentationItemId(event),
                eventJson,
            );
        }
        auto path = buildPath(turnRoot, "conversation.events.jsonl");
        auto file = File(path, "a");
        file.writeln(eventJson);
        file.flush();
        conversationEventTailByTurnRoot[turnRoot] = ConversationEventTail(
            event.sequence,
            event.kind,
        );
        if (event.kind == ConversationEventKind.tool
            || event.kind == ConversationEventKind.artifact
            || event.kind == ConversationEventKind.completed
            || event.kind == ConversationEventKind.failed)
            invalidateSessionActivity(sessionRoot(event.session));
        return presentationSequence;
    }

    ConversationEvent[] conversationEvents(SessionKey session, string turnId)
    {
        auto eventGuard = scopedMutexLock(conversationEventMutex);
        auto events = loadConversationEvents(session, turnId);
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        conversationEventTailByTurnRoot[turnRoot] = events.length
            ? ConversationEventTail(events[$ - 1].sequence, events[$ - 1].kind)
            : ConversationEventTail();
        return events;
    }

    ulong conversationEventSequence(SessionKey session, string turnId)
    {
        auto eventGuard = scopedMutexLock(conversationEventMutex);
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Conversation turn not found for events");
        enforce(sessionRootFromTurnRoot(turnRoot) == sessionRoot(session), "Turn session mismatch");
        return conversationEventTail(session, turnId, turnRoot).sequence;
    }

    ConversationEventFollower followConversationEvents(
        SessionKey session,
        string turnId,
        ulong afterSequence,
    )
    {
        return new ConversationEventFollower(this, session, turnId, afterSequence);
    }

    private ConversationEventTail conversationEventTail(
        SessionKey session,
        string turnId,
        string turnRoot,
    )
    {
        if (auto tail = turnRoot in conversationEventTailByTurnRoot) return *tail;
        auto events = loadConversationEvents(session, turnId);
        auto tail = events.length
            ? ConversationEventTail(events[$ - 1].sequence, events[$ - 1].kind)
            : ConversationEventTail();
        conversationEventTailByTurnRoot[turnRoot] = tail;
        return tail;
    }

    private ConversationEvent[] loadConversationEvents(SessionKey session, string turnId)
    {
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Conversation turn not found for events");
        enforce(sessionRootFromTurnRoot(turnRoot) == sessionRoot(session), "Turn session mismatch");
        auto path = buildPath(turnRoot, "conversation.events.jsonl");
        if (!exists(path)) return [];
        ConversationEvent[] events;
        foreach (line; readText(path).splitLines) {
            if (!line.strip.length) continue;
            auto event = persistedConversationEvent(line, session, turnId);
            enforce(event.sequence == events.length + 1, "Persisted Conversation event sequence gap");
            events ~= event;
        }
        return events;
    }

    void attachUserAudioToTurn(string profileId, string turnId, UserAudioArtifactRecord userAudio)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto turnRoot = existingTurnRoot(profileId, turnId);
        if (!turnRoot.length) turnRoot = existingTurnRoot("", turnId);
        enforce(turnRoot.length, "Turn not found for user audio attachment: " ~ turnId);
        enforce(locations.profileIdFromTurnRoot(turnRoot) == profileId, "Turn profile mismatch for user audio attachment");

        auto started = MonoTime.currTime;
        auto userAudioFile = moveUserAudioFile(profileId, userAudio, turnRoot);
        enforce(userAudioFile.length > 0, "User audio staged file was not available for attachment");
        auto attachAudioMs = cast(long) (MonoTime.currTime - started).total!"msecs";
        attachUserAudioMetricsToTurn(turnRoot, userAudio, attachAudioMs);
    }

    void recordUserAudioAttachmentFailure(string profileId, string turnId, string message)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto turnRoot = existingTurnRoot(profileId, turnId);
        if (!turnRoot.length) turnRoot = existingTurnRoot("", turnId);
        enforce(turnRoot.length, "Turn not found for user audio attachment failure: " ~ turnId);
        enforce(locations.profileIdFromTurnRoot(turnRoot) == profileId, "Turn profile mismatch for user audio attachment failure");
        appendTurnError(turnRoot, jsonObject([
            jsonStringField("stage", "audio_encode"),
            jsonStringField("recorded_at", nowIso()),
            jsonStringField("message", message),
        ]));
    }

    void saveRuntimeToolEvents(string profileId, string turnId, ExecutedTool[] tools)
    {
        if (!tools.length) return;
        auto turnRoot = existingTurnRoot(profileId, turnId);
        enforce(turnRoot.length, "Turn not found for tool persistence: " ~ turnId);
        writeJsonFile(toolsJsonPath(turnRoot), runtimeToolsJson(tools));
        invalidateSessionActivity(sessionRootFromTurnRoot(turnRoot));
        // Scheduler provenance is written before Pi begins emitting events.
        // Journal it at the same point so restored transcripts retain the
        // task-link position rather than having to infer it from later output.
        auto schedulerMarker = buildPath(turnRoot, ".presentation-scheduler-tools");
        if (!exists(schedulerMarker)) {
            foreach (tool; tools) {
                if (tool.source != "scheduler") continue;
                appendPresentation(
                    sessionRootFromTurnRoot(turnRoot),
                    "pi",
                    "tool",
                    turnId,
                    tool.eventId,
                    "{}",
                );
            }
            write(schedulerMarker, "recorded\n");
        }
    }

    void saveModelInput(string profileId, string turnId, ModelInput input)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto turnRoot = existingTurnRoot(profileId, turnId);
        enforce(turnRoot.length, "Turn not found for model input persistence: " ~ turnId);
        writeModelInput(turnRoot, input);
    }

    long appendLlmRequest(
        SessionKey session,
        string turnId,
        LlmRequestCapture capture,
    )
    {
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Turn not found for LLM request capture: " ~ turnId);
        enforce(sessionRootFromTurnRoot(turnRoot) == sessionRoot(session),
            "LLM request capture session mismatch");
        return .appendLlmRequest(turnRoot, capture);
    }

    void mergeClientTurnMetrics(SessionKey session, string turnId, string metricsJson)
    {
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Turn not found for client metrics: " ~ turnId);
        enforce(sessionRootFromTurnRoot(turnRoot) == sessionRoot(session), "Turn session mismatch");

        auto path = buildPath(turnRoot, "turn.json");
        auto payload = parseJSON(readText(path));
        auto incoming = Json.parse(jsonObjectRaw(metricsJson)).value;

        mergeAllowedClientMetrics(payload, incoming);
        writeJsonFile(path, payload.toString());
    }

    void appendUserPreference(string profileId, string memory, string timestamp)
    {
        auto guard = scopedMutexLock(profileDocumentMutex(profileId));
        profileDocuments.appendUserPreference(profileId, memory, timestamp);
    }

    ImportedCompletedTurn importCompletedTurn(CompletedTurnImport input)
    {
        enforce(profileExists(input.profileId), "Profile not found");
        auto guard = scopedMutexLock(profileSyncMutex(input.profileId));
        auto imported = commitCompletedTurn(locations, input);
        if (imported.imported) recentSessions.invalidate(input.profileId);
        appendSessionAutoMemoryTodoOnce(
            SessionKey(input.profileId, imported.sessionId),
            imported.turnId,
            imported.startedAt,
            imported.language,
            imported.userText,
        );
        return imported;
    }

    bool ensureSyncedSession(string profileId, RemoteTurnSessionHandoff handoff)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto guard = scopedMutexLock(profileSyncMutex(profileId));
        auto created = commitSyncedSession(locations, profileId, handoff);
        if (created) recentSessions.invalidate(profileId);
        return created;
    }

    RemoteTurnSessionHandoff remoteTurnSessionHandoff(SessionKey session)
    {
        auto root = sessionRoot(session);
        parseSyncSessionPath(session.sessionId);
        auto sessionJson = readText(buildPath(root, "session.json"));
        Json.object(parseJSON(sessionJson));
        return RemoteTurnSessionHandoff(session.sessionId, sessionJson);
    }

    string[] syncProfileIds()
    {
        return loadSyncProfileIds(reader);
    }

    SyncCompletedTurnExport[] exportReadyTurns(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return loadExportReadyTurns(locations, reader, profileId);
    }

    bool hasSyncTurn(string profileId, string sessionPath, string turnPath)
    {
        enforce(profileExists(profileId), "Profile not found");
        return syncTurnExists(locations, profileId, sessionPath, turnPath);
    }

    ProfileReplicaSnapshot syncProfileReplicaSnapshot(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return profileReplicaSnapshot(
            profileId,
            effectiveConfigProperties(profileId),
            profilePromptDocuments(profileId),
        );
    }

    void applySyncedProfileDocuments(ProfileReplicaSnapshot snapshot)
    {
        enforce(profileExists(snapshot.profileId), "Profile not found");
        auto guard = scopedMutexLock(profileSyncMutex(snapshot.profileId));
        profileDocuments.applyReplicaDocuments(snapshot);
    }

    void enableSyncedProfileReplicaDocuments()
    {
        profileDocuments.enableReplicaDocuments();
    }

    string[] syncSessionPaths(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return loadSyncSessionPaths(locations, reader, profileId);
    }

    bool syncSessionIsFullyExportable(string profileId, string sessionPath)
    {
        enforce(profileExists(profileId), "Profile not found");
        return syncSessionFullyExportable(
            locations,
            reader,
            profileId,
            sessionPath,
        );
    }

    void removeNonCurrentSyncSession(string profileId, string sessionPath)
    {
        enforce(profileExists(profileId), "Profile not found");
        auto guard = scopedMutexLock(profileSyncMutex(profileId));
        auto sessions = syncSessionPaths(profileId);
        enforce(sessions.length >= 3, "Current and last replica sessions must be retained");
        enforce(
            sessionPath != sessions[$ - 1] && sessionPath != sessions[$ - 2],
            "Current or last replica session cannot be removed",
        );
        auto session = parseSyncSessionPath(sessionPath);
        auto root = buildPath(
            locations.profileRoot(profileId),
            "sessions",
            session.year,
            session.month,
            session.day,
            session.folder,
        );
        enforce(exists(root), "Replica session is missing");
        rmdirRecurse(root);
        recentSessions.invalidate(profileId);
    }

    SyncSessionSnapshot latestSessionSnapshot(string profileId)
    {
        enforce(profileExists(profileId), "Profile not found");
        return loadLatestSessionSnapshot(locations, reader, profileId);
    }

    SyncSessionSnapshot sessionTurnSnapshot(
        string profileId,
        string sessionPath,
        string turnPath,
    )
    {
        enforce(profileExists(profileId), "Profile not found");
        return loadSessionTurnSnapshot(
            locations,
            reader,
            profileId,
            sessionPath,
            turnPath,
        );
    }

    SyncSnapshotFile resolveLatestSessionSnapshotFile(string profileId, string relativePath)
    {
        enforce(profileExists(profileId), "Profile not found");
        return resolveLatestSnapshotFile(locations, reader, profileId, relativePath);
    }

    SyncSnapshotFile resolveSessionTurnSnapshotFile(
        string profileId,
        string sessionPath,
        string turnPath,
        string relativePath,
    )
    {
        enforce(profileExists(profileId), "Profile not found");
        return resolveSessionTurnSnapshotFileImpl(
            locations,
            reader,
            profileId,
            sessionPath,
            turnPath,
            relativePath,
        );
    }

    void appendSessionAutoMemoryTodo(
        SessionKey session,
        string turnId,
        string timestamp,
        string language,
        string userText,
    )
    {
        sessionRoot(session);
        auto guard = scopedMutexLock(profileDocumentMutex(session.profileId));
        appendSessionAutoMemoryTodoLocked(session, turnId, timestamp, language, userText);
    }

    bool appendSessionAutoMemoryTodoOnce(
        SessionKey session,
        string turnId,
        string timestamp,
        string language,
        string userText,
    )
    {
        sessionRoot(session);
        auto guard = scopedMutexLock(profileDocumentMutex(session.profileId));
        auto path = buildPath(profileRoot(session.profileId), "memory_auto_todo.md");
        auto current = readOptionalText(path);
        auto key = "- Session: `" ~ session.sessionId ~ "`\n- Turn: `" ~ turnId ~ "`";
        if (current.indexOf(key) >= 0) return false;
        appendSessionAutoMemoryTodoLocked(session, turnId, timestamp, language, userText);
        return true;
    }

    private void appendSessionAutoMemoryTodoLocked(
        SessionKey session,
        string turnId,
        string timestamp,
        string language,
        string userText,
    )
    {
        auto path = buildPath(profileRoot(session.profileId), "memory_auto_todo.md");
        auto current = readOptionalText(path);
        auto output = appender!string;
        if (current.length) {
            output.put(current);
            if (!current.endsWith("\n")) output.put("\n");
        }
        putSessionAutoMemoryEntry(
            output,
            session.sessionId,
            turnId,
            timestamp,
            language,
            userText,
        );
        writeTextFile(path, output.data);
    }

    string profilesJson()
    {
        return views.profilesJson();
    }






    string sessionTurnsJson(SessionKey session)
    {
        return views.sessionTurnsJson(sessionRoot(session), sessionGeneratedImages(session));
    }

    string toolDetailJson(SessionKey session, string turnId, long callIndex)
    {
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length, "Turn not found");
        return piToolDetailJson(turn, sessionRoot(session), callIndex);
    }

    string turnReasoningJson(SessionKey session, string turnId, string itemId)
    {
        return jsonObject([jsonStringField(
            "text",
            turnPresentationItemText(session, turnId, itemId, "reasoning"),
        )]);
    }

    string turnPresentationItemText(
        SessionKey session,
        string turnId,
        string itemId,
        string expectedKind = "",
    )
    {
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length, "Turn not found");
        auto pi = loadPiSessionTranscript(piSessionJsonlPath(sessionRoot(session)));
        auto piTurn = pi.turn(turn);
        foreach (candidate; piTurn.items) {
            if (candidate.toolName != "generate_image" || candidate.details.type != JSONType.object)
                continue;
            auto details = Json.object(candidate.details);
            if (details.opt.textOrEmpty("kind") != "generated_image") continue;
            auto artifact = generatedImageArtifactFromJson(details);
            if (artifact.itemId != itemId) continue;
            if (expectedKind.length)
                enforce(expectedKind == "assistant", "Turn item kind mismatch");
            enforce(artifact.prompt.length, "Generated image has no prompt");
            return artifact.prompt;
        }
        auto item = piTurn.item(itemId);
        enforce(item.id.length, "Turn presentation item not found");
        if (expectedKind.length) enforce(item.kind == expectedKind, "Turn item kind mismatch");
        enforce(item.text.length, "Turn presentation item has no text");
        return item.text;
    }


    StoredTurn findTurn(string profileId, string turnId)
    {
        auto turnRoot = existingTurnRoot(profileId, turnId);
        if (!turnRoot.length) return StoredTurn();
        auto turn = reader.loadTurn(turnRoot, true);
        enforce(turn.profileId == profileId, "Turn profile mismatch");
        return turn;
    }

    StoredTurn findTurn(SessionKey session, string turnId)
    {
        auto turn = findTurn(session.profileId, turnId);
        if (!turn.id.length) return turn;
        enforce(
            sessionRootFromTurnRoot(turn.turnRoot) == sessionRoot(session),
            "Turn session mismatch",
        );
        return turn;
    }

    StoredTurn findTurnBySubmission(SessionKey session, string submissionId)
    {
        enforce(submissionId.length, "Submission ID is required");
        foreach (turn; reader.loadTurns(session.profileId, false)) {
            if (turn.submissionId != submissionId) continue;
            enforce(
                sessionRootFromTurnRoot(turn.turnRoot) == sessionRoot(session),
                "Submission session mismatch",
            );
            return reader.loadTurn(turn.turnRoot, true);
        }
        return StoredTurn();
    }

    bool sessionHasUserImage(SessionKey session)
    {
        auto root = sessionRoot(session);
        foreach (turn; reader.loadTurns(session.profileId, false)) {
            if (sessionRootFromTurnRoot(turn.turnRoot) == root && turn.hasUserImage)
                return true;
        }
        return false;
    }

    struct GeneratedImagePaths
    {
        string imagesRoot;
        string imagePath;
        string metadataPath;
        string artifactPath;
    }

    long nextGeneratedImageIndex(SessionKey session, string turnId)
    {
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length, "Turn not found for generated image");
        enforce(turn.status == "running", "Generated images require a running turn");
        long maximum;
        foreach (artifact; sessionGeneratedImages(session))
            if (artifact.generatedImageId > maximum) maximum = artifact.generatedImageId;
        return maximum + 1;
    }

    GeneratedImageArtifact[] sessionGeneratedImages(SessionKey session)
    {
        auto root = sessionRoot(session);
        GeneratedImageArtifact[] result;
        auto turnsRoot = buildPath(root, "turns");
        if (!exists(turnsRoot)) return result;
        StoredTurn[] turns;
        foreach (path; reader.turnJsonPaths(turnsRoot))
            turns ~= reader.loadTurn(dirName(path), false);
        sort!((left, right) => left.startedAt < right.startedAt)(turns);
        foreach (turn; turns) {
            auto imagesRoot = buildPath(turn.turnRoot, "images");
            if (!exists(imagesRoot)) continue;
            string[] metadataPaths;
            foreach (entry; dirEntries(imagesRoot, SpanMode.shallow)) {
                auto filename = baseName(entry.name);
                if (!entry.isFile || !filename.startsWith("generated-")
                    || !filename.endsWith(".json")) continue;
                metadataPaths ~= entry.name;
            }
            sort(metadataPaths);
            foreach (path; metadataPaths)
                result ~= generatedImageArtifactFromJson(Json.parse(readText(path)));
        }
        assignMissingGeneratedImageIds(result);
        sort!((left, right) => left.generatedImageId < right.generatedImageId)(result);
        foreach (index, artifact; result) {
            enforce(artifact.generatedImageId > 0, "Generated image ID is required");
            enforce(index == 0 || result[index - 1].generatedImageId < artifact.generatedImageId,
                "Generated image IDs must be unique within a session");
        }
        return result;
    }

    string sessionGeneratedImagesJson(SessionKey session)
    {
        auto output = appender!string;
        output.put("[");
        foreach (index, artifact; sessionGeneratedImages(session)) {
            if (index) output.put(",");
            output.put(generatedImageArtifactJson(artifact));
        }
        output.put("]");
        return output.data;
    }

    GeneratedImageArtifact sessionGeneratedImage(SessionKey session, long generatedImageId)
    {
        enforce(generatedImageId > 0, "Generated image ID must be positive");
        foreach (artifact; sessionGeneratedImages(session))
            if (artifact.generatedImageId == generatedImageId) return artifact;
        enforce(false, "Generated image not found");
        return GeneratedImageArtifact();
    }

    long generatedImageCount(SessionKey session, string turnId)
    {
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length, "Turn not found for generated images");
        auto imagesRoot = buildPath(turn.turnRoot, "images");
        if (!exists(imagesRoot)) return 0;
        long count;
        foreach (entry; dirEntries(imagesRoot, SpanMode.shallow)) {
            auto filename = baseName(entry.name);
            if (entry.isFile && filename.startsWith("generated-") && filename.endsWith(".png"))
                count++;
        }
        return count;
    }

    GeneratedImagePaths generatedImagePaths(
        SessionKey session,
        string turnId,
        string filename,
    )
    {
        enforce(filename.startsWith("generated-") && filename.endsWith(".png"),
            "Generated image filename is invalid");
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length, "Turn not found for generated image");
        auto imagesRoot = buildPath(turn.turnRoot, "images");
        return GeneratedImagePaths(
            imagesRoot,
            buildPath(imagesRoot, filename),
            buildPath(imagesRoot, filename[0 .. $ - 4] ~ ".json"),
            locations.profileArtifactRelativePath(buildPath(imagesRoot, filename)),
        );
    }

    GeneratedImageArtifact generatedImage(
        SessionKey session,
        string turnId,
        string filename,
    )
    {
        auto paths = generatedImagePaths(session, turnId, filename);
        return loadPresentationImage(paths, filename, "generated_image", "Generated image");
    }

    GeneratedImageArtifact screenCapture(
        SessionKey session,
        string turnId,
        string filename,
    )
    {
        enforce(filename.startsWith("screenshot-") && filename.endsWith(".png"),
            "Screen capture filename is invalid");
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length, "Turn not found for screen capture");
        auto imagesRoot = buildPath(turn.turnRoot, "images");
        auto paths = GeneratedImagePaths(
            imagesRoot,
            buildPath(imagesRoot, filename),
            buildPath(imagesRoot, filename[0 .. $ - 4] ~ ".json"),
            locations.profileArtifactRelativePath(buildPath(imagesRoot, filename)),
        );
        return loadPresentationImage(paths, filename, "screen_capture", "Screen capture");
    }

    private GeneratedImageArtifact loadPresentationImage(
        GeneratedImagePaths paths,
        string filename,
        string kind,
        string label,
    )
    {
        enforce(exists(paths.imagePath) && exists(paths.metadataPath), label ~ " not found");
        auto artifact = generatedImageArtifactFromJson(Json.parse(readText(paths.metadataPath)));
        enforce(artifact.kind == kind, label ~ " metadata kind changed");
        enforce(artifact.filename == filename, label ~ " metadata filename changed");
        enforce(artifact.path == paths.artifactPath, label ~ " metadata path changed");
        enforce(artifact.byteCount == getSize(paths.imagePath), label ~ " size changed");
        auto imageBytes = cast(ubyte[]) read(paths.imagePath);
        enforce(
            artifact.sha256 == toHexString!(LetterCase.lower)(sha256Of(imageBytes)),
            label ~ " hash changed",
        );
        artifact.path = paths.imagePath;
        return artifact;
    }

    string promoteScreenCapture(
        SessionKey session,
        string turnId,
        string sourcePath,
        Json clientArtifact,
        string toolCallId,
    )
    {
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length && turn.status == "running",
            "Screen capture requires a running turn");
        auto imagesRoot = buildPath(turn.turnRoot, "images");
        mkdirRecurse(imagesRoot);
        long index = 1;
        string filename;
        string imagePath;
        do {
            filename = "screenshot-" ~ (index < 10 ? "0" : "") ~ index.to!string ~ ".png";
            imagePath = buildPath(imagesRoot, filename);
            index++;
        } while (exists(imagePath));
        auto staging = imagePath ~ ".partial-" ~ randomUUID().toString();
        scope(failure) removeQuietly(staging);
        copy(sourcePath, staging);
        moveFileReplacing(staging, imagePath);
        auto bytes = cast(ubyte[]) read(imagePath);
        auto dimensions = screenCapturePngDimensions(bytes);
        auto modelWidth = clientArtifact.positiveInt("model_width");
        auto modelHeight = clientArtifact.positiveInt("model_height");
        enforce(modelWidth <= dimensions.width && modelHeight <= dimensions.height,
            "Screen capture model dimensions exceed the full image");
        enforce(
            modelWidth == dimensions.width && modelHeight == dimensions.height
                || modelWidth < dimensions.width && modelHeight < dimensions.height,
            "Screen capture model dimensions must preserve both axes",
        );
        auto aspect = dimensions.width == dimensions.height ? "square"
            : dimensions.width > dimensions.height ? "landscape" : "portrait";
        auto fullUrl = screenCaptureUrl(session, turnId, filename);
        auto modelUrl = modelWidth == dimensions.width && modelHeight == dimensions.height
            ? fullUrl
            : screenCaptureModelUrl(session, turnId, filename);
        auto artifact = GeneratedImageArtifact(
            0,
            "screen-capture:" ~ toolCallId,
            filename,
            "image/png",
            fullUrl,
            locations.profileArtifactRelativePath(imagePath),
            toHexString!(LetterCase.lower)(sha256Of(bytes)).idup,
            cast(long) bytes.length,
            dimensions.width,
            dimensions.height,
            0,
            "medium",
            aspect,
            "Screen capture",
            "screen_capture",
            modelWidth,
            modelHeight,
        );
        auto json = generatedImageArtifactJson(artifact);
        json = json[0 .. $ - 1] ~ ","
            ~ jsonStringField("scope", clientArtifact.nonEmpty("scope")) ~ ","
            ~ `"ui_scale":` ~ clientArtifact.value["ui_scale"].toString() ~ ","
            ~ jsonStringField("model_url", modelUrl) ~ "}";
        writeJsonFileAtomic(buildPath(imagesRoot, filename[0 .. $ - 4] ~ ".json"), json);
        return json;
    }

    alias WebImagePaths = GeneratedImagePaths;

    long nextWebImageIndex(SessionKey session, string turnId)
    {
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length, "Turn not found for web image");
        enforce(turn.status == "running", "Web images require a running turn");
        long index = 1;
        while (
            exists(webImagePaths(session, turnId,
                "web-" ~ (index < 10 ? "0" : "") ~ index.to!string ~ ".png").imagePath)
            || exists(webImagePaths(session, turnId,
                "web-" ~ (index < 10 ? "0" : "") ~ index.to!string ~ ".jpg").imagePath)
        ) index++;
        return index;
    }

    WebImagePaths webImagePaths(SessionKey session, string turnId, string filename)
    {
        enforce(
            filename.startsWith("web-")
                && (filename.endsWith(".png") || filename.endsWith(".jpg")),
            "Web image filename is invalid",
        );
        auto turn = findTurn(session, turnId);
        enforce(turn.id.length, "Turn not found for web image");
        auto imagesRoot = buildPath(turn.turnRoot, "images");
        return WebImagePaths(
            imagesRoot,
            buildPath(imagesRoot, filename),
            buildPath(imagesRoot, filename[0 .. $ - 4] ~ ".json"),
            locations.profileArtifactRelativePath(buildPath(imagesRoot, filename)),
        );
    }

    WebImageArtifact webImage(SessionKey session, string turnId, string filename)
    {
        auto paths = webImagePaths(session, turnId, filename);
        enforce(exists(paths.imagePath) && exists(paths.metadataPath), "Web image not found");
        auto artifact = webImageArtifactFromJson(Json.parse(readText(paths.metadataPath)));
        enforce(artifact.filename == filename, "Web image metadata filename changed");
        enforce(artifact.path == paths.artifactPath, "Web image metadata path changed");
        enforce(artifact.byteCount == getSize(paths.imagePath), "Web image size changed");
        auto imageBytes = cast(ubyte[]) read(paths.imagePath);
        enforce(
            artifact.sha256 == toHexString!(LetterCase.lower)(sha256Of(imageBytes)),
            "Web image hash changed",
        );
        artifact.path = paths.imagePath;
        return artifact;
    }

    FilePayload presentationImage(SessionKey session, string kind, long index)
    {
        enforce(index > 0, "Presentation image index must be positive");
        long current;
        foreach (turn; orderedSessionTurns(session)) {
            foreach (filename; presentationImageFilenames(turn, kind)) {
                if (++current != index) continue;
                if (kind == "screenshot") {
                    auto artifact = screenCapture(session, turn.id, filename);
                    return FilePayload(artifact.path, artifact.mediaType);
                }
                if (kind == "generated-image") {
                    auto artifact = generatedImage(session, turn.id, filename);
                    return FilePayload(artifact.path, artifact.mediaType);
                }
                auto artifact = webImage(session, turn.id, filename);
                return FilePayload(artifact.path, artifact.mediaType);
            }
        }
        throw new Exception("Presentation image not found");
    }

    FilePayload uploadedImage(SessionKey session, string filename, long uploadIndex)
    {
        enforce(uploadIndex > 0, "Uploaded image index must be positive");
        long current;
        foreach (turn; orderedSessionTurns(session)) {
            if (!turn.hasUserImage) continue;
            if (++current != uploadIndex) continue;
            enforce(turn.userImageFilename == filename, "Uploaded image filename changed");
            enforce(exists(turn.userImagePath), "Uploaded image file does not exist");
            enforce(getSize(turn.userImagePath) == turn.userImageBytes,
                "Uploaded image size changed");
            return FilePayload(turn.userImagePath, turn.userImageMediaType);
        }
        throw new Exception("Uploaded image not found");
    }

    private StoredTurn[] orderedSessionTurns(SessionKey session)
    {
        auto root = sessionRoot(session);
        auto turns = reader.loadSessionTurns(root, false);
        sort!((left, right) => left.startedAt < right.startedAt)(turns);
        return turns;
    }

    private string[] presentationImageFilenames(StoredTurn turn, string kind)
    {
        string prefix;
        string[] extensions;
        if (kind == "screenshot") {
            prefix = "screenshot-";
            extensions = [".png"];
        } else if (kind == "generated-image") {
            prefix = "generated-";
            extensions = [".png"];
        } else {
            enforce(kind == "search-image", "Unsupported presentation image kind");
            prefix = "web-";
            extensions = [".png", ".jpg"];
        }

        auto imagesRoot = buildPath(turn.turnRoot, "images");
        string[] filenames;
        if (!exists(imagesRoot)) return filenames;
        foreach (entry; dirEntries(imagesRoot, SpanMode.shallow)) {
            auto filename = baseName(entry.name);
            if (entry.isFile && filename.startsWith(prefix)
                && extensions.any!(extension => filename.endsWith(extension)))
                filenames ~= filename;
        }
        sort(filenames);
        return filenames;
    }

    GeneratedImageArtifact presentationScreenCapture(SessionKey session, long index)
    {
        enforce(index > 0, "Screen capture index must be positive");
        long current;
        foreach (turn; orderedSessionTurns(session)) {
            foreach (filename; presentationImageFilenames(turn, "screenshot")) {
                if (++current == index) return screenCapture(session, turn.id, filename);
            }
        }
        throw new Exception("Screen capture not found");
    }



    ArtifactRef artifactRef(string artifactId)
    {
        auto separator = artifactId.indexOf(":user_audio");
        if (separator < 0) return ArtifactRef(false);
        auto turnId = artifactId[0 .. cast(size_t) separator];
        auto turnRoot = existingTurnRoot("", turnId);
        if (!turnRoot.length) return ArtifactRef(false);
        auto path = buildPath(turnRoot, "user.opus");
        if (!exists(path)) return ArtifactRef(false);
        return ArtifactRef(true, locations.profileArtifactRelativePath(path), "audio/ogg");
    }

    private string profileRoot(string profileId)
    {
        return locations.profileRoot(profileId);
    }

    private TaskMutex profileDocumentMutex(string profileId)
    {
        auto guard = scopedMutexLock(documentMutexRegistry);
        if (auto mutex = profileId in profileDocumentMutexes) return *mutex;
        auto mutex = new TaskMutex;
        profileDocumentMutexes[profileId] = mutex;
        return mutex;
    }

    private TaskMutex profileSyncMutex(string profileId)
    {
        auto guard = scopedMutexLock(syncMutexRegistry);
        if (auto mutex = profileId in profileSyncMutexes) return *mutex;
        auto mutex = new TaskMutex;
        profileSyncMutexes[profileId] = mutex;
        return mutex;
    }

    private void migrateSessionAutoMemoryInbox(SessionKey session)
    {
        auto cursor = profileDocuments.sessionAutoMemoryCursor(session.profileId);
        if (!cursor.length) return;

        auto backlog = sessionAutoMemoryBacklog(session.profileId, session.sessionId);
        auto todoPath = buildPath(profileRoot(session.profileId), "memory_auto_todo.md");
        auto output = appender!string;
        auto current = readOptionalText(todoPath);
        if (current.length) {
            output.put(current);
            if (!current.endsWith("\n")) output.put("\n");
        }
        foreach (message; backlog.messages) {
            putSessionAutoMemoryEntry(
                output,
                message.sessionId,
                message.turnId,
                message.startedAt,
                "",
                message.userText,
            );
        }
        writeTextFile(todoPath, output.data);
        profileDocuments.clearSessionAutoMemoryCursor(session.profileId);
    }

    private string sessionRoot(SessionKey session)
    {
        enforce(profileExists(session.profileId), "Profile not found");
        if (auto cached = session.value in sessionRootByKey) {
            if (exists(buildPath(*cached, "session.json"))) return *cached;
            sessionRootByKey.remove(session.value);
        }
        auto sessionsRoot = buildPath(locations.profileRoot(session.profileId), "sessions");
        enforce(exists(sessionsRoot), "Session not found");
        foreach (path; reader.sessionJsonPaths(sessionsRoot)) {
            auto root = dirName(path);
            if (locations.sessionIdFromSessionRoot(session.profileId, root) == session.sessionId) {
                sessionRootByKey[session.value] = root;
                return root;
            }
        }
        enforce(false, "Session not found");
        return "";
    }

    private string resumableLastSessionRoot(string profileId)
    {
        auto sessions = recentSessions.load(profileId);
        if (!sessions.length) return "";
        auto started = SysTime.fromISOExtString(sessions[0].startedAt).toLocalTime();
        auto today = Clock.currTime().toLocalTime();
        return started.year == today.year
            && started.month == today.month
            && started.day == today.day
            ? sessions[0].root
            : "";
    }

    private string createSessionRoot(string profileId, string startedAt)
    {
        auto root = profileRoot(profileId);
        auto day = isoDate(startedAt);
        auto base = buildPath(
            root,
            "sessions",
            day[0 .. 4],
            day[5 .. 7],
            day[8 .. 10],
            sessionFolderName(startedAt),
        );
        auto sessionRoot = uniqueTimestampPath(base);
        mkdirRecurse(buildPath(sessionRoot, "turns"));
        return sessionRoot;
    }

    private string createTurnRoot(string sessionRoot, string startedAt, string turnId)
    {
        auto base = buildPath(sessionRoot, "turns", turnFolderName(startedAt));
        auto turnRoot = uniqueTimestampPath(base);
        mkdirRecurse(turnRoot);
        return turnRoot;
    }

    private string existingTurnRoot(string profileId, string turnId)
    {
        auto pathIdRoot = locations.turnRootFromPathId(turnId);
        if (pathIdRoot.length && exists(buildPath(pathIdRoot, "turn.json"))) return pathIdRoot;
        if (auto cached = turnId in turnRootById) {
            if (exists(buildPath(*cached, "turn.json"))) return *cached;
        }
        foreach (turn; reader.loadTurns(profileId, false)) {
            if (turn.id == turnId) {
                turnRootById[turnId] = turn.turnRoot;
                return turn.turnRoot;
            }
        }
        return "";
    }

    private string ensureTextTurnRoot(SessionKey session, string turnId, string startedAt)
    {
        auto root = sessionRoot(session);
        auto turnRoot = existingTurnRoot(session.profileId, turnId);
        if (!turnRoot.length) {
            turnRoot = createTurnRoot(root, startedAt, turnId);
        } else {
            enforce(sessionRootFromTurnRoot(turnRoot) == root, "Turn session mismatch");
        }
        turnRootById[turnId] = turnRoot;
        turnRootById[locations.turnIdFromTurnRoot(turnRoot)] = turnRoot;
        return turnRoot;
    }

    private string moveUserAudioIfPresent(TextTurnRecord turn, string turnRoot)
    {
        if (!turn.hasUserAudio) return "";
        return moveUserAudioFile(turn.profileId, turn.userAudio, turnRoot);
    }

    private string moveUserAudioFile(string profileId, UserAudioArtifactRecord userAudio, string turnRoot)
    {
        if (!userAudio.stagedPath.length) return "";
        auto source = isAbsolute(userAudio.stagedPath)
            ? userAudio.stagedPath
            : buildPath(profileRoot(profileId), userAudio.stagedPath.replace("/", dirSeparator));
        auto target = buildPath(turnRoot, "user.opus");
        auto normalizedSource = absolutePath(buildNormalizedPath(source));
        auto normalizedTarget = absolutePath(buildNormalizedPath(target));
        // Daemon-owned queue execution recovers audio from the durable turn
        // itself. Final persistence must therefore accept an already-attached
        // target instead of replacing the file with itself (which removes it).
        if (normalizedSource == normalizedTarget)
            return exists(target) ? "user.opus" : "";
        if (!exists(source))
            return exists(target) ? "user.opus" : "";
        moveFileReplacing(source, target);
        return "user.opus";
    }

    private void moveUserImageIfPresent(TextTurnRecord turn, string turnRoot)
    {
        if (!turn.hasUserImage || !turn.userImage.stagedPath.length) return;
        auto source = turn.userImage.stagedPath;
        if (!exists(source)) return;
        auto targetDirectory = buildPath(turnRoot, "images");
        mkdirRecurse(targetDirectory);
        moveFileReplacing(source, buildPath(targetDirectory, turn.userImage.filename));
        if (turn.userImage.stagedManifestPath.length
            && exists(turn.userImage.stagedManifestPath))
            remove(turn.userImage.stagedManifestPath);
        auto stagedDirectory = dirName(source);
        if (exists(stagedDirectory)) rmdir(stagedDirectory);
    }

    private void writeSessionJson(
        string sessionRoot,
        string mode = "",
        string language = "",
        string reasoningMode = "",
        string model = "",
    )
    {
        auto metadata = loadSessionMetadata(sessionRoot);
        if (mode.length) metadata.clientMode = mode;
        if (language.length) {
            enforce(
                !metadata.language.length || metadata.language == language,
                "Session language cannot change",
            );
            metadata.language = language;
        }
        if (model.length) metadata.model = model;
        if (reasoningMode.length) {
            metadata.reasoningMode = parseReasoningMode(reasoningMode);
        }
        sessionMetadataByRoot[sessionRoot] = metadata;
        withSessionStorageLock(sessionRoot, {
            auto codexJson = sessionCodexJson(sessionRoot);
            auto branchJson = sessionFieldJson(sessionRoot, "branch");
            auto scheduledTaskJson = sessionFieldJson(sessionRoot, "scheduled_task");
            auto automaticUnseenJson = sessionFieldJson(sessionRoot, "automatic_session_unseen");
            auto unseenScheduledJson = sessionFieldJson(sessionRoot, "unseen_scheduled_turn_ids");
            auto startedAt = sessionFieldText(sessionRoot, "started_at");
            writeJsonFile(buildPath(sessionRoot, "session.json"), jsonObject([
                startedAt.length ? jsonStringField("started_at", startedAt) : "",
                jsonStringField("client", metadata.clientMode),
                jsonStringField("language", metadata.language),
                jsonStringField("model", metadata.model),
                jsonStringField("reasoning_mode", reasoningModeText(metadata.reasoningMode)),
                jsonRawField("codex", codexJson),
                jsonRawField("branch", branchJson),
                jsonRawField("scheduled_task", scheduledTaskJson),
                jsonRawField("automatic_session_unseen", automaticUnseenJson),
                jsonRawField("unseen_scheduled_turn_ids", unseenScheduledJson),
            ]));
        });
        invalidateSessionActivity(sessionRoot);
    }

    private string sessionCodexJson(string sessionRoot)
    {
        return sessionFieldJson(sessionRoot, "codex");
    }

    private string sessionFieldJson(string sessionRoot, string name)
    {
        auto path = buildPath(sessionRoot, "session.json");
        if (!exists(path)) return "null";
        auto value = parseJSON(readText(path));
        if (value.type != JSONType.object) return "null";
        auto field = name in value.objectNoRef;
        return field is null ? "null" : field.toString();
    }

    private string sessionFieldText(string sessionRoot, string name)
    {
        auto path = buildPath(sessionRoot, "session.json");
        if (!exists(path)) return "";
        auto value = parseJSON(readText(path));
        return value.type == JSONType.object ? jsonText(value, name) : "";
    }

    private SessionMetadata loadSessionMetadata(string sessionRoot)
    {
        if (auto metadata = sessionRoot in sessionMetadataByRoot) return *metadata;
        auto metadata = reader.loadSessionMetadata(sessionRoot);
        sessionMetadataByRoot[sessionRoot] = metadata;
        return metadata;
    }

    private void savePiSessionJsonlTo(string targetRoot, string sessionDir, bool required)
    {
        auto source = reader.latestPiSessionJsonl(sessionDir, true);
        auto target = buildPath(targetRoot, "pi_session.jsonl");
        enforce(source.length || !required, "Pi session JSONL was not written");
        if (!source.length) return;
        if (absolutePath(buildNormalizedPath(source)) == absolutePath(buildNormalizedPath(target))) return;
        moveFileReplacing(source, target);
    }

}

/** One live reader over a turn's append-only Conversation journal. */
final class ConversationEventFollower
{
    private HistoryStore store;
    private SessionKey session;
    private string turnId;
    private string path;
    private ulong offset;
    private ulong cursor;

    this(
        HistoryStore store,
        SessionKey session,
        string turnId,
        ulong afterSequence,
    )
    {
        this.store = store;
        this.session = session;
        this.turnId = turnId;
        this.cursor = afterSequence;
        auto eventGuard = scopedMutexLock(store.conversationEventMutex);
        auto turnRoot = store.existingTurnRoot(session.profileId, turnId);
        enforce(turnRoot.length, "Conversation turn not found for events");
        enforce(
            sessionRootFromTurnRoot(turnRoot) == store.sessionRoot(session),
            "Turn session mismatch",
        );
        path = buildPath(turnRoot, "conversation.events.jsonl");
        auto tail = store.conversationEventTail(session, turnId, turnRoot);
        enforce(afterSequence <= tail.sequence, "Conversation replay cursor exceeds journal");
        if (!exists(path)) return;
        if (afterSequence == tail.sequence) {
            offset = getSize(path);
            return;
        }
        auto file = File(path, "r");
        char[] line;
        ulong found;
        while (file.readln(line)) {
            auto event = persistedConversationEvent(line, session, turnId);
            if (event.sequence > afterSequence) break;
            offset += line.length;
            found = event.sequence;
        }
        enforce(found == afterSequence, "Conversation replay cursor is not in the journal");
    }

    ConversationEvent[] readAvailable()
    {
        ConversationEvent[] events;
        auto eventGuard = scopedMutexLock(store.conversationEventMutex);
        if (!exists(path)) return events;
        enforce(getSize(path) >= offset, "Conversation journal shrank while following");
        auto file = File(path, "r");
        file.seek(offset);
        char[] line;
        while (file.readln(line)) {
            offset += line.length;
            auto event = persistedConversationEvent(line, session, turnId);
            enforce(event.sequence == cursor + 1, "Conversation journal sequence gap");
            cursor = event.sequence;
            events ~= event;
        }
        return events;
    }

    ulong sequence() const
    {
        return cursor;
    }
}

private ConversationEvent persistedConversationEvent(
    const(char)[] line,
    SessionKey session,
    string turnId,
)
{
    auto event = conversationEventFromJson(parseJSON(line.strip));
    enforce(event.session == session, "Persisted Conversation event session changed");
    enforce(event.turnId == turnId, "Persisted Conversation event turn changed");
    return event;
}

private string presentationItemId(ConversationEvent event)
{
    final switch (event.kind) {
        case ConversationEventKind.status:
        case ConversationEventKind.completed:
        case ConversationEventKind.failed:
            return "";
        case ConversationEventKind.assistantDelta:
            return event.assistantDelta.itemId;
        case ConversationEventKind.reasoning:
            return event.reasoning.itemId;
        case ConversationEventKind.tool:
            return event.tool.itemId;
        case ConversationEventKind.artifact:
            return event.artifact.itemId;
    }
}

private bool modelContextEvent(ConversationEvent event)
{
    return event.kind == ConversationEventKind.tool
        && event.tool.name == "model_context";
}

private struct ScreenCapturePngDimensions
{
    long width;
    long height;
}

private string screenCaptureUrl(SessionKey session, string turnId, string filename)
{
    return "/api/profiles/" ~ encodeComponent(session.profileId)
        ~ "/turns/" ~ encodeComponent(turnId)
        ~ "/images/" ~ encodeComponent(filename)
        ~ "?session_id=" ~ encodeComponent(session.sessionId);
}

private string screenCaptureModelUrl(SessionKey session, string turnId, string filename)
{
    return "/api/profiles/" ~ encodeComponent(session.profileId)
        ~ "/turns/" ~ encodeComponent(turnId)
        ~ "/images/" ~ encodeComponent(filename) ~ "/model"
        ~ "?session_id=" ~ encodeComponent(session.sessionId);
}

private ScreenCapturePngDimensions screenCapturePngDimensions(scope const ubyte[] bytes)
{
    immutable ubyte[] signature = [137, 80, 78, 71, 13, 10, 26, 10];
    enforce(bytes.length >= 24 && bytes[0 .. 8] == signature,
        "Screen capture is not a valid PNG");
    enforce(bytes[12 .. 16] == cast(ubyte[]) "IHDR", "Screen capture PNG has no IHDR");
    return ScreenCapturePngDimensions(
        screenCaptureBigEndian(bytes[16 .. 20]),
        screenCaptureBigEndian(bytes[20 .. 24]),
    );
}

private long screenCaptureBigEndian(scope const ubyte[] bytes)
{
    return (cast(long) bytes[0] << 24)
        | (cast(long) bytes[1] << 16)
        | (cast(long) bytes[2] << 8)
        | cast(long) bytes[3];
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-uploaded-image-links-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(profilesRoot, new AppConfigStore(configPath), root);
    auto session = store.startProfileSession(
        "tester",
        "2026-08-13T17:50:07.000000Z",
        "chat",
        "en",
    );

    foreach (index; 1 .. 3) {
        auto stagedRoot = buildPath(root, "upload-" ~ index.to!string);
        auto stagedPath = buildPath(stagedRoot, "same name.png");
        mkdirRecurse(stagedRoot);
        write(stagedPath, cast(ubyte[]) [cast(ubyte) index]);
        TextTurnRecord turn;
        turn.turnId = "upload-turn-" ~ index.to!string;
        turn.profileId = "tester";
        turn.sessionId = session.sessionId;
        turn.deviceId = "web";
        turn.source = "browser_image";
        turn.status = "completed";
        turn.startedAt = "2026-08-13T17:5" ~ index.to!string ~ ":00.000000Z";
        turn.completedAt = turn.startedAt;
        turn.modelName = "pi:test";
        turn.language = "en";
        turn.userText = "image " ~ index.to!string;
        turn.hasUserImage = true;
        turn.userImage = UserImageArtifactRecord(
            "same name.png",
            "image/png",
            stagedPath,
            "",
            1,
        );
        store.saveTextTurn(turn);
    }

    assert(cast(ubyte[]) read(store.uploadedImage(session, "same name.png", 1).path)
        == cast(ubyte[]) [1]);
    assert(cast(ubyte[]) read(store.uploadedImage(session, "same name.png", 2).path)
        == cast(ubyte[]) [2]);
    assertThrown(store.uploadedImage(session, "other.png", 1));
    assertThrown(store.uploadedImage(session, "same name.png", 3));
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-screen-capture-history-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(profilesRoot, new AppConfigStore(configPath), root);
    auto timestamp = "2026-08-13T17:50:07.000000Z";
    auto session = store.startProfileSession("tester", timestamp, "chat", "en");
    auto turnId = store.beginTextTurn(TextTurnRecord(
        "capture-turn",
        "tester",
        session.sessionId,
        "web",
        "browser_text",
        "pending",
        timestamp,
        "",
        "pi:test",
        "en",
        "Look at my screen",
        "",
        "",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
        ReasoningMode.off,
        false,
        "capture-submission",
    ));
    assert(store.claimConversationTurn(session, turnId).length);

    auto source = buildPath(root, "capture.png");
    ubyte[] png = [
        137, 80, 78, 71, 13, 10, 26, 10,
        0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 32, 0, 0, 0, 24,
    ];
    write(source, png);
    auto promoted = Json.parse(store.promoteScreenCapture(
        session,
        turnId,
        source,
        Json.parse(
            `{"url":"/full","scope":"active_display","ui_scale":1,`
                ~ `"model_width":16,"model_height":12}`,
        ),
        "capture-call",
    ));
    assert(promoted.nonEmpty("filename") == "screenshot-01.png");
    assert(promoted.nonEmpty("kind") == "screen_capture");

    auto restored = store.screenCapture(session, turnId, "screenshot-01.png");
    assert(restored.kind == "screen_capture");
    assert(restored.width == 32 && restored.height == 24);
    assert(isAbsolute(restored.path) && exists(restored.path));
}

private bool sessionAutoMemoryTodoReady(
    string todoMarkdown,
    long triggerBytes,
    long maxPendingHours,
    string checkedAt,
)
{
    if (todoMarkdown.length >= triggerBytes) return true;

    try {
        auto checkedTime = SysTime.fromISOExtString(checkedAt);
        foreach (line; todoMarkdown.splitLines()) {
            if (!line.startsWith("## ")) continue;
            auto oldestPending = SysTime.fromISOExtString(line[3 .. $].strip);
            return checkedTime - oldestPending >= dur!"hours"(maxPendingHours);
        }
    } catch (Exception) {
        // A malformed retained inbox must not become permanently unprocessable.
        return true;
    }
    return true;
}

private void putSessionAutoMemoryEntry(
    ref Appender!string output,
    string sessionId,
    string turnId,
    string timestamp,
    string language,
    string userText,
)
{
    output.put("## " ~ timestamp ~ "\n\n");
    output.put("- Session: `" ~ sessionId ~ "`\n");
    output.put("- Turn: `" ~ turnId ~ "`\n");
    if (language.length) output.put("- Language: `" ~ language ~ "`\n");
    output.put("\n" ~ userText.strip ~ "\n");
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-history-store-" ~ randomUUID().toString());
    scope(exit) {
        if (exists(root)) rmdirRecurse(root);
    }

    auto profilesRoot = buildPath(root, "profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    mkdirRecurse(buildPath(profilesRoot, "old"));
    mkdirRecurse(buildPath(profilesRoot, "today"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto appConfig = new AppConfigStore(configPath);
    auto store = new HistoryStore(profilesRoot, appConfig, root);
    auto timestamp = "2026-07-06T10:00:00.000000Z";

    store.startProfileSession("old", "2000-01-01T10:00:00.000000Z", "test", "en");
    assert(!store.canResumeLastProfileSession("old"));
    assert(!store.resumeLastProfileSession("old", "test").sessionId.length);

    auto todayTimestamp = nowIso();
    auto todaySession = store.startProfileSession("today", todayTimestamp, "test", "sk");
    assert(store.requireSession(todaySession) == store.sessionRuntimeRoot(todaySession));
    assertThrown(store.requireResumableSession(todaySession));
    store.saveTextTurn(TextTurnRecord(
        "today-turn",
        "today",
        todaySession.sessionId,
        "device",
        "api_text",
        "completed",
        todayTimestamp,
        todayTimestamp,
        "pi:test",
        "sk",
        "dnešná otázka",
        "dnešná odpoveď",
        "{}",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
    ));
    writeTextFile(
        buildPath(store.sessionRuntimeRoot(todaySession), "pi_session.jsonl"),
        `{"type":"message","message":{"role":"user"}}` ~ "\n",
    );
    auto reopenedStore = new HistoryStore(profilesRoot, appConfig, root);
    assert(reopenedStore.canResumeLastProfileSession("today"));
    assert(reopenedStore.lastSessionLanguage("today") == "sk");
    assert(reopenedStore.resumeLastProfileSession("today", "test").sessionId == todaySession.sessionId);

    auto testerSession = store.startProfileSession("tester", timestamp, "test", "en");
    assert(store.sessionTurnsJson(testerSession) == "[]");
    store.saveTextTurn(TextTurnRecord(
        "turn-1",
        "tester",
        testerSession.sessionId,
        "device",
        "api_text",
        "completed",
        timestamp,
        timestamp,
        "pi:test",
        "en",
        "hello",
        "hi",
        jsonObject([
            jsonRawField("turn", jsonObject([
                jsonLongField("total_ms", 1),
            ])),
        ]),
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
    ));

    auto stagedPath = buildPath(root, "staged.opus");
    write(stagedPath, cast(ubyte[]) [1, 2, 3, 4]);
    store.attachUserAudioToTurn(
        "tester",
        "turn-1",
        UserAudioArtifactRecord(
            "runtime-user-audio:turn-1",
            "tester",
            timestamp,
            stagedPath,
            4,
            1.0,
            true,
            7,
            true,
        ),
    );

    assert(!exists(stagedPath));
    auto artifact = store.artifactRef("turn-1:user_audio");
    assert(artifact.found);
    assert(artifact.mediaType == "audio/ogg");
    auto turnRoot = buildPath(profilesRoot, "tester", "sessions", "2026", "07", "06", "10_00_00", "turns", "10_00_00_000000");
    auto durableUserAudioPath = buildPath(turnRoot, "user.opus");
    // A queue dispatcher recovers voice audio from the turn directory. Saving
    // that same artifact again must be idempotent and preserve its bytes.
    store.attachUserAudioToTurn(
        "tester",
        "turn-1",
        UserAudioArtifactRecord(
            "runtime-user-audio:turn-1",
            "tester",
            timestamp,
            durableUserAudioPath,
            4,
            1.0,
            true,
            7,
            true,
        ),
    );
    assert(read(durableUserAudioPath) == cast(ubyte[]) [1, 2, 3, 4]);
    auto metricsPayload = parseJSON(turnMetricsJson(turnRoot));
    assert(metricsPayload.object["turn"].object["total_ms"].integer == 1);
    assert(exists(buildPath(turnRoot, "user.opus")));
    assert(!exists(buildPath(turnRoot, "prompt.md")));
    assert(!exists(buildPath(turnRoot, "llm")));
    auto sessionJson = readText(buildPath(profilesRoot, "tester", "sessions", "2026", "07", "06", "10_00_00", "session.json"));
    assert(sessionJson.canFind(`"client": "test"`));
    assert(sessionJson.canFind(`"language": "en"`));
    assert(!sessionJson.canFind("runtime"));

    auto sessionRoot = buildPath(profilesRoot, "tester", "sessions", "2026", "07", "06", "10_00_00");
    assert(!store.hasSessionContext(testerSession));
    assert(store.sessionContext(testerSession) == "");
    store.saveSessionContext(testerSession, "# context");
    assert(store.hasSessionContext(testerSession));
    assert(store.sessionContext(testerSession) == "# context");
    assert(readText(buildPath(sessionRoot, "context.md")) == "# context\n");
    store.saveSessionContext(testerSession, "# changed");
    assert(readText(buildPath(sessionRoot, "context.md")) == "# context\n");
    assert(!store.sessionHasPresentedModelContext(testerSession));
    store.saveModelInput(
        "tester",
        "turn-1",
        ModelInput("# context", timestamp, "/work", true, false),
    );
    assert(store.sessionHasPresentedModelContext(testerSession));
    remove(modelInputJsonPath(turnRoot));

    auto piSessionPath = buildPath(sessionRoot, "pi_session.jsonl");
    auto nativePiSession = `{"type":"message","message":{"role":"user","content":[{"type":"text","text":"kept"}]}}` ~ "\n";
    writeTextFile(piSessionPath, nativePiSession);
    auto presentationPath = buildPath(sessionRoot, "presentation.jsonl");
    writeTextFile(presentationPath, `{"sequence":1}` ~ "\n");
    store.savePiSessionJsonl(testerSession, sessionRoot);
    assert(readText(piSessionPath) == nativePiSession);
    assert(readText(presentationPath) == `{"sequence":1}` ~ "\n");
    remove(piSessionPath);
    store.savePiSessionJsonl(testerSession, sessionRoot);
    assert(!exists(piSessionPath));
    writeTextFile(
        piSessionPath,
        `{"type":"session","version":3,"cwd":"/tmp"}` ~ "\n"
        ~ `{"type":"message","timestamp":"` ~ timestamp
        ~ `","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}` ~ "\n"
        ~ `{"type":"message","timestamp":"` ~ timestamp
        ~ `","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}` ~ "\n",
    );

    auto secondTimestamp = "2026-07-06T10:01:00.000000Z";
    auto secondSession = store.startProfileSession("tester", secondTimestamp, "test", "en");
    store.saveTextTurn(TextTurnRecord(
        "turn-2",
        "tester",
        secondSession.sessionId,
        "device",
        "api_text",
        "completed",
        secondTimestamp,
        secondTimestamp,
        "pi:test",
        "en",
        "second conversation",
        "second response",
        "{}",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
    ));
    writeTextFile(
        piSessionJsonlPath(store.sessionRuntimeRoot(secondSession)),
        `{"type":"session","version":3,"cwd":"/tmp"}` ~ "\n"
        ~ `{"type":"message","timestamp":"` ~ secondTimestamp
        ~ `","message":{"role":"user","content":[{"type":"text","text":"second conversation"}]}}` ~ "\n"
        ~ `{"type":"message","timestamp":"` ~ secondTimestamp
        ~ `","message":{"role":"assistant","content":[{"type":"text","text":"second response"}]}}` ~ "\n",
    );
    assert(store.sessionTurnsJson(testerSession).canFind("hello"));
    assert(!store.sessionTurnsJson(testerSession).canFind("second conversation"));
    assert(store.sessionTurnsJson(secondSession).canFind("second conversation"));

    store.appendSessionAutoMemoryTodo(
        testerSession,
        "turn-1",
        timestamp,
        "en",
        "remember first",
    );
    store.appendSessionAutoMemoryTodo(
        secondSession,
        "turn-2",
        secondTimestamp,
        "en",
        "remember second",
    );
    assert(store.prepareSessionAutoMemoryBatch(
        secondSession,
        8_192,
        24,
        "2026-07-06T10:03:00.000000Z",
    ).length == 0);
    assert(!exists(buildPath(profilesRoot, "tester", "memory_auto_processing.md")));

    auto firstBatch = store.prepareSessionAutoMemoryBatch(
        secondSession,
        1,
        24,
        "2026-07-06T10:03:00.000000Z",
    );
    assert(firstBatch.canFind("remember first"));
    assert(firstBatch.canFind("remember second"));
    store.appendSessionAutoMemoryTodo(
        secondSession,
        "turn-3",
        "2026-07-06T10:02:00.000000Z",
        "en",
        "arrived while processing",
    );
    assert(store.prepareSessionAutoMemoryBatch(
        secondSession,
        8_192,
        24,
        "2026-07-06T10:03:00.000000Z",
    ) == firstBatch);

    auto memoryTurn = store.createSessionAutoMemoryTurn(
        secondSession,
        "2026-07-06T10:03:00.000000Z",
    );
    writeTextFile(buildPath(memoryTurn.turnRoot, "pi_session.jsonl"), "{}\n");
    store.saveSessionAutoMemorySuccess("tester", SessionAutoMemorySave(
        memoryTurn,
        "# Request\n",
        "# Memory\n",
        memoryTurn.turnRoot,
        secondSession.sessionId,
        2,
        2,
        10,
        9,
        "{}",
        "2026-07-06T10:03:01.000000Z",
    ));
    assert(store.prepareSessionAutoMemoryBatch(
        secondSession,
        8_192,
        24,
        "2026-07-06T10:03:01.000000Z",
    ).length == 0);
    auto secondBatch = store.prepareSessionAutoMemoryBatch(
        secondSession,
        8_192,
        24,
        "2026-07-07T10:02:00.000000Z",
    );
    assert(secondBatch.canFind("arrived while processing"));
    assert(!secondBatch.canFind("remember first"));
    store.snapshotSessionAutoMemory(secondSession);
    assert(readText(buildPath(store.sessionRuntimeRoot(secondSession), "memory_auto.md")) == "# Memory\n");

    auto migrateRoot = buildPath(profilesRoot, "migrate");
    mkdirRecurse(migrateRoot);
    auto migratedCursorSession = store.startProfileSession(
        "migrate",
        "2026-07-06T09:00:00.000000Z",
        "test",
        "en",
    );
    auto migratedPendingSession = store.startProfileSession(
        "migrate",
        "2026-07-06T09:01:00.000000Z",
        "test",
        "en",
    );
    store.saveTextTurn(TextTurnRecord(
        "migrate-turn",
        "migrate",
        migratedPendingSession.sessionId,
        "device",
        "api_text",
        "failed",
        "2026-07-06T09:01:01.000000Z",
        "2026-07-06T09:01:02.000000Z",
        "pi:test",
        "en",
        "failed accepted prompt",
        "",
        "{}",
        true,
        1,
        "{}",
        false,
        UserAudioArtifactRecord(),
    ));
    writeTextFile(
        buildPath(migrateRoot, "config.json"),
        jsonObject([jsonRawField(
            "memory",
            jsonObject([jsonStringField("last_built_session", migratedCursorSession.sessionId)]),
        )]),
    );
    writeTextFile(buildPath(migrateRoot, "memory_auto.json"), "{}\n");
    auto migratedCurrentSession = store.startProfileSession(
        "migrate",
        "2026-07-06T09:02:00.000000Z",
        "test",
        "en",
    );
    auto migratedBatch = store.prepareSessionAutoMemoryBatch(
        migratedCurrentSession,
        1,
        24,
        "2026-07-06T09:02:00.000000Z",
    );
    assert(migratedBatch.canFind("failed accepted prompt"));
    assert(!readText(buildPath(migrateRoot, "config.json")).canFind("last_built_session"));
    assert(!exists(buildPath(migrateRoot, "memory_auto.json")));

    store.saveRuntimeToolEvents("tester", "turn-1", [
        ExecutedTool(
            "tool-1",
            timestamp,
            ToolCall("web_search", `{"query":"x"}`),
            ToolResult("web_search", true, jsonObject([
                jsonStringField("summary", "legacy preview"),
                jsonStringField("result_preview", "legacy preview"),
                jsonStringField("text", "canonical text"),
            ])),
            0.1,
            0,
            "pi",
        ),
    ]);
    auto toolsPayload = parseJSON(readText(buildPath(turnRoot, "tools.json")));
    assert(toolsPayload.object["schema"].str == "wheatley.runtime_tools.v1");
    auto toolResult = toolsPayload.object["tools"].array[0].object["result"];
    assert(("summary" in toolResult.object) is null);
    assert(("result_preview" in toolResult.object) is null);
    assert(toolResult.object["text"].str == "canonical text");

    store.mergeClientTurnMetrics(testerSession, "turn-1", jsonObject([
        jsonRawField("audio", jsonObject([
            jsonLongField("client_audio_bytes", 1_920),
            jsonLongField("client_sent_bytes", 1_920),
            jsonLongField("accepted_seconds", 99),
            jsonStringField("client_audio_format", "pcm_s16le"),
        ])),
        jsonRawField("tts", jsonObject([
            jsonStringField("model", "piper:test"),
            jsonLongField("chunks", 2),
        ])),
        jsonRawField("turn", jsonObject([
            jsonLongField("endpoint_to_first_spoken_audio_ms", 123),
            jsonLongField("total_ms", 99),
        ])),
    ]));
    auto merged = parseJSON(readText(buildPath(turnRoot, "turn.json")));
    assert(merged.object["metrics"].object["audio"].object["client_audio_bytes"].integer == 1_920);
    assert(merged.object["metrics"].object["audio"].object["client_sent_bytes"].integer == 1_920);
    assert(merged.object["metrics"].object["audio"].object["client_audio_format"].str == "pcm_s16le");
    auto acceptedSeconds = merged.object["metrics"].object["audio"].object["accepted_seconds"];
    assert(
        (acceptedSeconds.type == JSONType.integer && acceptedSeconds.integer == 1)
        || (acceptedSeconds.type == JSONType.float_ && acceptedSeconds.floating == 1.0)
    );
    assert(merged.object["metrics"].object["tts"].object["model"].str == "piper:test");
    assert(merged.object["metrics"].object["tts"].object["chunks"].integer == 2);
    assert(merged.object["metrics"].object["turn"].object["endpoint_to_first_spoken_audio_ms"].integer == 123);
    assert(merged.object["metrics"].object["turn"].object["total_ms"].integer == 1);

    writeJsonFile(buildPath(turnRoot, "tools.json"), `{"schema":"unknown","tools":[]}`);
    assert(store.healthJson().canFind(`"profiles":`));
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-conversation-follower-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(profilesRoot, new AppConfigStore(configPath), root);
    auto session = store.startProfileSession(
        "tester", "2026-08-25T13:00:00.000000Z", "chat", "en",
    );
    auto turnId = store.beginTextTurn(TextTurnRecord(
        "follow-turn", "tester", session.sessionId, "browser", "browser_text",
        "pending", "2026-08-25T13:00:01.000000Z", "", "pi:test", "en",
        "Question", "", "", false, 0, "", false,
        UserAudioArtifactRecord(), ReasoningMode.off,
    ));

    ConversationEvent first;
    first.session = session;
    first.turnId = turnId;
    first.sequence = 1;
    first.timestamp = "2026-08-25T13:00:01.100000Z";
    first.kind = ConversationEventKind.status;
    first.status.code = "accepted";
    first.status.message = "Accepted.";
    first.status.detailsJson = "{}";
    store.appendConversationEvent(first);

    ConversationEvent second;
    second.session = session;
    second.turnId = turnId;
    second.sequence = 2;
    second.timestamp = "2026-08-25T13:00:01.200000Z";
    second.kind = ConversationEventKind.assistantDelta;
    second.assistantDelta.itemId = "assistant:0:0";
    second.assistantDelta.text = "A";
    store.appendConversationEvent(second);

    auto follower = store.followConversationEvents(session, turnId, 1);
    auto available = follower.readAvailable();
    assert(available.length == 1);
    assert(available[0].sequence == 2);
    assert(available[0].assistantDelta.text == "A");
    assert(follower.sequence == 2);
    assert(follower.readAvailable().length == 0);

    ConversationEvent third = second;
    third.sequence = 3;
    third.timestamp = "2026-08-25T13:00:01.300000Z";
    third.assistantDelta.text = "B";
    store.appendConversationEvent(third);
    available = follower.readAvailable();
    assert(available.length == 1);
    assert(available[0].sequence == 3);
    assert(available[0].assistantDelta.text == "B");

    auto atTail = store.followConversationEvents(session, turnId, 3);
    assert(atTail.readAvailable().length == 0);
    ConversationEvent fourth = second;
    fourth.sequence = 4;
    fourth.timestamp = "2026-08-25T13:00:01.400000Z";
    fourth.assistantDelta.text = "C";
    store.appendConversationEvent(fourth);
    available = atTail.readAvailable();
    assert(available.length == 1 && available[0].sequence == 4);
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-recent-sessions-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    mkdirRecurse(buildPath(profilesRoot, "other"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(profilesRoot, new AppConfigStore(configPath), root);

    auto empty = store.startProfileSession(
        "tester",
        "2026-07-14T08:00:00.000000Z",
        "chat",
        "en",
    );
    auto memoryOnly = store.startProfileSession(
        "tester",
        "2026-07-14T08:30:00.000000Z",
        "chat",
        "en",
    );
    auto memoryTurn = store.createSessionAutoMemoryTurn(
        memoryOnly,
        "2026-07-14T08:30:01.000000Z",
    );
    store.saveSessionAutoMemoryRequest("tester", memoryTurn, "# Memory request\n", 1, 1, 10);
    writeTextFile(
        buildPath(store.sessionRuntimeRoot(memoryOnly), "pi_session.jsonl"),
        `{"type":"message","message":{"role":"user"}}` ~ "\n",
    );
    auto resumable = store.startProfileSession(
        "tester",
        "2026-07-14T09:00:00.000000Z",
        "chat",
        "en",
    );
    store.saveTextTurn(TextTurnRecord(
        "recent-turn",
        "tester",
        resumable.sessionId,
        "browser",
        "browser_text",
        "completed",
        "2026-07-14T09:00:01.000000Z",
        "2026-07-14T09:00:02.000000Z",
        "pi:test",
        "en",
        "Full first prompt",
        "Response",
        "{}",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
    ));
    writeTextFile(
        buildPath(store.sessionRuntimeRoot(resumable), "pi_session.jsonl"),
        `{"type":"message","message":{"role":"user"}}` ~ "\n",
    );
    store.saveRuntimeToolEvents("tester", "recent-turn", [
        ExecutedTool("tool-generic", "2026-07-14T09:00:03.000000Z",
            ToolCall("read_file", `{}`), ToolResult("read_file", true, `{}`), 0.1, 0, "pi"),
        ExecutedTool("tool-image", "2026-07-14T09:00:04.000000Z",
            ToolCall("generate_image", `{}`), ToolResult("generate_image", true, `{}`), 0.1, 1, "pi"),
        ExecutedTool("tool-web", "2026-07-14T09:00:05.000000Z",
            ToolCall("web_search", `{}`), ToolResult("web_search", true, `{}`), 0.1, 2, "pi"),
        ExecutedTool("tool-screen", "2026-07-14T09:00:06.000000Z",
            ToolCall("capture_screen", `{}`), ToolResult("capture_screen", true, `{}`), 0.1, 3, "pi"),
        ExecutedTool("tool-scheduler", "2026-07-14T09:00:07.000000Z",
            ToolCall("scheduled_task_trigger", `{}`), ToolResult("scheduled_task_trigger", true, `{}`),
            0.1, 4, "scheduler"),
    ]);
    appendPresentation(
        store.sessionRuntimeRoot(resumable),
        "pi",
        "compaction",
        "recent-turn",
        "compaction-1",
        `{"status":"completed"}`,
    );
    auto unknownLanguage = store.startProfileSession(
        "tester",
        "2026-07-14T09:30:00.000000Z",
        "chat",
        "en",
    );
    store.saveTextTurn(TextTurnRecord(
        "unknown-language-turn",
        "tester",
        unknownLanguage.sessionId,
        "browser",
        "browser_text",
        "completed",
        "2026-07-14T09:30:01.000000Z",
        "2026-07-14T09:30:02.000000Z",
        "pi:test",
        "en",
        "Legacy prompt without language",
        "Response",
        "{}",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
    ));
    writeTextFile(
        buildPath(store.sessionRuntimeRoot(unknownLanguage), "pi_session.jsonl"),
        `{"type":"message","message":{"role":"user"}}` ~ "\n",
    );
    writeTextFile(buildPath(store.sessionRuntimeRoot(unknownLanguage), "session.json"), `{"client":"chat","language":"en","model":"","reasoning_mode":"off"}` ~ "\n");
    writeTextFile(
        buildPath(store.sessionRuntimeRoot(unknownLanguage), "turns", "09_30_01_000000", "turn.json"),
        `{"reasoning_mode":"off","metrics":{}}` ~ "\n",
    );
    auto legacy = store.startProfileSession(
        "tester",
        "2026-07-14T10:00:00.000000Z",
        "chat",
        "en",
    );
    store.saveTextTurn(TextTurnRecord(
        "legacy-turn",
        "tester",
        legacy.sessionId,
        "browser",
        "browser_text",
        "completed",
        "2026-07-14T10:00:01.000000Z",
        "2026-07-14T10:00:02.000000Z",
        "pi:test",
        "en",
        "Legacy transcript only",
        "Response",
        "{}",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
    ));

    auto recent = store.recentSessionsJson("tester");
    assert(recent.canFind("Full first prompt"));
    bool foundUnknownLanguage;
    bool foundActivity;
    foreach (entry; parseJSON(recent).array) {
        if (entry.object["session_id"].str == resumable.sessionId) {
            assert(entry.object["has_tool_use"].boolean);
            assert(entry.object["has_generated_image"].boolean);
            assert(entry.object["has_web_search"].boolean);
            assert(entry.object["has_compaction"].boolean);
            assert(entry.object["has_screen_capture"].boolean);
            foundActivity = true;
        }
        if (entry.object["session_id"].str != unknownLanguage.sessionId) continue;
        assert(entry.object["language"].str == "en");
        assert(entry.object["initial_user_text"].str == "Legacy prompt without language");
        assert(!entry.object["has_tool_use"].boolean);
        assert(!entry.object["has_generated_image"].boolean);
        assert(!entry.object["has_web_search"].boolean);
        assert(!entry.object["has_compaction"].boolean);
        assert(!entry.object["has_screen_capture"].boolean);
        foundUnknownLanguage = true;
    }
    assert(foundActivity);
    assert(foundUnknownLanguage);
    assert(!recent.canFind("Legacy transcript only"));
    assert(!recent.canFind(empty.sessionId));
    assert(!recent.canFind(memoryOnly.sessionId));
    assert(store.resumeProfileSession("tester", resumable.sessionId, "chat") == resumable);
    assertThrown!Exception(store.resumeProfileSession("other", resumable.sessionId, "chat"));

    store.markScheduledTurnUnseen(resumable, "scheduled-turn-1");
    assert(readText(buildPath(store.sessionRuntimeRoot(resumable), "session.json"))
        .canFind("unseen_scheduled_turn_ids"));
    assert(store.recentSessionsJson("tester").canFind(`"unseen_scheduled_turn_count":1`));
    store.markScheduledSessionSeen(resumable);
    assert(!store.recentSessionsJson("tester").canFind(`"unseen_scheduled_turn_count":1`));
    store.markScheduledSessionOrigin(resumable, "schedule_test", "occurrence_test");
    assert(store.recentSessionsJson("tester").canFind(`"automatic_session_unseen":true`));
    store.markScheduledSessionSeen(resumable);
    assert(!store.recentSessionsJson("tester").canFind(`"automatic_session_unseen":true`));

    auto added = store.startProfileSession(
        "tester",
        "2026-07-14T11:00:00.000000Z",
        "chat",
        "sk",
    );
    store.beginTextTurn(TextTurnRecord(
        "added-turn",
        "tester",
        added.sessionId,
        "browser",
        "browser_text",
        "",
        "2026-07-14T11:00:01.000000Z",
        "",
        "pi:test",
        "sk",
        "Nová otázka",
        "",
        "",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
    ));
    writeTextFile(
        buildPath(store.sessionRuntimeRoot(added), "pi_session.jsonl"),
        `{"type":"message","message":{"role":"user"}}` ~ "\n",
    );
    recent = store.recentSessionsJson("tester");
    assert(recent.indexOf("Nová otázka") < recent.indexOf("Full first prompt"));

    auto memoryPath = buildPath(profilesRoot, "tester", "memory_auto.md");
    writeTextFile(memoryPath, "keep memory\n");
    auto sourceRoot = store.sessionRuntimeRoot(resumable);
    store.deleteSession(resumable);
    assert(!exists(sourceRoot));
    assert(exists(buildPath(root, "Trash", "tester", resumable.sessionId, "session.json")));
    assert(readText(memoryPath) == "keep memory\n");
    assert(!store.recentSessionsJson("tester").canFind("Full first prompt"));
    assert(store.recentSessionsJson("tester").canFind("Nová otázka"));
    assertThrown!Exception(store.resumeProfileSession("tester", resumable.sessionId, "chat"));
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-branch-image-ids-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(profilesRoot, new AppConfigStore(configPath), root);
    auto source = store.startProfileSession(
        "tester", "2026-08-20T10:00:00.000000Z", "chat", "en",
    );
    store.saveTextTurn(TextTurnRecord(
        "image-turn", "tester", source.sessionId, "browser", "browser_text",
        "completed", "2026-08-20T10:00:01.000000Z",
        "2026-08-20T10:00:02.000000Z", "pi:test", "en",
        "Generate one image", "Done", "{}", false, 0, "", false,
        UserAudioArtifactRecord(), ReasoningMode.off,
    ));
    auto imagePaths = store.generatedImagePaths(source, "image-turn", "generated-01.png");
    mkdirRecurse(imagePaths.imagesRoot);
    write(imagePaths.imagePath, cast(ubyte[])[0]);
    writeJsonFile(imagePaths.metadataPath, generatedImageArtifactJson(GeneratedImageArtifact(
        1, "assistant:0:0", "generated-01.png", "image/png",
        "/image", imagePaths.artifactPath, "00", 1, 1, 1, 0,
        "medium", "square", "First image", "generated_image",
    )));
    store.saveTextTurn(TextTurnRecord(
        "branch-turn", "tester", source.sessionId, "browser", "browser_text",
        "completed", "2026-08-20T10:00:03.000000Z",
        "2026-08-20T10:00:04.000000Z", "pi:test", "en",
        "Continue", "Continued", "{}", false, 0, "", false,
        UserAudioArtifactRecord(), ReasoningMode.off,
    ));
    writeTextFile(
        buildPath(store.sessionRuntimeRoot(source), "pi_session.jsonl"),
        `{"type":"session","version":3,"id":"source","timestamp":"2026-08-20T10:00:00Z","cwd":"/tmp"}` ~ "\n"
        ~ `{"type":"message","id":"user-1","parentId":null,"timestamp":"2026-08-20T10:00:01Z","message":{"role":"user","content":[{"type":"text","text":"Generate one image"}]}}` ~ "\n"
        ~ `{"type":"message","id":"assistant-1","parentId":"user-1","timestamp":"2026-08-20T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]}}` ~ "\n"
        ~ `{"type":"message","id":"user-2","parentId":"assistant-1","timestamp":"2026-08-20T10:00:03Z","message":{"role":"user","content":[{"type":"text","text":"Continue"}]}}` ~ "\n"
        ~ `{"type":"message","id":"assistant-2","parentId":"user-2","timestamp":"2026-08-20T10:00:04Z","message":{"role":"assistant","content":[{"type":"text","text":"Continued"}]}}` ~ "\n",
    );

    auto branch = store.branchProfileSession(
        "tester", source.sessionId, "branch-turn", "user", "",
    );
    auto inherited = store.sessionGeneratedImages(branch);
    assert(inherited.length == 1 && inherited[0].generatedImageId == 1);
    auto nextTurn = store.beginTextTurn(TextTurnRecord(
        "next-image-turn", "tester", branch.sessionId, "browser", "browser_text",
        "pending", "2026-08-20T10:00:05.000000Z", "", "pi:test", "en",
        "Generate another image", "", "", false, 0, "", false,
        UserAudioArtifactRecord(), ReasoningMode.off,
    ));
    store.claimConversationTurn(branch, nextTurn);
    assert(store.nextGeneratedImageIndex(branch, nextTurn) == 2);
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-interrupted-turns-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(
        profilesRoot,
        new AppConfigStore(configPath),
        root,
    );
    auto session = store.startProfileSession(
        "tester",
        "2026-08-12T15:38:20.000000Z",
        "chat",
        "en",
    );
    auto turnId = store.beginTextTurn(TextTurnRecord(
        "pending-turn",
        "tester",
        session.sessionId,
        "web",
        "browser_text",
        "pending",
        "2026-08-12T15:40:25.000000Z",
        "",
        "pi:test",
        "en",
        "Question",
        "",
        "",
        false,
        0,
        "",
        false,
        UserAudioArtifactRecord(),
        ReasoningMode.off,
        false,
        "submission-1",
    ));

    auto completedAt = "2026-08-12T16:02:00.000000Z";
    auto message = "Conversation execution was interrupted.";
    auto turnJsonPath = buildPath(
        store.sessionRuntimeRoot(session),
        "turns",
        baseName(store.findTurn(session, turnId).turnRoot),
        "turn.json",
    );
    auto turnPayload = parseJSON(readText(turnJsonPath));
    turnPayload.object["metrics"] = JSONValue("legacy-invalid-metrics");
    write(turnJsonPath, turnPayload.toString());
    assert(store.failInterruptedConversationTurns(completedAt, message) == 1);
    auto recovered = parseJSON(readText(turnJsonPath));
    assert(jsonText(recovered, "status") == "failed");
    assert(jsonText(recovered, "completed_at") == completedAt);
    assert(readText(errorsJsonPath(dirName(turnJsonPath))).canFind(message));
    assert(store.failInterruptedConversationTurns(completedAt, message) == 0);
}

unittest
{
    auto root = buildPath(tempDir(), "wheatley-history-sync-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "Profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(profilesRoot, new AppConfigStore(configPath), root);
    assert(store.recentSessionsJson("tester") == "[]");

    auto incoming = buildPath(root, "incoming");
    auto sessionJson = buildPath(incoming, "session.json");
    auto turnJson = buildPath(incoming, "turn.json");
    auto turnMarkdownPath = buildPath(incoming, "turn.md");
    auto piJsonl = buildPath(incoming, "pi_session.jsonl");
    auto userOpus = buildPath(incoming, "user.opus");
    writeTextFile(sessionJson, `{"client":"offline","language":"en","model":"","reasoning_mode":"off"}`);
    writeTextFile(turnJson, `{"source":"offline","status":"completed","user_audio_required":true,"reasoning_mode":"off","completed_at":"2026-08-05T10:00:00.123456Z","metrics":{}}`);
    writeTextFile(turnMarkdownPath, turnMarkdown("first prompt", "first answer"));
    writeTextFile(
        piJsonl,
        `{"type":"session","version":3,"cwd":"/first"}` ~ "\n"
        ~ `{"type":"message","timestamp":"2026-08-05T10:00:00.123456Z","message":{"role":"user","content":[{"type":"text","text":"first prompt"}]}}` ~ "\n",
    );
    write(userOpus, cast(ubyte[]) [1, 2, 3]);

    auto first = CompletedTurnImport(
        "tester",
        "2026/08/05/10_00_00",
        "10_00_00_123456",
        sessionJson,
        turnJson,
        turnMarkdownPath,
        piJsonl,
        userOpus,
        "",
        "",
        "",
        true,
    );
    auto imported = store.importCompletedTurn(first);
    assert(imported.imported);
    auto session = SessionKey("tester", "2026/08/05/10_00_00");
    auto sessionRoot = store.sessionRuntimeRoot(session);
    auto firstTurnRoot = buildPath(sessionRoot, "turns", "10_00_00_123456");
    assert(exists(buildPath(firstTurnRoot, "user.opus")));
    assert(store.recentSessionsJson("tester").canFind("first prompt"));
    auto todoPath = buildPath(profilesRoot, "tester", "memory_auto_todo.md");
    auto todo = readText(todoPath);
    assert(todo.canFind("first prompt"));

    writeTextFile(todoPath, "");
    auto retried = store.importCompletedTurn(first);
    assert(!retried.imported);
    assert(readText(todoPath).canFind("first prompt"));
    todo = readText(todoPath);
    assert(!store.importCompletedTurn(first).imported);
    assert(readText(todoPath) == todo);
    assert(!exists(buildPath(sessionRoot, "pi_session_2.jsonl")));

    auto secondTurnJson = buildPath(incoming, "turn-2.json");
    auto secondTurnMarkdown = buildPath(incoming, "turn-2.md");
    auto secondPiJsonl = buildPath(incoming, "pi-session-2.jsonl");
    auto secondSessionJson = buildPath(incoming, "session-2.json");
    writeTextFile(secondTurnJson, `{"source":"offline","status":"completed","user_audio_required":false,"reasoning_mode":"off","completed_at":"2026-08-05T10:00:01.123456Z","metrics":{}}`);
    writeTextFile(secondTurnMarkdown, turnMarkdown("second prompt", "second answer"));
    writeTextFile(secondPiJsonl, `{"type":"session","version":3,"cwd":"/second"}` ~ "\n");
    writeTextFile(secondSessionJson, `{"client":"offline","language":"sk","model":"","reasoning_mode":"off"}`);
    auto collision = CompletedTurnImport(
        "tester",
        "2026/08/05/10_00_00",
        "10_00_01_123456",
        secondSessionJson,
        secondTurnJson,
        secondTurnMarkdown,
        secondPiJsonl,
        "",
        "",
        "",
        "",
        false,
    );
    assert(store.importCompletedTurn(collision).imported);
    assert(readText(buildPath(sessionRoot, "pi_session.jsonl")) == readText(piJsonl));
    assert(readText(buildPath(sessionRoot, "pi_session_2.jsonl")) == readText(secondPiJsonl));
    assert(Json.parse(readText(buildPath(sessionRoot, "session.json"))).text("language") == "en");
    assert(exists(buildPath(sessionRoot, "turns", "10_00_01_123456", "turn.md")));
    assert(readText(todoPath).canFind("second prompt"));

    auto thirdCollision = collision;
    thirdCollision.turnPath = "10_00_02_123456";
    assert(store.importCompletedTurn(thirdCollision).imported);
    assert(!exists(buildPath(sessionRoot, "pi_session_3.jsonl")));

    auto missingAudio = collision;
    missingAudio.turnPath = "10_00_03_123456";
    missingAudio.userAudioRequired = true;
    assertThrown!Exception(store.importCompletedTurn(missingAudio));
    assert(!exists(buildPath(sessionRoot, "turns", "10_00_03_123456")));
}
