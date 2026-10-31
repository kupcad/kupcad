import { forEachDiagnostic } from '@codemirror/lint';
import { EditorView } from '@codemirror/view';
import { fireEvent, render, screen } from '@testing-library/svelte';
import { stubRenderer } from '@kupcad/ui/testing';
import { testCore } from '@kupcad/wasm/testing';
import { createRawSnippet, tick } from 'svelte';
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
 * @param {Record<string, unknown>} [props] what else it is given
 */
async function playground(source, settings = memorySettings(), props = {}) {
  const kupcad = await testCore();
  const { renderer, drawn } = stubRenderer();
  const { component, rerender } = render(Playground, {
    props: {
      source,
      kupcad,
      name: 'bracket',
      viewerOptions: { renderer, motionMs: 0 },
      settings,
      ...props,
    },
  });
  return { kupcad, view: editorView(), component, rerender, drawn };
}

/** The editor's view, as it is now. */
const editorView = () =>
  /** @type {EditorView} */ (
    EditorView.findFromDOM(/** @type {HTMLElement} */ (document.querySelector('.cm-editor')))
  );

/**
 * The undo key, as the person presses it (jsdom is no Mac: Ctrl).
 * @param {EditorView} view
 */
const undo = (view) => fireEvent.keyDown(view.contentDOM, { key: 'z', ctrlKey: true });

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

  it('follows its settings set elsewhere, and keeps a size dragged once the drag is done', async () => {
    const settings = memorySettings();
    await playground('cube(10)\n', settings);
    const script = /** @type {HTMLElement} */ (document.querySelector('.kc-playground'));
    settings.set('playground.editor', 420);
    await tick();
    expect(script.style.getPropertyValue('--editor-width')).toBe('420px');

    // jsdom captures no pointer: the bar takes the drag as a browser gives it
    const capture = HTMLElement.prototype.setPointerCapture;
    HTMLElement.prototype.setPointerCapture = () => {};
    try {
      const set = vi.spyOn(settings, 'set');
      const bar = screen.getByRole('separator', { name: 'Resize the script' });
      await fireEvent.pointerDown(bar, { button: 0, clientX: 500, pointerId: 1 });
      for (const clientX of [520, 540]) await fireEvent.pointerMove(bar, { clientX, pointerId: 1 });
      expect(script.style.getPropertyValue('--editor-width')).toBe('460px');
      expect(set).not.toHaveBeenCalled();
      await fireEvent.pointerUp(bar, { pointerId: 1 });
      expect(set).toHaveBeenCalledExactlyOnceWith('playground.editor', 460);
    } finally {
      HTMLElement.prototype.setPointerCapture = capture;
    }
  });

  it("tells its host each edit of the script, the host's buttons after Export, for sharing it", async () => {
    /** @type {string[]} */
    const sources = [];
    const actions = createRawSnippet(() => ({
      render: () => '<button type="button" class="kc-control">Share</button>',
    }));
    const { view } = await playground('cube(10)\n', memorySettings(), {
      onsource: (/** @type {string} */ source) => sources.push(source),
      actions,
    });
    // The script it was given is no edit
    expect(sources).toEqual([]);
    view.dispatch({ changes: { from: 5, to: 7, insert: '12' } });
    expect(sources).toEqual(['cube(12)\n']);
    const share = screen.getByRole('button', { name: 'Share' });
    const exportMenu = screen.getByRole('combobox', { name: 'Export' });
    expect(exportMenu.compareDocumentPosition(share) & Node.DOCUMENT_POSITION_FOLLOWING).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING,
    );
  });

  it("keeps how the view looks in its settings, and lists its host's shortcuts first", async () => {
    const settings = memorySettings();
    await playground('cube(10)\n', settings, {
      shortcuts: [{ title: 'Page', keys: [['⌘K', 'Search the docs']] }],
    });
    await fireEvent.click(screen.getByRole('button', { name: 'X-ray' }));
    expect(settings.get('view.renderMode')).toBe('xray');
    await fireEvent.click(screen.getByRole('button', { name: 'Keyboard shortcuts' }));
    const dialog = screen.getByRole('dialog', { name: 'Keyboard shortcuts' });
    expect([...dialog.querySelectorAll('h3')].map((heading) => heading.textContent)).toEqual([
      'Page',
      'Viewer',
    ]);
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

  it('loads a script the page gives in place of the one shown, and runs it on its own values', async () => {
    const { kupcad, view, component } = await playground(
      'w = param(:w, default: 10)\ncube(w).named("box")\n',
    );
    const field = await vi.waitFor(() => screen.getByLabelText('w'), RUN_MS);
    await fireEvent.change(field, { target: { value: '20' } });
    await vi.waitFor(() => expect(screen.getByText('1 changed')).toBeTruthy(), RUN_MS);
    const preview = vi.spyOn(kupcad, 'preview');
    component.load('w = param(:w, default: 4)\ncube(w).named("lid")\n');
    await tick();
    expect(view.state.doc.toString()).toBe('w = param(:w, default: 4)\ncube(w).named("lid")\n');
    await vi.waitFor(() => expect(partsListed()).toBe('lid'), RUN_MS);
    expect(preview).toHaveBeenCalledWith(
      expect.stringContaining('lid'),
      expect.objectContaining({ params: {} }),
    );
    expect(screen.getByText("The script's values")).toBeTruthy();
    expect(/** @type {HTMLInputElement} */ (screen.getByLabelText('w')).value).toBe('4');
  });

  it("frames a loaded script's model whole, where an edit's keeps the camera", async () => {
    const { view, component, drawn } = await playground('cube(10).named("box")\n');
    await vi.waitFor(() => expect(partsListed()).toBe('box'), RUN_MS);
    view.dispatch({
      changes: {
        from: 0,
        to: view.state.doc.length,
        insert: 'cube(10).translate(x: 300).named("far")\n',
      },
    });
    await vi.waitFor(() => expect(partsListed()).toBe('far'), RUN_MS);
    // An edit keeps the camera where it was, on the box
    expect(drawn.camera?.position.x).toBeLessThan(100);
    component.load('cube(10).translate(x: 300).named("loaded")\n');
    await vi.waitFor(() => expect(partsListed()).toBe('loaded'), RUN_MS);
    await vi.waitFor(() => expect(drawn.camera?.position.x).toBeGreaterThan(200), RUN_MS);
  });

  it('loads the script it started with over the edits made since, which is no edit', async () => {
    /** @type {string[]} */
    const sources = [];
    const { view, component } = await playground('cube(10).named("box")\n', memorySettings(), {
      onsource: (/** @type {string} */ source) => sources.push(source),
    });
    view.dispatch({ changes: { from: 5, to: 7, insert: '12' } });
    component.load('cube(10).named("box")\n');
    await tick();
    expect(view.state.doc.toString()).toBe('cube(10).named("box")\n');
    expect(sources).toEqual(['cube(12).named("box")\n']);
  });

  it('opens another document in place of the one shown, each with its own undo history', async () => {
    const { view, component } = await playground('cube(1).named("a")\n');
    view.dispatch({ changes: { from: 5, to: 6, insert: '2' } });
    const kept = component.snapshot();
    component.open('cube(3).named("b")\n');
    await tick();
    const other = editorView();
    expect(other).not.toBe(view);
    expect(other.state.doc.toString()).toBe('cube(3).named("b")\n');
    await vi.waitFor(() => expect(partsListed()).toBe('b'), RUN_MS);
    // Nothing of the last document's to undo
    await undo(other);
    expect(other.state.doc.toString()).toBe('cube(3).named("b")\n');
    component.open('cube(2).named("a")\n', kept);
    await tick();
    const back = editorView();
    expect(back.state.doc.toString()).toBe('cube(2).named("a")\n');
    await undo(back);
    expect(back.state.doc.toString()).toBe('cube(1).named("a")\n');
    component.focus();
    expect(back.hasFocus).toBe(true);
  });

  it("runs and exports with the files the script's imports read", async () => {
    vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:model');
    vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    const files = { 'parts/size.kup': 'size = 6\nexport size\n' };
    const { kupcad } = await playground(
      'import { size } from "./parts/size.kup"\ncube(size).named("box")\n',
      memorySettings(),
      { files },
    );
    await vi.waitFor(() => expect(partsListed()).toBe('box'), RUN_MS);
    const build = vi.spyOn(kupcad, 'build');
    await fireEvent.change(screen.getByRole('combobox', { name: 'Export' }), {
      target: { value: 'stl' },
    });
    await vi.waitFor(() =>
      expect(build).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({ files })),
    );
  });

  it('runs again when the page says what its script imports changed, and not before', async () => {
    const { kupcad, component, rerender } = await playground(
      'import { size } from "./size.kup"\ncube(size).named("box")\n',
      memorySettings(),
      { files: { 'size.kup': 'size = 6\nexport size\n' } },
    );
    await vi.waitFor(() => expect(partsListed()).toBe('box'), RUN_MS);
    const preview = vi.spyOn(kupcad, 'preview');
    await rerender({ files: {} });
    expect(preview).not.toHaveBeenCalled();
    component.run();
    await vi.waitFor(() => expect(statusText()).toMatch(/^Failed/), RUN_MS);
    expect(preview).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({ files: {} }),
    );
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
