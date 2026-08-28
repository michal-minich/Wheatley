import { Er } from "../core/Er";

export class FluentElement<T extends HTMLElement> {
    readonly element: T;

    constructor(element: T) {
        this.element = element;
    }

    class(...names: string[]): this {
        this.element.classList.add(...names);
        return this;
    }

    attr(name: string, value: string): this {
        this.element.setAttribute(name, value);
        return this;
    }

    text(value: string): this {
        this.element.textContent = value;
        return this;
    }

    append(...children: Node[]): this {
        this.element.append(...children);
        return this;
    }

    on<K extends keyof HTMLElementEventMap>(
        type: K,
        handler: (event: HTMLElementEventMap[K]) => void,
    ): this {
        this.element.addEventListener(type, handler as EventListener);
        return this;
    }

    el(): T {
        return this.element;
    }
}

function tag<K extends keyof HTMLElementTagNameMap>(
    name: K,
): FluentElement<HTMLElementTagNameMap[K]> {
    return new FluentElement(document.createElement(name));
}

export const H = {
    single(selector: string): HTMLElement {
        return document.querySelector<HTMLElement>(selector)
            ?? Er.internal(`Missing ${selector} element.`);
    },

    div(): FluentElement<HTMLDivElement> {
        return tag("div");
    },

    span(): FluentElement<HTMLSpanElement> {
        return tag("span");
    },

    input(): FluentElement<HTMLInputElement> {
        return tag("input");
    },

    img(): FluentElement<HTMLImageElement> {
        return tag("img");
    },

    a(): FluentElement<HTMLAnchorElement> {
        return tag("a");
    },

    button(): FluentElement<HTMLButtonElement> {
        return tag("button");
    },

    select(): FluentElement<HTMLSelectElement> {
        return tag("select");
    },

    option(): FluentElement<HTMLOptionElement> {
        return tag("option");
    },

    header(): FluentElement<HTMLElement> {
        return tag("header");
    },

    section(): FluentElement<HTMLElement> {
        return tag("section");
    },

    main(): FluentElement<HTMLElement> {
        return tag("main");
    },

    h2(): FluentElement<HTMLHeadingElement> {
        return tag("h2");
    },

    singleChild<T extends HTMLElement>(parent: ParentNode, selector: string): T {
        return parent.querySelector<T>(selector)
            ?? Er.internal(`Missing ${selector} child.`);
    },

    textarea(): FluentElement<HTMLTextAreaElement> {
        return tag("textarea");
    },
};
