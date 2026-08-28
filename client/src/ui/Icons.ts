export function waveformIcon(): HTMLImageElement {
    const image = icon("/icons/waveform.svg");
    image.classList.add("chat-button-icon-waveform");
    return image;
}

export function sendIcon(): HTMLImageElement {
    return icon("/icons/paper-airplane.svg");
}

export function composerCancelIcon(): HTMLImageElement {
    return icon("/icons/composer-cancel.svg");
}

export function imageIcon(): HTMLImageElement {
    return icon("/icons/image.svg");
}

export function icon(source: string): HTMLImageElement {
    const image = document.createElement("img");
    image.classList.add("chat-button-icon");
    image.src = source;
    image.alt = "";
    image.setAttribute("aria-hidden", "true");
    return image;
}
