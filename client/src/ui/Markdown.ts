import MarkdownIt from "markdown-it";

const markdown = new MarkdownIt({
    html: false,
    linkify: true,
    typographer: true,
});

export function renderMarkdown(source: string): DocumentFragment {
    const template = document.createElement("template");
    template.innerHTML = markdown.render(source);
    for (const code of template.content.querySelectorAll<HTMLElement>("pre > code"))
        highlightCode(code);
    return template.content;
}

function highlightCode(code: HTMLElement): void {
    const source = code.textContent;
    const pattern = new RegExp(
        "(//[^\\n]*|#[^\\n]*|\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'"
            + "|`(?:\\\\.|[^`\\\\])*`|\\b(?:true|false|null|undefined|class|struct|enum|function"
            + "|return|if|else|for|foreach|while|const|let|var|import|from|async|await|new|void"
            + "|private|public|final)\\b|-?\\d+(?:\\.\\d+)?)",
        "gu",
    );
    const fragment = document.createDocumentFragment();
    let offset = 0;
    for (const match of source.matchAll(pattern)) {
        const index = match.index;
        fragment.append(document.createTextNode(source.slice(offset, index)));
        const token = document.createElement("span");
        token.className = match[0].startsWith("//") || match[0].startsWith("#")
            ? "code-comment"
            : /^["'`]/u.test(match[0]) ? "code-string"
                : /^-?\d/u.test(match[0]) ? "code-number" : "code-keyword";
        token.textContent = match[0];
        fragment.append(token);
        offset = index + match[0].length;
    }
    fragment.append(document.createTextNode(source.slice(offset)));
    code.replaceChildren(fragment);
}

export function updateMarkdown(element: HTMLElement, source: string): void {
    const next = renderMarkdown(source);
    const currentNodes = [...element.childNodes];
    const nextNodes = [...next.childNodes];
    let stableCount = 0;
    while (
        stableCount < currentNodes.length
        && stableCount < nextNodes.length
        && currentNodes[stableCount]!.isEqualNode(nextNodes[stableCount]!)
    ) {
        stableCount++;
    }
    for (const node of currentNodes.slice(stableCount))
        node.remove();
    element.append(...nextNodes.slice(stableCount));
}
