export function isNearBottom(element: HTMLElement): boolean {
    return element.scrollHeight - element.scrollTop - element.clientHeight <= 24;
}

export function reconcileChildren(parent: HTMLElement, desired: readonly HTMLElement[]): void {
    for (const [index, element] of desired.entries()) {
        const current = parent.children.item(index);
        if (current !== element)
            parent.insertBefore(element, current);
    }
    while (parent.children.length > desired.length)
        parent.lastElementChild!.remove();
}
