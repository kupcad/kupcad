import { forEachDiagnostic } from '@codemirror/lint';
import { EditorView } from '@codemirror/view';
import { fireEvent, render, screen } from '@testing-library/svelte';
import { stubRenderer } from '@kupcad/viewer/testing';
import { testCore } from '@kupcad/wasm/testing';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { memorySettings } from '@kupcad/ui';
import Playground from './Playground.svelte';

/** How long a run may take here: the pause after an edit, then the real core's. */
const RUN_MS = 5000;

afterEach(() => vi.restoreAllMocks());

/**
 * The playground on `source`, run by the real core in this thread, and its editor's view.
 * @param {string} source
 * @param {import('@kupcad/ui').Settings} [settings] where its panes' sizes are kept
 */
async function playground(source, settings = memorySettings()) {
  const kupcad = await testCore();
  render(Playground, {
    props: {
      source,
      kupcad,
      name: 'bracket',
      viewerOptions: { renderer: stubRenderer().renderer, motionMs: 0 },
      settings,
    },
  });
  const view = /** @type {EditorView} */ (
    EditorView.findFromDOM(/** @type {HTMLElement} */ (document.querySelector('.cm-editor')))
  );
  return { kupcad, view };
}

/** The status line's words. */
const statusText = () => screen.queryByRole('status')?.textContent?.replace(/\s+/g, ' ').trim();

/**
 * The parts listed beside the model.
 */
const partsListed = () =>
  screen.queryByRole('list', { name: 'Parts' })?.textContent?.replace(/\s+/g, ' ').trim();

/** The console's lines, as they read. */
const consoleLines = () =>
  [...screen.getByRole('log').querySelectorAll('li')].map((li) =>
    li.textContent?.replace(/\s+/g, ' ').trim(),
  );

/**
 * What the editor marks: each mark's message and the text it marks.
 * @param {EditorView} view
 */
function marksIn(view) {
  /** @type {string[]} */
  const marks = [];
  forEachDiagnostic(view.state, (d, from, to) =>
    marks.push(`${d.severity} ${view.state.doc.sliceString(from, to)}: ${d.message}`),
  );
  return marks;
}

describe('Playground', () => {
  it('runs the script it starts with: its model, its parts, how it went', async () => {
    await playground('cube(10).named("box")\n');
    await vi.waitFor(() => expect(statusText()).toMatch(/^Ready · \d+ ms$/), RUN_MS);
    expect(partsListed()).toBe('box');
  });

  it('marks what check finds and where the run failed; a problem clicked takes the editor there', async () => {
    const { view } = await playground('unused = 1\nraise "boom"\n');
    await vi.waitFor(() => expect(marksIn(view)).toHaveLength(2), RUN_MS);
    expect(marksIn(view)).toEqual([
      expect.stringMatching(/^warning unused: Unused variable 'unused'/),
      'error : RuntimeError: boom',
    ]);
    expect(statusText()).toMatch(/^Failed/);
    const problem = /** @type {HTMLElement} */ (
      screen.getByRole('list', { name: 'Problems' }).querySelector('button')
    );
    await fireEvent.click(problem);
    expect(view.state.selection.main.head).toBe(view.state.doc.line(2).from);
  });

  it('keeps what each run printed in the console under the model, a line of it taking the editor there', async () => {
    const { view } = await playground('puts "made"\ncube(1)\nraise "boom"\n');
    await vi.waitFor(() => expect(consoleLines()).toHaveLength(3), RUN_MS);
    expect(consoleLines()).toEqual([
      expect.stringMatching(/^bracket: Failed · \d+ ms$/),
      'made',
      'Error: RuntimeError: boom line 3',
    ]);
    await fireEvent.click(screen.getByRole('button', { name: /Error: RuntimeError: boom/ }));
    expect(view.state.selection.main.head).toBe(view.state.doc.line(3).from);
  });

  it('lays its panes out as its settings keep them, and keeps what the person changes', async () => {
    const settings = memorySettings({ 'playground.editor': 500 });
    await playground('cube(10)\n', settings);
    const script = /** @type {HTMLElement} */ (document.querySelector('.kc-playground'));
    expect(script.style.getPropertyValue('--editor-width')).toBe('500px');
    await fireEvent.keyDown(screen.getByRole('separator', { name: 'Resize the script' }), {
      key: 'ArrowRight',
    });
    expect(settings.get('playground.editor')).toBe(516);
  });

  it("hides the parameters and the view's panel by the toolbar's toggles, and keeps that", async () => {
    const settings = memorySettings({ 'playground.paramsOpen': false });
    await playground('w = param(:w, default: 10)\ncube(w)\n', settings);
    const toggle = await vi.waitFor(
      () => screen.getByRole('button', { name: 'Parameters' }),
      RUN_MS,
    );
    // Hidden as the settings keep it: no column, no bar to resize it
    expect(toggle.getAttribute('aria-expanded')).toBe('false');
    expect(screen.queryByRole('complementary', { name: 'Parameters' })).toBeNull();
    expect(screen.queryByRole('separator', { name: 'Resize the parameters' })).toBeNull();
    await fireEvent.click(toggle);
    expect(screen.getByRole('complementary', { name: 'Parameters' })).toBeTruthy();
    expect(settings.get('playground.paramsOpen')).toBe(true);
    await fireEvent.click(screen.getByRole('button', { name: 'Panel' }));
    expect(screen.queryByRole('complementary', { name: 'View and parts' })).toBeNull();
    expect(settings.get('playground.panelOpen')).toBe(false);
  });

  it('runs the script again once an edit stays a moment', async () => {
    const { view } = await playground('cube(10).named("box")\n');
    await vi.waitFor(() => expect(partsListed()).toBe('box'), RUN_MS);
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: 'cube(4).named("lid")\n' },
    });
    await vi.waitFor(() => expect(partsListed()).toBe('lid'), RUN_MS);
  });

  it('runs again at once with the value the parameter panel gives', async () => {
    const { kupcad } = await playground(
      'w = param(:w, default: 10, validate: { min: 1, max: 50 })\ncube(w).named("box")\n',
    );
    const preview = vi.spyOn(kupcad, 'preview');
    const field = await vi.waitFor(() => screen.getByLabelText('w'), RUN_MS);
    await fireEvent.change(field, { target: { value: '20' } });
    await vi.waitFor(
      () =>
        expect(preview).toHaveBeenCalledWith(
          expect.any(String),
          expect.objectContaining({ params: { w: 20 } }),
        ),
      RUN_MS,
    );
  });

  it("exports the model in the format chosen, and says why one wasn't made", async () => {
    /** @type {string[]} */
    const saved = [];
    vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:model');
    vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(
      /** @this {HTMLAnchorElement} */ function () {
        saved.push(this.download);
      },
    );
    const { kupcad } = await playground('cube(10).named("box")\n');
    await vi.waitFor(() => expect(partsListed()).toBe('box'), RUN_MS);
    const choose = screen.getByRole('combobox', { name: 'Export' });
    await fireEvent.change(choose, { target: { value: 'stl' } });
    await vi.waitFor(() => expect(saved).toEqual(['bracket.stl']));
    vi.spyOn(kupcad, 'build').mockRejectedValueOnce(new Error('no B-Rep model to write'));
    await fireEvent.change(choose, { target: { value: 'step' } });
    await vi.waitFor(() =>
      expect(screen.getByRole('alert').textContent).toBe(
        "The STEP wasn't made: no B-Rep model to write",
      ),
    );
  });
});
