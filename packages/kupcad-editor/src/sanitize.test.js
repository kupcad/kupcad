import { describe, expect, it } from 'vitest';
import { sanitizeHTML } from './sanitize.js';

describe("the server's documentation, as HTML", () => {
  it('keeps what Markdown and the highlighter write', () => {
    const html =
      '<h3>width</h3><p><strong>Scope:</strong> <code>global</code>, <em>Enclosing</em></p>' +
      '<pre><code class="language-kupcad"><span class="ͼ1c">width</span> = 40<br></code></pre>' +
      '<ul><li>one</li></ul><ol><li>two</li></ol><blockquote>q</blockquote><hr><del>old</del>';
    expect(sanitizeHTML(html)).toBe(html);
  });

  it('gives any other element its text alone, and drops the rest', () => {
    const hostile = [
      '<style>body { display: none }</style>',
      '<form action="https://evil.example"><input name="password"><button>Sign in</button></form>',
      '<img src=x onerror="alert(1)">',
      '<a href="javascript:alert(1)">click</a>',
      '<a href="https://evil.example">here</a>',
      '<p style="position: fixed; inset: 0" onclick="alert(1)" id="x">over it all</p>',
      '<span class="ͼ1c" style="color: red">styled</span><em class="cm-tooltip">em</em>',
      '<svg><style>p { color: red }</style><circle onload="alert(1)"/></svg>',
      '<iframe src="https://evil.example"></iframe>',
      '<script>alert(1)</script>',
      '<!-- a comment -->',
      '<template><p>inert</p></template>',
    ].join('');
    expect(sanitizeHTML(hostile)).toBe(
      'body { display: none }Sign inclickhere<p>over it all</p><span class="ͼ1c">styled</span>' +
        '<em>em</em>' +
        'p { color: red }alert(1)',
    );
  });

  it("takes an element named as an Object property for one it doesn't know", () => {
    expect(sanitizeHTML('<constructor>a</constructor><toString>b</toString>')).toBe('ab');
  });
});
