import { Er } from "../core/Er";
import type { ChatLanguage } from "../chat/Language";
import { accent, findAccentId, type Accent, type AccentId } from "../theme/Accents";
import type {
    ModelCatalog,
    ClientConfigData,
    ProfileSummary,
    ReasoningMode,
} from "../transport/ChatTransport";

interface ProfileClientConfig {
    readonly accentId: AccentId;
    readonly autoSpeak: boolean;
    readonly playMusic: boolean;
    readonly keepMicrophoneOn: boolean;
    readonly language: ChatLanguage | "";
    readonly reasoningMode: ReasoningMode;
    readonly activityPaneOpen: boolean;
    readonly showThinking: boolean;
    readonly showCompactedContext: boolean;
    readonly modelId: string;
}

type SaveClientConfig = (config: ClientConfigData) => Promise<void>;

export class ClientConfig {
    #lastUsedProfileId: string;
    #speechCommitDelaySeconds: number;
    readonly #outputRecoveryMs: number;
    readonly #thinkingMusicFadeInMs: number;
    readonly #thinkingMusicFadeOutMs: number;
    readonly #profiles: Map<string, ProfileClientConfig>;
    readonly #saveConfig: SaveClientConfig;
    #saveQueue = Promise.resolve();

    constructor(saved: ClientConfigData, saveConfig: SaveClientConfig) {
        if (saved.profiles.length === 0)
            Er.contract("Client config must include at least one profile.");
        this.#lastUsedProfileId = saved.lastUsedProfileId;
        this.#speechCommitDelaySeconds = saved.speechCommitDelaySeconds;
        this.#outputRecoveryMs = saved.outputRecoveryMs;
        this.#thinkingMusicFadeInMs = saved.thinkingMusicFadeInMs;
        this.#thinkingMusicFadeOutMs = saved.thinkingMusicFadeOutMs;
        this.#saveConfig = saveConfig;
        this.#profiles = new Map();
        for (const profile of saved.profiles) {
            const accentId = findAccentId(profile.accentId)
                ?? Er.contract(`Unknown accent ${profile.accentId}.`);
            this.#profiles.set(profile.profileId, {
                accentId,
                autoSpeak: profile.autoSpeak,
                playMusic: profile.playMusic,
                keepMicrophoneOn: profile.keepMicrophoneOn,
                language: profile.language,
                reasoningMode: profile.reasoningMode,
                activityPaneOpen: profile.activityPaneOpen,
                showThinking: profile.showThinking,
                showCompactedContext: profile.showCompactedContext,
                modelId: profile.modelId,
            });
        }
        if (!this.#profiles.has(this.#lastUsedProfileId))
            Er.contract(`Last used profile ${this.#lastUsedProfileId} has no client config.`);
    }

    get profileId(): string {
        return this.#lastUsedProfileId;
    }

    get speechCommitDelaySeconds(): number {
        return this.#speechCommitDelaySeconds;
    }

    setSpeechCommitDelaySeconds(seconds: number): void {
        if (this.#speechCommitDelaySeconds === seconds)
            return;
        this.#speechCommitDelaySeconds = seconds;
        this.#save();
    }

    get outputRecoveryMs(): number {
        return this.#outputRecoveryMs;
    }

    get thinkingMusicFadeInMs(): number {
        return this.#thinkingMusicFadeInMs;
    }

    get thinkingMusicFadeOutMs(): number {
        return this.#thinkingMusicFadeOutMs;
    }

    get autoSpeak(): boolean {
        return this.#profile().autoSpeak;
    }

    get language(): ChatLanguage | "" {
        return this.#profile().language;
    }

    get playMusic(): boolean {
        return this.#profile().playMusic;
    }

    get keepMicrophoneOn(): boolean {
        return this.#profile().keepMicrophoneOn;
    }

    get lastUsedLanguage(): ChatLanguage {
        const language = this.#profiles.get(this.#lastUsedProfileId)?.language;
        return language === undefined || language === "" ? "en" : language;
    }

    get reasoningMode(): ReasoningMode {
        return this.#profile().reasoningMode;
    }

    get activityPaneOpen(): boolean {
        return this.#profile().activityPaneOpen;
    }

    get showThinking(): boolean {
        return this.#profile().showThinking;
    }

    get showCompactedContext(): boolean {
        return this.#profile().showCompactedContext;
    }

    get modelId(): string {
        const modelId = this.#profile().modelId;
        return modelId.length > 0
            ? modelId
            : Er.internal(`Profile ${this.#lastUsedProfileId} has no selected model.`);
    }

    selectAvailableProfile(profiles: readonly ProfileSummary[]): string {
        const configured = this.configuredProfiles(profiles);
        if (configured.length === 0)
            return Er.contract("No available profiles have client config.");
        const selected = configured.find(profile => profile.id === this.#lastUsedProfileId)
            ?? configured[0]!;
        this.#lastUsedProfileId = selected.id;
        this.#save();
        return selected.id;
    }

    configuredProfiles(profiles: readonly ProfileSummary[]): readonly ProfileSummary[] {
        return profiles.filter(profile => this.#profiles.has(profile.id));
    }

    selectProfile(profileId: string): void {
        if (!this.#profiles.has(profileId))
            return Er.contract(`Profile ${profileId} has no client config.`);
        this.#lastUsedProfileId = profileId;
        this.#save();
    }

    selectAvailableModel(catalog: ModelCatalog): string {
        const profile = this.#profile();
        const fallback = catalog.models.find(candidate => candidate.id === catalog.defaultModelId)
            ?? Er.internal(`Default model ${catalog.defaultModelId} is unavailable.`);
        const model = catalog.models.find(candidate => candidate.id === profile.modelId)
            ?? fallback;
        this.#patchProfile({ modelId: model.id });
        return model.id;
    }

    get accent(): Accent {
        return accent(this.#profile().accentId);
    }

    setAccent(id: AccentId): void {
        this.#patchProfile({ accentId: id });
    }

    setAutoSpeak(enabled: boolean): void {
        this.#patchProfile({ autoSpeak: enabled });
    }

    setPlayMusic(enabled: boolean): void {
        this.#patchProfile({ playMusic: enabled });
    }

    setKeepMicrophoneOn(enabled: boolean): void {
        this.#patchProfile({ keepMicrophoneOn: enabled });
    }

    setLanguage(language: ChatLanguage): void {
        this.#patchProfile({ language });
    }

    setReasoningMode(reasoningMode: ReasoningMode): void {
        this.#patchProfile({ reasoningMode });
    }

    setActivityPaneOpen(activityPaneOpen: boolean): void {
        this.#patchProfile({ activityPaneOpen });
    }

    setShowThinking(showThinking: boolean): void {
        this.#patchProfile({ showThinking });
    }

    setShowCompactedContext(showCompactedContext: boolean): void {
        this.#patchProfile({ showCompactedContext });
    }

    setModel(modelId: string): void {
        this.#patchProfile({ modelId });
    }

    #profile(): ProfileClientConfig {
        return this.#profiles.get(this.#lastUsedProfileId)
            ?? Er.internal(`Profile ${this.#lastUsedProfileId} has no client config.`);
    }

    #patchProfile(patch: Partial<ProfileClientConfig>): void {
        const profile = this.#profile();
        this.#saveProfile({
            accentId: patch.accentId ?? profile.accentId,
            autoSpeak: patch.autoSpeak ?? profile.autoSpeak,
            playMusic: patch.playMusic ?? profile.playMusic,
            keepMicrophoneOn: patch.keepMicrophoneOn ?? profile.keepMicrophoneOn,
            language: patch.language ?? profile.language,
            reasoningMode: patch.reasoningMode ?? profile.reasoningMode,
            activityPaneOpen: patch.activityPaneOpen ?? profile.activityPaneOpen,
            showThinking: patch.showThinking ?? profile.showThinking,
            showCompactedContext: patch.showCompactedContext ?? profile.showCompactedContext,
            modelId: patch.modelId ?? profile.modelId,
        });
    }

    #saveProfile(profile: ProfileClientConfig): void {
        this.#profiles.set(this.#lastUsedProfileId, profile);
        this.#save();
    }

    #save(): void {
        const snapshot = this.#snapshot();
        this.#saveQueue = this.#saveQueue
            .catch(() => undefined)
            .then(async () => await this.#saveConfig(snapshot))
            .catch((error: unknown) => console.error("Saving client config failed", error));
    }

    #snapshot(): ClientConfigData {
        return {
            lastUsedProfileId: this.#lastUsedProfileId,
            speechCommitDelaySeconds: this.#speechCommitDelaySeconds,
            outputRecoveryMs: this.#outputRecoveryMs,
            thinkingMusicFadeInMs: this.#thinkingMusicFadeInMs,
            thinkingMusicFadeOutMs: this.#thinkingMusicFadeOutMs,
            profiles: [...this.#profiles].map(([profileId, profile]) => ({
                profileId,
                accentId: profile.accentId,
                autoSpeak: profile.autoSpeak,
                playMusic: profile.playMusic,
                keepMicrophoneOn: profile.keepMicrophoneOn,
                language: profile.language,
                reasoningMode: profile.reasoningMode,
                activityPaneOpen: profile.activityPaneOpen,
                showThinking: profile.showThinking,
                showCompactedContext: profile.showCompactedContext,
                modelId: profile.modelId,
            })),
        };
    }
}
