export interface LinkedImageFrameOptions {
    readonly url: string;
    readonly pageUrl?: string;
    readonly alt: string;
    readonly title?: string;
    readonly frameClass: string;
    readonly imageClass: string;
    readonly width?: number;
    readonly height?: number;
    readonly lazy?: boolean;
}

export function linkedImageFrame(options: LinkedImageFrameOptions): HTMLAnchorElement {
    const image = document.createElement("img");
    image.classList.add("image-presentation-image", options.imageClass);
    image.src = options.url;
    image.alt = options.alt;
    if (options.width !== undefined) image.width = options.width;
    if (options.height !== undefined) image.height = options.height;
    if (options.lazy === true) image.loading = "lazy";

    const link = document.createElement("a");
    link.classList.add("image-presentation-frame", options.frameClass);
    link.href = options.pageUrl ?? options.url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    if (options.title !== undefined) link.title = options.title;
    link.append(image);
    return link;
}

export function imagePresentationText(
    text: string,
    className: string,
    href?: string,
): HTMLElement {
    const element = document.createElement(href === undefined ? "div" : "a");
    element.classList.add("image-presentation-text", className);
    element.textContent = text;
    element.title = text;
    if (element instanceof HTMLAnchorElement) {
        element.href = href!;
        element.target = "_blank";
        element.rel = "noopener noreferrer";
    }
    return element;
}
