type DetailValue = boolean | number | string;

export function browserVoiceEvent(
    turnId: string,
    event: string,
    detail: Readonly<Record<string, DetailValue>> = {},
): void {
    console.debug("Wheatley browser voice", {
        turn_id: turnId,
        event,
        monotonic_ms: Math.round(performance.now()),
        ...detail,
    });
}
