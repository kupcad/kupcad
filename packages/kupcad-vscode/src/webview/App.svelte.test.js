import { stubRenderer } from '@kupcad/viewer/testing';
import { testCore } from '@kupcad/wasm/testing';
import { fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { describe, expect, it, vi } from 'vitest';
import App from './App.svelte';

/** @import { HostMessage, Preview } from '@kupcad/protocol/types' */
/** @import { ViewportEvents } from './socket.js' */

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
function page({ viewportUrl = /** @type {string | null} */ ('ws://127.0.0.1:9001') } = {}) {
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
  const { unmount } = render(App, {
    props: {
      host,
      viewportUrl,
      connect,
      viewerOptions: { renderer: stubRenderer().renderer },
    },
  });
  return {
    posted,
    unmount,
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

/** The status line's text, if one shows. */
const status = () => document.querySelector('.status')?.textContent ?? null;

describe('App', () => {
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
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    expect(status()).toBeNull();
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

    // Another document, then back: its values come back with it
    await viewer.tell({ type: 'document', document: LID });
    await viewer.tell({ type: 'overrides', uri: LID.uri, values: { width: 12 } });
    await viewer.tell({ type: 'document', document: PART });
    viewer.socket.on.frame(await previewOf(SCRIPT, PART.uri));
    await tick();
    expect(screen.getByRole('button', { name: 'Revert width' })).toBeTruthy();
  });

  it('shows why the run failed, and what it warned of without a line', async () => {
    const viewer = page();
    await viewer.tell({ type: 'document', document: PART });
    const failed = await previewOf('x = 1\nraise "too thin"\n', PART.uri);
    viewer.socket.on.frame(failed);
    await tick();
    expect(screen.getByRole('alert').textContent).toMatch(/too thin.*\(line 2\)/);

    const empty = await previewOf(
      'cube(1) - cube(2, center: true).translate(x: 0.5, y: 0.5, z: 0.5)',
      PART.uri,
    );
    viewer.socket.on.frame(empty);
    await tick();
    expect(screen.getByRole('alert').textContent).toMatch(/empty/);
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

describe('App presets', () => {
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
});

it('asks the host to export or print the document shown', async () => {
  const viewer = page();
  expect(screen.queryByRole('button', { name: 'Export…' })).toBeNull();
  await viewer.tell({ type: 'document', document: PART });
  await fireEvent.click(screen.getByRole('button', { name: 'Export…' }));
  await fireEvent.click(screen.getByRole('button', { name: 'Print' }));
  expect(viewer.posted.slice(-2)).toEqual([
    { type: 'export', uri: PART.uri },
    { type: 'print', uri: PART.uri },
  ]);
});
