import { H } from "./h";
import { icon } from "./Icons";

/** Shared controls used by the app's detail and editor surfaces. */
export function iconActionButton(source: string, onClick: () => void): HTMLButtonElement {
    return H.button()
        .class("chat-button", "chat-button-quiet", "instruction-action")
        .attr("type", "button")
        .append(icon(source))
        .on("click", onClick)
        .el();
}

export function detailField(label: string, control: HTMLElement): HTMLElement {
    const title = document.createElement("label");
    title.textContent = label;
    return H.div()
        .class("tool-detail-field")
        .append(title, control)
        .el();
}
