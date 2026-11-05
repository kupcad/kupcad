import { readFileSync } from 'node:fs';
import { resolve as resolvePath } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { createHost } from './host.js';

/** @import { ExportFormat, HostMessage, ParamValues } from '@kupcad/protocol/types' */
/** @typedef {{ defaultPath: string, filters: { name: string, extensions: string[] }[], title: string }} SaveOptions */

const PART = { uri: 'file:///w/part.kup', name: 'part.kup', path: '/w/part.kup' };
/** An export's values and the texts the native side is given for them (@kupcad/protocol's). */
const BUILD = JSON.parse(
  // From the package's folder, where its tests run (the page's tests have no file URLs)
  readFileSync(resolvePath('../kupcad-protocol/src/fixtures/build-arguments.json'), 'utf8'),
);
const LID = { uri: 'file:///w/lid.kup', name: 'lid.kup', path: '/w/lid.kup' };

/** The host on stand-ins for what it works with, what it tells its panel, and what it does. */
function hostOn({ saveAs = /** @type {string | null} */ ('/out/part.3mf') } = {}) {
  const services = {
    server: {
      preview: vi.fn(async (/** @type {string} */ _uri) => null),
      setParams: vi.fn(async (/** @type {string} */ _uri, /** @type {ParamValues} */ _v) => null),
    },
    save: vi.fn(async (/** @type {SaveOptions} */ _options) => saveAs),
    tell: vi.fn(async (/** @type {string} */ _text) => {}),
    beforeExport: vi.fn(async (/** @type {string} */ _path) => true),
    cancelExport: vi.fn(async () => {}),
    exporting: vi.fn((/** @type {string | null} */ _name) => {}),
    exportModel: vi.fn(
      async (
        /** @type {string} */ _script,
        /** @type {string} */ _output,
        /** @type {ExportFormat} */ _format,
        /** @type {[string, string][]} */ _params,
        /** @type {number} */ _memoryLimit,
      ) => {},
    ),
    memoryLimit: () => 8,
    writeFile: vi.fn(async (/** @type {string} */ _path, /** @type {Uint8Array} */ _bytes) => {}),
    reveal: vi.fn(
      (/** @type {string} */ _uri, /** @type {number} */ _line, /** @type {number} */ _col) => {},
    ),
    log: vi.fn((/** @type {string} */ _text) => {}),
  };
  const made = createHost(services);
  /** @type {HostMessage[]} */
  const told = [];
  made.host.listen((message) => told.push(message));
  return { ...made, services, told };
}

/** Until the promises a message started have settled. */
const settled = () => new Promise((resolve) => setTimeout(resolve));

