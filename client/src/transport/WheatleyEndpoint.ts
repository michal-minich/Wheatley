import { Er } from "../core/Er";

export class WheatleyEndpoint {
    readonly #apiBase: URL;

    constructor(apiBase: string) {
        const url = new URL(apiBase, globalThis.location.href);
        if (url.protocol !== "http:" && url.protocol !== "https:")
            Er.contract(`Wheatley API protocol ${url.protocol} is unsupported.`);
        url.pathname = url.pathname.replace(/\/$/u, "");
        this.#apiBase = url;
    }

    api(path: string): string {
        this.#requirePath(path);
        return `${this.#apiBase.href}${path}`;
    }

    resource(url: string): string {
        return new URL(url, this.#apiBase).href;
    }

    webSocket(path: string): string {
        const url = new URL(this.api(path));
        url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
        return url.href;
    }

    #requirePath(path: string): void {
        if (!path.startsWith("/"))
            Er.internal(`Wheatley API path must start with /: ${path}`);
    }
}

export function configuredWheatleyEndpoint(): WheatleyEndpoint {
    return new WheatleyEndpoint(import.meta.env.VITE_WHEATLEY_API_BASE ?? "/api");
}
