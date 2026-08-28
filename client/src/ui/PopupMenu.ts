import { H } from "./h";
import { icon } from "./Icons";

export type MenuItemRole = "menuitem" | "menuitemcheckbox" | "menuitemradio";

export interface PopupMenuOptions {
    readonly rootClass: string;
    readonly popoverClass: string;
    readonly role: "dialog" | "menu";
}

export class PopupMenu {
    readonly element: HTMLElement;
    readonly trigger: HTMLButtonElement;
    readonly popover: HTMLElement;
    #open = false;

    constructor(
        trigger: HTMLButtonElement,
        content: HTMLElement,
        options: PopupMenuOptions,
    ) {
        this.trigger = trigger;
        this.trigger.setAttribute("aria-haspopup", options.role);
        this.trigger.setAttribute("aria-expanded", "false");
        this.trigger.addEventListener("click", () => this.#setOpen(!this.#open));
        this.popover = H.div()
            .class("popup-menu-popover", options.popoverClass)
            .attr("role", options.role)
            .append(content)
            .el();
        this.popover.hidden = true;
        this.element = H.div()
            .class("popup-menu", options.rootClass)
            .append(this.trigger, this.popover)
            .el();

        document.addEventListener("click", event => {
            if (
                this.#open
                && event.target instanceof Node
                && !this.element.contains(event.target)
            )
                this.close();
        });
        document.addEventListener("keydown", event => {
            if (this.#open && event.key === "Escape") {
                this.close();
                this.trigger.focus();
            }
        });
        document.addEventListener("wheatley-popup-menu-open", event => {
            if (event instanceof CustomEvent && event.detail !== this)
                this.close();
        });
    }

    setLabel(label: string): void {
        this.trigger.title = label;
        this.trigger.setAttribute("aria-label", label);
    }

    setHidden(hidden: boolean): void {
        if (hidden)
            this.close();
        this.element.hidden = hidden;
    }

    close(): void {
        this.#setOpen(false);
    }

    #setOpen(open: boolean): void {
        this.#open = open;
        this.popover.hidden = !open;
        this.trigger.setAttribute("aria-expanded", String(open));
        if (open) {
            document.dispatchEvent(new CustomEvent("wheatley-popup-menu-open", {
                detail: this,
            }));
            this.#fitHorizontally();
            globalThis.requestAnimationFrame(() => {
                if (this.#open)
                    this.#fitHorizontally();
            });
        } else {
            this.popover.style.transform = "";
        }
    }

    #fitHorizontally(): void {
        const viewportInset = 12;
        this.popover.style.transform = "";
        const bounds = this.popover.getBoundingClientRect();
        const viewportWidth = document.documentElement.clientWidth;
        let shift = Math.min(0, viewportWidth - viewportInset - bounds.right);
        if (bounds.left + shift < viewportInset)
            shift += viewportInset - bounds.left - shift;
        if (shift !== 0)
            this.popover.style.transform = `translateX(${Math.round(shift)}px)`;
    }
}

export class MenuItemButton {
    readonly element: HTMLButtonElement;
    readonly #decorator: HTMLElement;
    readonly #label: HTMLElement;

    constructor(role: MenuItemRole, onSelect: () => void) {
        this.#decorator = H.span().class("popup-menu-item-decorator").el();
        this.#label = H.span().class("popup-menu-item-label").el();
        this.element = H.button()
            .class("popup-menu-item")
            .attr("type", "button")
            .attr("role", role)
            .append(this.#decorator, this.#label)
            .on("click", onSelect)
            .el();
    }

    setLabel(label: string): void {
        this.#label.textContent = label;
    }

    setTooltip(tooltip: string | undefined): void {
        if (tooltip === undefined)
            this.element.removeAttribute("title");
        else
            this.element.title = tooltip;
    }

    setDecorator(decorator: Node): void {
        this.#decorator.replaceChildren(decorator);
    }

    setChecked(checked: boolean): void {
        this.element.setAttribute("aria-checked", String(checked));
    }
}

export function menuIcon(source: string): HTMLElement {
    return H.span().class("popup-menu-icon").append(icon(source)).el();
}

export function menuCheckIcon(checked: boolean): HTMLElement {
    const result = menuIcon(
        checked ? "/icons/checkbox-checked.svg" : "/icons/checkbox-empty.svg",
    );
    result.classList.add("popup-menu-check-icon");
    return result;
}

export function menuTextIcon(text: string): HTMLElement {
    return H.span().class("popup-menu-text-icon").text(text).el();
}

/** Marks an action which opens a dialog or browser permission prompt. */
export function menuDialogLabel(label: string): string {
    return `${label}…`;
}