describe('the host', () => {
  it('tells the panel the script shown and its values, and has its frame sent', () => {
    const { host, show, services, told } = hostOn();
    show(PART);
    // Its values only once it was given some: the page starts each document with none
    expect(told).toEqual([{ type: 'document', document: { uri: PART.uri, name: PART.name } }]);
    expect(services.server.preview).toHaveBeenCalledWith(PART.uri);
    // The same script again changes nothing; a panel just connected asks, and is told again
    show(PART);
    expect(services.server.preview).toHaveBeenCalledOnce();
    host.post({ type: 'ready' });
    expect(told).toHaveLength(2);
    expect(services.server.preview).toHaveBeenCalledTimes(2);
  });

  it("gives the server the panel's values, and keeps them for when the script is shown again", () => {
    const { host, show, services, told } = hostOn();
    show(PART);
    host.post({ type: 'setParams', uri: PART.uri, values: { width: 40 } });
    expect(services.server.setParams).toHaveBeenCalledWith(PART.uri, { width: 40 });
    show(LID);
    show(PART);
    expect(told.at(-1)).toEqual({ type: 'overrides', uri: PART.uri, values: { width: 40 } });
  });

  it("gives a server started again the panel's values before the frame is asked", () => {
    const { host, show, services } = hostOn();
    show(PART);
    host.post({ type: 'setParams', uri: PART.uri, values: { width: 40 } });
    services.server.setParams.mockClear();
    services.server.preview.mockClear();
    // The server started again (a new memory limit, a crash): the panel, on its socket, is ready
    host.post({ type: 'ready' });
    expect(services.server.setParams).toHaveBeenCalledWith(PART.uri, { width: 40 });
    expect(services.server.setParams.mock.invocationCallOrder[0]).toBeLessThan(
      services.server.preview.mock.invocationCallOrder[0],
    );
  });

  it('acts on the script shown alone', () => {
    const { host, show, services } = hostOn();
    show(PART);
    host.post({ type: 'setParams', uri: LID.uri, values: { width: 1 } });
    host.post({ type: 'export', uri: LID.uri, format: '3mf' });
    expect(services.server.setParams).not.toHaveBeenCalled();
    expect(services.save).not.toHaveBeenCalled();
    expect(services.log).toHaveBeenCalledTimes(2);
  });

  it('exports the script where the person saves it, in its format, with its values', async () => {
    const { host, show, services } = hostOn();
    show(PART);
    host.post({ type: 'setParams', uri: PART.uri, values: BUILD.values });
    host.post({ type: 'export', uri: PART.uri, format: '3mf' });
    await settled();
    // The page's menu chose the format: the dialog is of it alone (one of them all offered no
    // choice on macOS, and named the file .stl)
    const asked = services.save.mock.calls[0][0];
    expect(asked.title).toBe('Export part.kup as 3MF');
    // Beside the script: a bare name opened the dialog wherever it was last
    expect(asked.defaultPath).toBe('/w/part.3mf');
    expect(asked.filters.map((/** @type {{ extensions: string[] }} */ f) => f.extensions)).toEqual([
      ['3mf'],
    ]);
    expect(services.exportModel).toHaveBeenCalledWith(
      '/w/part.kup',
      '/out/part.3mf',
      '3mf',
      // Each value's text, an array's as kupcad build -p reads one: what the native side's
      // build_args is held to give as the VS Code extension's arguments
      BUILD.params,
      // The setting: the build holds the script to it
      8,
    );
    // Saved first, and said while it runs and once it is done
    expect(services.beforeExport).toHaveBeenCalledWith('/w/part.kup');
    expect(services.exporting.mock.calls).toEqual([['part.3mf'], [null]]);
    expect(services.log).toHaveBeenLastCalledWith('Exported part.3mf.');
  });

  it('builds nothing of a script left unsaved', async () => {
    const { host, show, services } = hostOn();
    services.beforeExport.mockResolvedValue(false);
    show(PART);
    host.post({ type: 'export', uri: PART.uri, format: 'stl' });
    await settled();
    expect(services.save).not.toHaveBeenCalled();
    expect(services.exportModel).not.toHaveBeenCalled();
  });

  it('runs one export at a time, and says nothing of one cancelled', async () => {
    const { host, show, services, cancelExport } = hostOn();
    /** Fails the build under way, as the native side does when it is stopped. @type {((error: unknown) => void)[]} */
    const builds = [];
    services.exportModel.mockImplementation(
      () => new Promise((_resolve, reject) => builds.push(reject)),
    );
    services.cancelExport.mockImplementation(async () => builds[0]('kupcad was stopped'));
    show(PART);
    host.post({ type: 'export', uri: PART.uri, format: '3mf' });
    await settled();
    expect(services.exporting).toHaveBeenLastCalledWith('part.3mf');
    host.post({ type: 'export', uri: PART.uri, format: 'stl' });
    await settled();
    expect(services.log).toHaveBeenLastCalledWith(
      'An export is under way: cancel it, or wait for it to be done.',
    );
    expect(services.exportModel).toHaveBeenCalledOnce();
    await cancelExport();
    await settled();
    expect(services.cancelExport).toHaveBeenCalledOnce();
    expect(services.exporting).toHaveBeenLastCalledWith(null);
    expect(services.tell).not.toHaveBeenCalled();
    // Nothing runs: nothing to stop
    await cancelExport();
    expect(services.cancelExport).toHaveBeenCalledOnce();
  });

  it('offers a STEP file as .step or .stp', async () => {
    const { host, show, services } = hostOn({ saveAs: '/out/part.stp' });
    show(PART);
    host.post({ type: 'export', uri: PART.uri, format: 'step' });
    await settled();
    expect(services.save.mock.calls[0][0].filters[0].extensions).toEqual(['step', 'stp']);
    expect(services.exportModel.mock.calls[0][2]).toBe('step');
  });

  it('writes a name of another format in it, and one of no format in the format chosen', async () => {
    // As the VS Code extension does: the desktop app refused a name of no format
    for (const [saveAs, format] of [
      ['/out/part.stl', 'stl'],
      ['/out/part.model', '3mf'],
    ]) {
      const named = hostOn({ saveAs });
      named.show(PART);
      named.host.post({ type: 'export', uri: PART.uri, format: '3mf' });
      await settled();
      expect(named.services.exportModel.mock.calls[0].slice(1, 3)).toEqual([saveAs, format]);
    }
  });

  it("says why an export wasn't made: kupcad's error", async () => {
    const failing = hostOn();
    failing.services.exportModel.mockRejectedValue(
      'info(x): log\nerror(vm): RuntimeError: too thin\nBuild failed: error.RuntimeError\n',
    );
    failing.show(PART);
    failing.host.post({ type: 'export', uri: PART.uri, format: '3mf' });
    await settled();
    expect(failing.services.tell).toHaveBeenCalledWith(
      "part.kup wasn't exported: RuntimeError: too thin",
    );
    // Told as JSON (kupcad build --errors json), the words are left alone
    const told = hostOn();
    told.services.exportModel.mockRejectedValue(
      'error(vm): RuntimeError: too thin\nBuild failed: error.RuntimeError\n{"error":{"kind":"runtime","message":"RuntimeError: too thin, at the lip","file":"part.kup","line":2,"column":1}}\n',
    );
    told.show(PART);
    told.host.post({ type: 'export', uri: PART.uri, format: '3mf' });
    await settled();
    expect(told.services.tell).toHaveBeenCalledWith(
      "part.kup wasn't exported: RuntimeError: too thin, at the lip",
    );
    // Cancelled, nothing is built
    const cancelled = hostOn({ saveAs: null });
    cancelled.show(PART);
    cancelled.host.post({ type: 'export', uri: PART.uri, format: '3mf' });
    await settled();
    expect(cancelled.services.exportModel).not.toHaveBeenCalled();
  });

  it('saves a screenshot where the person says, and shows a place a run named', async () => {
    const { host, show, services } = hostOn({ saveAs: '/out/part.png' });
    show(PART);
    host.post({ type: 'screenshot', png: btoa('PNG') });
    await settled();
    expect(services.save.mock.calls[0][0].defaultPath).toBe('/w/part.png');
    const [path, bytes] = services.writeFile.mock.calls[0];
    expect(path).toBe('/out/part.png');
    expect([...bytes]).toEqual([...new TextEncoder().encode('PNG')]);
    host.post({ type: 'reveal', uri: PART.uri, line: 3, column: 5 });
    expect(services.reveal).toHaveBeenCalledWith(PART.uri, 3, 5, null);
  });
});

it("gives the panel's console the server's log", () => {
  const { log, told } = hostOn();
  log('info(lsp): ready\n');
  expect(told).toEqual([{ type: 'log', text: 'info(lsp): ready\n' }]);
});
