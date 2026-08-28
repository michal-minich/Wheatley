import { H } from "./h";

export interface SegmentedTabOption<Id extends string> {
    readonly id: Id;
    readonly label: string;
}

export class SegmentedTabs<Id extends string> {
    readonly element: HTMLElement;
    readonly #group: HTMLElement;
    readonly #onSelect: (id: Id) => void;

    constructor(onSelect: (id: Id) => void) {
        this.#onSelect = onSelect;
        this.#group = H.div()
            .class("segmented-tabs")
            .attr("role", "tablist")
            .el();
        this.element = H.div()
            .class("segmented-tabs-scroll")
            .append(this.#group)
            .el();
    }

    render(
        options: readonly SegmentedTabOption<Id>[],
        activeId: Id,
        disabled: boolean,
    ): void {
        this.#group.replaceChildren(...options.map(option => {
            const active = option.id === activeId;
            const button = H.button()
                .class(
                    "chat-button",
                    "chat-button-quiet",
                    "segmented-tab",
                    "toggle-selection",
                )
                .attr("type", "button")
                .attr("role", "tab")
                .attr("aria-selected", String(active))
                .text(option.label)
                .on("click", () => this.#onSelect(option.id))
                .el();
            button.disabled = disabled;
            return button;
        }));
    }
}
