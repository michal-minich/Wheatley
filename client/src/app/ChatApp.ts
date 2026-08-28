import { WheatleyApi } from "../transport/WheatleyApi";
import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";
import type { ChatLanguage } from "../chat/Language";
import { H } from "../ui/h";
import {
    connectionUnavailableText,
    installTranslation,
} from "../ui/UiText";
import { ClientConfig } from "./ClientConfig";
import { ChatRuntime } from "./ChatRuntime";

export class ChatApp {
    readonly #root: HTMLElement;
    readonly #endpoint: WheatleyEndpoint;
    readonly #api: WheatleyApi;

    constructor(root: HTMLElement, endpoint: WheatleyEndpoint) {
        this.#root = root;
        this.#endpoint = endpoint;
        this.#api = new WheatleyApi(endpoint);
    }

    async start(): Promise<void> {
        let language: ChatLanguage = "en";
        try {
            const [english, slovak] = await Promise.all([
                this.#api.loadTranslation("en"),
                this.#api.loadTranslation("sk"),
            ]);
            installTranslation("en", english);
            installTranslation("sk", slovak);
            const [savedClientConfig, profiles, models] = await Promise.all([
                this.#api.loadClientConfig(),
                this.#api.loadProfiles(),
                this.#api.loadModels(),
            ]);
            const clientConfig = new ClientConfig(
                savedClientConfig,
                async value => await this.#api.saveClientConfig(value),
            );
            language = clientConfig.lastUsedLanguage;
            const profileId = clientConfig.selectAvailableProfile(profiles);
            const configuredProfiles = clientConfig.configuredProfiles(profiles);
            clientConfig.selectAvailableModel(models);
            const startup = await this.#api.loadStartupState(
                profileId,
                clientConfig.language,
            );
            clientConfig.setLanguage(startup.language);
            new ChatRuntime(
                this.#root,
                this.#api,
                this.#endpoint,
                clientConfig,
                configuredProfiles,
                models,
                startup,
            );
        } catch (error: unknown) {
            console.error("Wheatley chat startup failed", error);
            document.documentElement.lang = language;
            this.#root.replaceChildren(H.div()
                .class("chat-startup-error")
                .text(connectionUnavailableText(language))
                .el());
        }
    }
}
