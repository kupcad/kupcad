import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/** This folder, src/, as a path: jsdom's URL is no file URL to node:fs's readdir. */
const HERE = dirname(fileURLToPath(import.meta.url));
const read = (/** @type {string} */ name) => readFileSync(join(HERE, name), 'utf8');
const TOKENS = read('tokens.css');

/** The --kc-* declarations of a block of CSS, by name. @param {string} block */
const declarations = (block) =>
  Object.fromEntries([...block.matchAll(/(--kc-[\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2]]));

const light = declarations(/^:root \{([^}]*)\}/m.exec(TOKENS)?.[1] ?? '');
const dark = {
  ...light,
  ...declarations(
    /@media \(prefers-color-scheme: dark\) \{\s*:root \{([^}]*)\}/.exec(TOKENS)?.[1] ?? '',
  ),
};

/** The relative luminance of a #rrggbb colour (WCAG 2). @param {string} hex */
function luminance(hex) {
  const [r, g, b] = [1, 3, 5].map((at) => {
    const channel = parseInt(hex.slice(at, at + 2), 16) / 255;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** The contrast of two #rrggbb colours (WCAG 2). @param {string} a @param {string} b */
function contrast(a, b) {
  const [high, low] = [luminance(a), luminance(b)].toSorted((x, y) => y - x);
  return (high + 0.05) / (low + 0.05);
}

/** Text: 4.5:1 (WCAG AA). [what, on what] */
const TEXT = [
  ['--kc-fg', '--kc-bg'],
  ['--kc-fg', '--kc-input-bg'],
  ['--kc-fg', '--kc-accent-subtle'],
  ['--kc-muted', '--kc-bg'],
  ['--kc-muted', '--kc-accent-subtle'],
  ['--kc-muted', '--kc-section-bg'],
  ['--kc-section-fg', '--kc-section-bg'],
  ['--kc-accent-fg', '--kc-accent'],
  ['--kc-accent-fg', '--kc-accent-hover'],
  ['--kc-accent-text', '--kc-bg'],
  ['--kc-accent-text', '--kc-input-bg'],
  ['--kc-error', '--kc-bg'],
  ['--kc-warning', '--kc-bg'],
];
/** A control's edge, a focus ring, a fill that is a control: 3:1 (WCAG AA, non-text). */
const EDGES = [
  ['--kc-control-border', '--kc-bg'],
  ['--kc-control-border', '--kc-input-bg'],
  ['--kc-focus', '--kc-bg'],
  ['--kc-accent', '--kc-bg'],
];

describe.each([
  ['light', light],
  ['dark', dark],
])('the %s tokens', (_scheme, tokens) => {
  /** @param {string} name */
  const colour = (name) => {
    const value = tokens[/** @type {keyof typeof tokens} */ (name)];
    expect(value, `${name} is a #rrggbb colour`).toMatch(/^#[\da-f]{6}$/i);
    return value;
  };

  it.each(TEXT)('keep %s readable as text on %s, 4.5:1', (fg, bg) => {
    expect(contrast(colour(fg), colour(bg))).toBeGreaterThanOrEqual(4.5);
  });

  it.each(EDGES)('keep %s apart from %s, 3:1', (fg, bg) => {
    expect(contrast(colour(fg), colour(bg))).toBeGreaterThanOrEqual(3);
  });
});

it('measures contrast as WCAG does', () => {
  expect(contrast('#000000', '#ffffff')).toBeCloseTo(21, 5);
  // The brand orange: white on it is too faint for text, the brand black is not
  expect(contrast('#ffffff', '#ff5f14')).toBeCloseTo(3.04, 2);
  expect(contrast('#1a1b1c', '#ff5f14')).toBeCloseTo(5.67, 2);
});

/** What tokens.css gives no value: the viewer's (its own colours stand in), the code's (the editor's), a slider's fill (set by the panel). */
const SET_ELSEWHERE = /^--kc-(viewer-|code-|range-fill$)/;

it('defines every token the panels use', () => {
  const sources = readdirSync(HERE).filter(
    (name) => /\.(svelte|js|css)$/.test(name) && !name.includes('.test.'),
  );
  const used = new Set(
    sources.flatMap((name) => [...read(name).matchAll(/var\((--kc-[\w-]+)/g)].map((m) => m[1])),
  );
  const undefinedTokens = [...used].filter((name) => !(name in light) && !SET_ELSEWHERE.test(name));
  expect(undefinedTokens).toEqual([]);
});

it("maps every colour token to VS Code's, so the brand never shows in its webview", () => {
  const mapped = declarations(read('vscode.css'));
  const colours = Object.keys(light).filter(
    (name) => !/^--kc-(font|font-size|radius|gap)$/.test(name),
  );
  expect(colours.filter((name) => !(name in mapped))).toEqual([]);
});
