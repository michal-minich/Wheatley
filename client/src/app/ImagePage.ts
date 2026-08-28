import { chatPath } from "./ChatRoute";

export type ImagePageKind = "screenshot" | "generated-image" | "search-image";

export function imagePageUrl(
    resourceUrl: string,
    profileId: string,
    sessionId: string,
    kind: ImagePageKind,
    index: number,
): string {
    if (!Number.isSafeInteger(index) || index < 1)
        throw new Error(`Invalid image page index: ${index}`);
    const path = `${chatPath(profileId, sessionId)}/${kind}/${String(index).padStart(2, "0")}`;
    return publicImageUrl(resourceUrl, path);
}

export function uploadedImagePageUrl(
    resourceUrl: string,
    profileId: string,
    sessionId: string,
    filename: string,
    occurrence: number,
): string {
    const path = `${chatPath(profileId, sessionId)}/image/${String(occurrence)}/`
        + encodeURIComponent(filename);
    return publicImageUrl(resourceUrl, path);
}

function publicImageUrl(resourceUrl: string, path: string): string {
    const resource = new URL(resourceUrl, globalThis.location.href);
    return resource.origin === globalThis.location.origin
        ? path
        : new URL(path, resource.origin).href;
}
