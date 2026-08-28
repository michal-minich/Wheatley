export function canKeepMicrophoneOn(
    playMusic: boolean,
    automaticallySpeak: boolean,
): boolean {
    return !playMusic && !automaticallySpeak;
}

export function keepMicrophoneOpenBetweenTurns(
    preference: boolean,
    playMusic: boolean,
    automaticallySpeak: boolean,
): boolean {
    return preference && canKeepMicrophoneOn(playMusic, automaticallySpeak);
}
