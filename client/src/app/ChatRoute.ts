export interface ChatRoute {
    readonly profileId: string;
    readonly sessionId: string;
}

const sessionIdPattern = /^(\d{4})\/(\d{2})\/(\d{2})\/(\d{2}_\d{2}_\d{2}(?:_[A-Za-z0-9]+)?)$/;
const chatPathPattern = new RegExp(
    "^/chat/([^/]+)/(\\d{4})-(\\d{2})-(\\d{2})-"
        + "(\\d{2}_\\d{2}_\\d{2}(?:_[A-Za-z0-9]+)?)/?$",
);

export function chatPath(profileId: string, sessionId: string): string {
    const match = sessionIdPattern.exec(sessionId);
    if (match === null)
        throw new Error(`Unsupported session ID for chat URL: ${sessionId}`);
    return `/chat/${encodeURIComponent(profileId)}/${match.slice(1).join("-")}`;
}

export function parseChatPath(pathname: string): ChatRoute | undefined {
    const match = chatPathPattern.exec(pathname);
    if (match === null)
        return undefined;
    const [, encodedProfile, year, month, day, time] = match;
    return {
        profileId: decodeURIComponent(encodedProfile!),
        sessionId: `${year!}/${month!}/${day!}/${time!}`,
    };
}

export function isUnmodifiedLeftClick(event: MouseEvent): boolean {
    return event.button === 0
        && !event.metaKey
        && !event.ctrlKey
        && !event.shiftKey
        && !event.altKey;
}
