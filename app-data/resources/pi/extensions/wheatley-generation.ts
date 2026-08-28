import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function configureWheatleyGeneration(pi: ExtensionAPI): void {
    const raw = process.env["WHEATLEY_PROVIDER_REQUEST_JSON"]?.trim();
    if (!raw) throw new Error("WHEATLEY_PROVIDER_REQUEST_JSON is required.");
    const parsed: unknown = JSON.parse(raw);
    if (!isObject(parsed))
        throw new Error("WHEATLEY_PROVIDER_REQUEST_JSON must contain an object.");
    pi.on("before_provider_request", (event) => {
        if (!isObject(event.payload))
            throw new Error("Provider payload must be an object.");
        return { ...event.payload, ...parsed };
    });
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
