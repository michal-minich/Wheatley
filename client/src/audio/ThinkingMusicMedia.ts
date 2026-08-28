import { Er } from "../core/Er";
import { JsonObject } from "../core/Json";
import type { WheatleyEndpoint } from "../transport/WheatleyEndpoint";

const CACHE_NAME = "wheatley-thinking-media-v1";
const MAX_CACHE_BYTES = 64 * 1024 * 1024;
const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]+$/u;

export interface MediaAssetRef {
    readonly code: string;
    readonly revision: string;
    readonly mediaType: "audio/mpeg";
    readonly sizeBytes: number;
    readonly sha256: string;
    readonly url: string;
}

export interface ThinkingMusicSelection {
    readonly asset: MediaAssetRef;
    readonly title: string;
    readonly gainDb: number;
}

export function parseThinkingMusicSelection(value: unknown): ThinkingMusicSelection {
    const json = JsonObject.from(value, "thinking music selection");
    const asset = json.object("asset");
    const code = asset.nonEmpty("code");
    const revision = asset.nonEmpty("revision");
    const mediaType = asset.choice("media_type", ["audio/mpeg"] as const);
    const sizeBytes = asset.positiveInteger("size_bytes", MAX_CACHE_BYTES);
    const sha256 = asset.nonEmpty("sha256");
    const url = asset.nonEmpty("url");
    if (!TOKEN_PATTERN.test(code))
        return Er.contract("thinking music selection.asset.code is invalid.");
    if (!TOKEN_PATTERN.test(revision))
        return Er.contract("thinking music selection.asset.revision is invalid.");
    if (!SHA256_PATTERN.test(sha256))
        return Er.contract("thinking music selection.asset.sha256 is invalid.");
    if (!url.startsWith("/api/"))
        return Er.contract("thinking music selection.asset.url must be a Wheatley API path.");
    return {
        asset: { code, revision, mediaType, sizeBytes, sha256, url },
        title: json.nonEmpty("title"),
        gainDb: json.number("gain_db", -120, 24),
    };
}

/**
 * Browser Cache Storage adapter for immutable reusable source media. The cache
 * identity is deliberately `code + sha256`, not a selected profile or ordinal.
 */
export class BrowserThinkingMusicCache {
    readonly #endpoint: WheatleyEndpoint;

    constructor(endpoint: WheatleyEndpoint) {
        this.#endpoint = endpoint;
    }

    async load(asset: MediaAssetRef, signal: AbortSignal): Promise<ArrayBuffer> {
        const cache = await this.#cache();
        const key = new Request(this.#cacheKey(asset));
        const cached = await cache.match(key);
        if (cached !== undefined) {
            try {
                const bytes = await cached.arrayBuffer();
                await verifyAsset(asset, bytes);
                await this.#store(cache, key, asset, bytes);
                return bytes;
            } catch {
                await cache.delete(key);
            }
        }

        const response = await fetch(this.#endpoint.resource(asset.url), {
            cache: "no-store",
            signal,
        });
        if (!response.ok)
            return Er.io(`Thinking music asset request failed with HTTP ${response.status}.`);
        const contentType = response.headers.get("Content-Type")?.split(";", 1)[0]?.trim();
        if (contentType !== asset.mediaType)
            return Er.contract("Thinking music asset media type does not match its reference.");
        const bytes = await response.arrayBuffer();
        await verifyAsset(asset, bytes);
        await this.#store(cache, key, asset, bytes);
        return bytes;
    }

    async #cache(): Promise<Cache> {
        return await globalThis.caches.open(CACHE_NAME);
    }

    #cacheKey(asset: MediaAssetRef): string {
        return new URL(
            `/__wheatley_media_cache__/${encodeURIComponent(asset.code)}/${asset.sha256}`,
            globalThis.location.href,
        ).href;
    }

    async #store(
        cache: Cache,
        key: Request,
        asset: MediaAssetRef,
        bytes: ArrayBuffer,
    ): Promise<void> {
        if (bytes.byteLength > MAX_CACHE_BYTES)
            return Er.contract("Thinking music asset exceeds the 64 MB cache limit.");

        const entries = await Promise.all((await cache.keys()).map(async request => ({
            request,
            response: await cache.match(request),
        })));
        let totalBytes = 0;
        const evictable: {
            readonly request: Request;
            readonly bytes: number;
            readonly accessedAt: number;
        }[] = [];
        for (const entry of entries) {
            if (entry.response === undefined)
                continue;
            const storedBytes = requiredStoredNumber(entry.response, "X-Wheatley-Media-Size");
            if (entry.request.url === key.url)
                continue;
            totalBytes += storedBytes;
            evictable.push({
                request: entry.request,
                bytes: storedBytes,
                accessedAt: requiredStoredNumber(entry.response, "X-Wheatley-Media-Accessed"),
            });
        }
        evictable.sort((left, right) => left.accessedAt - right.accessedAt);
        while (totalBytes + bytes.byteLength > MAX_CACHE_BYTES) {
            const oldest = evictable.shift();
            if (oldest === undefined)
                return Er.contract("Thinking music cache cannot make room for the asset.");
            await cache.delete(oldest.request);
            totalBytes -= oldest.bytes;
        }
        await cache.put(key, new Response(bytes.slice(0), {
            headers: {
                "Content-Type": asset.mediaType,
                "X-Wheatley-Media-Size": bytes.byteLength.toString(),
                "X-Wheatley-Media-Accessed": Date.now().toString(),
                "X-Wheatley-Media-Code": asset.code,
                "X-Wheatley-Media-Sha256": asset.sha256,
            },
        }));
    }
}

function requiredStoredNumber(response: Response, name: string): number {
    const value = Number(response.headers.get(name));
    if (!Number.isSafeInteger(value) || value < 0)
        return Er.contract(`Thinking music cache entry ${name} is invalid.`);
    return value;
}

async function verifyAsset(asset: MediaAssetRef, bytes: ArrayBuffer): Promise<void> {
    if (bytes.byteLength !== asset.sizeBytes)
        return Er.contract("Thinking music asset size does not match its reference.");
    const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
    const actual = [...new Uint8Array(digest)]
        .map(value => value.toString(16).padStart(2, "0"))
        .join("");
    if (actual !== asset.sha256)
        return Er.contract("Thinking music asset SHA-256 does not match its reference.");
}
