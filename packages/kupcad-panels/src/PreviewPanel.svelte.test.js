import { stubRenderer } from '@kupcad/viewer/testing';
import { testCore } from '@kupcad/wasm/testing';
import { fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { describe, expect, it, vi } from 'vitest';
import PreviewPanel from './PreviewPanel.svelte';
import { memorySettings } from './settings.js';

/** @import { HostMessage, Preview } from '@kupcad/protocol/types' */
/** @import { ViewportEvents } from './viewport-socket.js' */

const PART = { uri: 'file:///work/part.kup', name: 'part.kup' };
const LID = { uri: 'file:///work/lid.kup', name: 'lid.kup' };
const SCRIPT = 'w = param(:width, default: 20, validate: { min: 10 })\ncube(w)\n';

/**
 * The frame the language server sends of `source`, as the document at `uri`.
 * @param {string} source
 * @param {string} uri
 * @returns {Promise<Preview>}
 */
async function previewOf(source, uri) {
  const preview = await (await testCore()).preview(source);
  return { ...preview, header: { ...preview.header, document: uri } };
}

/** The page, with a host and a socket the test plays. */
function page({
  viewportUrl = /** @type {string | null} */ ('ws://127.0.0.1:9001'),
  presets = true,
  settings = memorySettings(),
} = {}) {
  /** @type {unknown[]} */
  const posted = [];
  /** @type {((message: HostMessage) => void)[]} */
  const listeners = [];
  /** @type {{ url: string, on: ViewportEvents, closed: boolean } | null} */
  let socket = null;
  const host = {
    post: (/** @type {unknown} */ message) => posted.push(message),
    listen: (/** @type {(message: HostMessage) => void} */ listener) => {
      listeners.push(listener);
      return () => listeners.splice(listeners.indexOf(listener), 1);
    },
  };
  const connect = (/** @type {string} */ url, /** @type {ViewportEvents} */ on) => {
    socket = { url, on, closed: false };
    const opened = socket;
    return () => {
      opened.closed = true;
    };
  };
  const { unmount, rerender } = render(PreviewPanel, {
    props: {
      host,
      viewportUrl,
      connect,
      viewerOptions: { renderer: stubRenderer().renderer },
      presets,
      settings,
    },
  });
  return {
    posted,
    unmount,
    /** The server's socket is at `url` now (null: there is none). @param {string | null} url */
    viewport: (url) => rerender({ viewportUrl: url }),
    get socket() {
      return /** @type {{ url: string, on: ViewportEvents, closed: boolean }} */ (socket);
    },
    /** @param {HostMessage} message */
    async tell(message) {
      for (const listener of listeners) listener(message);
      await tick();
    },
  };
}

/** The list of the run's problems under the model. */
const problems = () => screen.getByRole('list', { name: 'Problems' });

/** The status line's text, if one shows. */
const status = () => document.querySelector('.notice')?.textContent ?? null;

describe('PreviewPanel', () => {
  it('says what it waits for: the server, its socket, a script, its model', async () => {
    const waiting = page({ viewportUrl: null });
    expect(status()).toBe('Waiting for the KupCAD language server…');
    waiting.unmount();

    const viewer = page();
    expect(viewer.socket.url).toBe('ws://127.0.0.1:9001');
    expect(status()).toBe('Connecting to the language server…');
    viewer.socket.on.state(true);
    await tick();
    expect(status()).toBe('Open a .kup file to see its model.');
    await viewer.tell({ type: 'document', document: PART });
    expect(status()).toBe('Running part.kup…');
  });

  it('follows the server to its socket as it starts again, its console kept', async () => {
    const viewer = page({ viewportUrl: null });
    await viewer.tell({ type: 'document', document: PART });
    await viewer.viewport('ws://127.0.0.1:9001');
    const first = viewer.socket;
    expect(first.url).toBe('ws://127.0.0.1:9001');
    await viewer.tell({ type: 'log', text: 'kupcad lsp ended (code 1); starting it again\n' });
    await viewer.viewport(null);
    expect(first.closed).toBe(true);
    expect(status()).toBe('Waiting for the KupCAD language server…');
    await viewer.viewport('ws://127.0.0.1:9002');
    expect(viewer.socket.url).toBe('ws://127.0.0.1:9002');
    viewer.socket.on.state(true);
    await tick();
    expect(status()).toBe('Running part.kup…');
    expect(consoleLines()).toEqual(['kupcad lsp ended (code 1); starting it again']);
  });

  it("asks the host for a frame when the socket opens, and tells it a frame it can't read", () => {
    const viewer = page();
    viewer.socket.on.open();
    viewer.socket.on.problem('a frame of protocol version 9');
    expect(viewer.posted).toEqual([
      { type: 'ready' },
      { type: 'problem', message: 'a frame of protocol version 9' },
    ]);
    viewer.unmount();
    expect(viewer.socket.closed).toBe(true);
  });

  it("shows the frame of the document shown, its parameters beside it, and not another's", async () => {
    const viewer = page();
    viewer.socket.on.state(true);
    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf('cube(1)', LID.uri));
    await tick();
    expect(status()).toBe('Running part.kup…');
    // The pane's status line: running until its frame came
    expect(screen.getByRole('status').textContent?.trim()).toBe('Running…');
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    expect(status()).toBeNull();
    expect(screen.getByRole('status').textContent?.trim()).toMatch(/^Ready · \d+ ms$/);
    expect(screen.getByLabelText('Parameters')).toBeTruthy();
    expect(/** @type {HTMLInputElement} */ (screen.getByLabelText('width')).value).toBe('20');
  });

  it('shows no model when it shows no document: none told yet, or none any more', async () => {
    const viewer = page();
    viewer.socket.on.state(true);
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    expect(status()).toBe('Open a .kup file to see its model.');
    expect(screen.queryByLabelText('Parameters')).toBeNull();

    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    expect(screen.queryByLabelText('Parameters')).not.toBeNull();
    await viewer.tell({ type: 'document', document: null });
    expect(status()).toBe('Open a .kup file to see its model.');
    expect(screen.queryByLabelText('Parameters')).toBeNull();
  });

  it("gives the host the panel's values for the document, and shows the ones the host gives", async () => {
    const viewer = page();
    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    await fireEvent.change(screen.getByLabelText('width'), { target: { value: '40' } });
    expect(viewer.posted.at(-1)).toEqual({
      type: 'setParams',
      uri: PART.uri,
      values: { width: 40 },
    });

    // Another document: none set until the host says what it holds for it, and what it
    // holds for a document not shown stays out
    await viewer.tell({ type: 'document', document: LID });
    viewer.socket.on.frame(await previewOf(SCRIPT, LID.uri));
    await tick();
    expect(screen.queryByRole('button', { name: 'Revert width' })).toBeNull();
    await viewer.tell({ type: 'overrides', uri: PART.uri, values: { width: 40 } });
    expect(screen.queryByRole('button', { name: 'Revert width' })).toBeNull();
    await viewer.tell({ type: 'overrides', uri: LID.uri, values: { width: 12 } });
    expect(screen.getByRole('button', { name: 'Revert width' })).toBeTruthy();
    // Back: the host says the document's values again, as the panel does with each document
    await viewer.tell({ type: 'document', document: PART });
    await viewer.tell({ type: 'overrides', uri: PART.uri, values: { width: 40 } });
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    expect(screen.getByRole('button', { name: 'Revert width' })).toBeTruthy();
    expect(
      viewer.posted.filter((m) => /** @type {{ type: string }} */ (m).type === 'setParams'),
    ).toHaveLength(1);
  });

  it('lists why the run failed, and what it warned of; one with a line, clicked, is revealed', async () => {
    const viewer = page();
    await viewer.tell({ type: 'document', document: PART });
    const failed = await previewOf('x = 1\nraise "too thin"\n', PART.uri);
    viewer.socket.on.frame(failed);
    await tick();
    expect(problems().textContent).toMatch(/Error\s+RuntimeError: too thin\s+line 2/);
    await fireEvent.click(/** @type {HTMLElement} */ (problems().querySelector('button')));
    expect(viewer.posted.at(-1)).toEqual({ type: 'reveal', uri: PART.uri, line: 2, column: 1 });

    // A warning while the model was meshed has no line: nothing to reveal
    const empty = await previewOf(
      'cube(1) - cube(2, center: true).translate(x: 0.5, y: 0.5, z: 0.5)',
      PART.uri,
    );
    viewer.socket.on.frame(empty);
    await tick();
    expect(problems().textContent).toMatch(/Warning\s+.*empty/);
    expect(problems().querySelector('button')).toBeNull();
  });

  it("says why the viewer can't show a frame's model, until the next frame, and tells the host", async () => {
    const viewer = page();
    viewer.socket.on.state(true);
    await viewer.tell({ type: 'document', document: PART });
    const good = await previewOf('cube(1)', PART.uri);
    // A model the viewer refuses: Draco-compressed, with no decoder given
    const glb = await (await testCore()).build('cube(1)', { format: 'glb', draco: true });
    viewer.socket.on.frame({ header: good.header, model: { kind: '3d', glb, parts: [] } });
    await vi.waitFor(() => expect(status()).toMatch(/^The model can't be shown: .*Draco/));
    expect(viewer.posted.at(-1)).toMatchObject({
      type: 'problem',
      message: expect.stringContaining('Draco'),
    });
    viewer.socket.on.frame(good);
    await vi.waitFor(() => expect(status()).toBeNull());
  });

  it('gives the host a screenshot as base64', async () => {
    const viewer = page();
    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf('cube(1)', PART.uri));
    await tick();
    await fireEvent.click(screen.getByRole('button', { name: 'Screenshot' }));
    await vi.waitFor(() => expect(viewer.posted.at(-1)).toMatchObject({ type: 'screenshot' }));
  });
});

describe('PreviewPanel presets', () => {
  it("lists the document's presets, applies the one chosen, and saves the panel's values as one", async () => {
    const viewer = page();
    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await viewer.tell({ type: 'presets', uri: LID.uri, names: ['Other'] });
    await viewer.tell({ type: 'presets', uri: PART.uri, names: ['Small', 'Large'] });
    const picker = /** @type {HTMLSelectElement} */ (
      screen.getByRole('combobox', { name: 'Preset' })
    );
    expect([...picker.options].map((o) => o.textContent?.trim())).toEqual([
      'Apply a preset…',
      'Small',
      'Large',
    ]);

    await fireEvent.change(picker, { target: { value: 'Large' } });
    expect(viewer.posted.at(-1)).toEqual({ type: 'applyPreset', uri: PART.uri, name: 'Large' });
    expect(picker.value).toBe('');

    await fireEvent.change(screen.getByLabelText('width'), { target: { value: '40' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Save as preset…' }));
    expect(viewer.posted.at(-1)).toEqual({
      type: 'savePreset',
      uri: PART.uri,
      values: { width: 40 },
    });
  });

  it('offers no preset to apply for a document without any', async () => {
    const viewer = page();
    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    const picker = /** @type {HTMLSelectElement} */ (
      screen.getByRole('combobox', { name: 'Preset' })
    );
    expect(picker.disabled).toBe(true);
    expect(picker.options[0].textContent?.trim()).toBe('No presets');
  });

  it('offers none for a host that keeps none, the parameters shown as they are', async () => {
    const viewer = page({ presets: false });
    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    expect(screen.getByRole('spinbutton', { name: 'width' })).toBeTruthy();
    expect(screen.queryByRole('combobox', { name: 'Preset' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Save as preset…' })).toBeNull();
  });
});

/** The console's lines, as they read. */
const consoleLines = () =>
  [...screen.getByRole('log').querySelectorAll('li')].map((li) => li.textContent?.trim());

describe('PreviewPanel console', () => {
  it("keeps each run of the document shown once, and the host's log, as they come", async () => {
    const viewer = page();
    await viewer.tell({ type: 'document', document: PART });
    const frame = await previewOf(`puts "hello"\n${SCRIPT}`, PART.uri);
    viewer.socket.on.frame(frame);
    await tick();
    // Sent again (a viewer that connects is sent the frame it missed): the same run
    viewer.socket.on.frame(frame);
    await viewer.tell({ type: 'log', text: 'info(session_manager): Initialized\n' });
    const lines = consoleLines();
    expect(lines[0]).toMatch(/^part\.kup: Ready · \d+ ms$/);
    expect(lines.slice(1)).toEqual(['hello', 'info(session_manager): Initialized']);
    // Another document's frame isn't this console's
    viewer.socket.on.frame(await previewOf('puts "other"\ncube(1)\n', LID.uri));
    await tick();
    expect(consoleLines()).toHaveLength(3);
  });

  it('shows the script where a line names, and is cleared and folded away', async () => {
    const viewer = page();
    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf('cube(1)\nraise "boom"\n', PART.uri));
    await tick();
    await fireEvent.click(screen.getByRole('button', { name: /Error: RuntimeError: boom/ }));
    expect(viewer.posted.at(-1)).toEqual({ type: 'reveal', uri: PART.uri, line: 2, column: 1 });
    await fireEvent.click(screen.getByRole('button', { name: 'Clear' }));
    expect(consoleLines()).toEqual([]);
    await fireEvent.click(screen.getByRole('button', { name: 'Console' }));
    expect(screen.queryByRole('log')).toBeNull();
    expect(screen.getByRole('button', { name: 'Console' }).getAttribute('aria-expanded')).toBe(
      'false',
    );
  });
});

it("lays its panes out as the host's settings keep them, and keeps what the person changes", async () => {
  const settings = memorySettings({
    'preview.params': 320,
    'preview.console': 200,
    'preview.panelOpen': false,
  });
  const viewer = page({ settings });
  await viewer.tell({ type: 'document', document: PART });
  viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
  await tick();
  const params = /** @type {HTMLElement} */ (
    screen.getByRole('complementary', { name: 'Parameters' })
  );
  expect(params.style.width).toBe('320px');
  expect(screen.getByRole('log').style.height).toBe('200px');
  // The view's panel hidden, as kept; shown again, it stays so
  expect(screen.queryByRole('complementary', { name: 'View and parts' })).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Panel' }));
  expect(screen.getByRole('complementary', { name: 'View and parts' })).toBeTruthy();
  expect(settings.get('preview.panelOpen')).toBe(true);
  await fireEvent.keyDown(screen.getByRole('separator', { name: 'Resize the parameters' }), {
    key: 'ArrowLeft',
  });
  // The bar is before the column: toward its start widens it
  expect(settings.get('preview.params')).toBe(336);
  await fireEvent.keyDown(screen.getByRole('separator', { name: 'Resize the console' }), {
    key: 'ArrowDown',
  });
  expect(settings.get('preview.console')).toBe(184);
  // Folded, it stays so, and has no bar to resize it
  await fireEvent.click(screen.getByRole('button', { name: 'Console' }));
  expect(settings.get('preview.consoleOpen')).toBe(false);
  expect(screen.queryByRole('separator', { name: 'Resize the console' })).toBeNull();
});

it("hides the parameters by the toolbar's toggle, for the model's width, and keeps that", async () => {
  const settings = memorySettings();
  const viewer = page({ settings });
  await viewer.tell({ type: 'document', document: PART });
  // No parameters yet: nothing to hide
  expect(screen.queryByRole('button', { name: 'Parameters' })).toBeNull();
  viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
  await tick();
  const toggle = screen.getByRole('button', { name: 'Parameters' });
  expect(toggle.getAttribute('aria-expanded')).toBe('true');
  // At the toolbar's end, beside the column, as the view's toggles look
  expect(toggle.previousElementSibling?.textContent?.trim()).toBe('Panel');
  expect(toggle.classList.contains('kc-control')).toBe(true);

  await fireEvent.click(toggle);
  expect(toggle.getAttribute('aria-expanded')).toBe('false');
  expect(screen.queryByRole('complementary', { name: 'Parameters' })).toBeNull();
  expect(screen.queryByRole('separator', { name: 'Resize the parameters' })).toBeNull();
  // Hidden, not gone: the column the toggle controls
  const column = document.getElementById(
    /** @type {string} */ (toggle.getAttribute('aria-controls')),
  );
  expect(column?.hidden).toBe(true);
  expect(settings.get('preview.paramsOpen')).toBe(false);

  // The next page the host makes with its settings hides them too
  viewer.unmount();
  const again = page({ settings });
  await again.tell({ type: 'document', document: PART });
  again.socket.on.frame(await previewOf(SCRIPT, PART.uri));
  await tick();
  expect(screen.queryByRole('complementary', { name: 'Parameters' })).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Parameters' }));
  expect(screen.getByRole('complementary', { name: 'Parameters' })).toBeTruthy();
  expect(settings.get('preview.paramsOpen')).toBe(true);
});

it('asks the host to export the document shown in the format its menu chose', async () => {
  const viewer = page();
  expect(screen.queryByRole('combobox', { name: 'Export' })).toBeNull();
  await viewer.tell({ type: 'document', document: PART });
  const menu = /** @type {HTMLSelectElement} */ (screen.getByRole('combobox', { name: 'Export' }));
  // In the viewer's toolbar, it looks as its own controls do
  expect(menu.classList.contains('kc-control')).toBe(true);
  // With no run to go by, every format
  const offered = () => [...menu.options].filter((o) => !o.disabled).map((o) => o.value);
  expect(offered()).toHaveLength(8);
  // A 2D model's drawings alone: the core refuses it in a 3D format
  viewer.socket.on.state(true);
  viewer.socket.on.frame(await previewOf('square(10)', PART.uri));
  await vi.waitFor(() => expect(offered()).toEqual(['svg', 'dxf']));
  await fireEvent.change(menu, { target: { value: 'svg' } });
  expect(viewer.posted.at(-1)).toEqual({ type: 'export', uri: PART.uri, format: 'svg' });
  // Its name again, so the same format can be chosen next time
  expect(menu.value).toBe('');
});
