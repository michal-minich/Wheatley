import { H } from "./h";

export type MessageActionName = "playback" | "copy" | "branch" | "cancel";

export function messageActionBar(): HTMLElement {
    return H.div().class("message-actions").el();
}

export function syncMessageAction(
    actions: HTMLElement,
    name: MessageActionName,
    iconPath: string,
    label: string,
    onClick: () => void,
): HTMLButtonElement {
    let button = actions.querySelector<HTMLButtonElement>(
        `[data-message-action="${name}"]`,
    );
    if (button === null) {
        const icon = document.createElement("img");
        icon.alt = "";
        icon.setAttribute("aria-hidden", "true");
        button = H.button()
            .class("message-action-button")
            .attr("type", "button")
            .attr("data-message-action", name)
            .append(icon)
            .el();
        actions.append(button);
    }

    const icon = button.querySelector<HTMLImageElement>("img")!;
    if (icon.getAttribute("src") !== iconPath)
        icon.src = iconPath;
    button.ariaLabel = label;
    button.title = label;
    button.onclick = onClick;
    return button;
}
