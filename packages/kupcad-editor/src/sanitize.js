// The server's documentation as the editor shows it (a hover, a completion's or a signature's
// docs): @codemirror/lsp-client renders its Markdown with marked, which passes the HTML in it
// through, and sets what comes out as innerHTML. A script's text the server repeats in it could
// then restyle the page or draw a form over it (the desktop app's CSP blocks scripts, not
// <style> or forms). What Markdown and the client's highlighter write is kept; any other
// element gives its text alone, and a link its text too: followed, one replaced the app's page.

/** The HTML namespace, the only one whose elements are kept. */
const HTML = 'http://www.w3.org/1999/xhtml';

/** The elements kept: what Markdown writes. */
const ELEMENTS = new Set(
  'p br hr h1 h2 h3 h4 h5 h6 blockquote ul ol li strong em del pre code span'.split(' '),
);
/**
 * The elements that keep their class, the one attribute kept: a code block's language, and the
 * highlighter's classes of its tokens.
 */
const CLASSED = new Set(['code', 'span']);

/**
 * `html` with only the elements and attributes Markdown writes: an inert copy, made from a
 * document that runs and loads nothing (DOMParser's).
 * @param {string} html
 * @returns {string}
 */
export function sanitizeHTML(html) {
  const parsed = new DOMParser().parseFromString(html, 'text/html');
  const clean = parsed.createElement('div');
  // What the parser took for the head's (a <style> first) as well as the body's
  for (const part of [parsed.head, parsed.body]) clean.append(...cleaned(part.childNodes, parsed));
  return clean.innerHTML;
}

/**
 * The nodes `nodes` are, cleaned, made in `document`: text as it is, a kept element with its
 * class where it keeps one, any other element as what it holds; comments and the rest dropped.
 * @param {NodeListOf<ChildNode>} nodes
 * @param {Document} document
 * @returns {Node[]}
 */
function cleaned(nodes, document) {
  return [...nodes].flatMap((node) => {
    if (node.nodeType === Node.TEXT_NODE) return [document.createTextNode(node.textContent ?? '')];
    if (node.nodeType !== Node.ELEMENT_NODE) return [];
    const element = /** @type {Element} */ (node);
    const held = cleaned(element.childNodes, document);
    if (element.namespaceURI !== HTML || !ELEMENTS.has(element.localName)) return held;
    const copy = document.createElement(element.localName);
    const classes = element.getAttribute('class');
    if (classes !== null && CLASSED.has(element.localName)) copy.setAttribute('class', classes);
    copy.append(...held);
    return [copy];
  });
}
