import { describe, expect, it, vi } from 'vitest';
import { createHost, formatOf } from './host.js';

/** @import { ExportFormat, HostMessage, ParamValues } from '@kupcad/protocol/types' */
/** @typedef {{ defaultPath: string, filters: { name: string, extensions: string[] }[], title: string }} SaveOptions */

const PART = { uri: 'file:///w/part.kup', name: 'part.kup', path: '/w/part.kup' };
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
    exportModel: vi.fn(
      async (
        /** @type {string} */ _script,
        /** @type {string} */ _output,
        /** @type {ExportFormat} */ _format,
        /** @type {[string, string][]} */ _params,
      ) => {},
    ),
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
    expect(told).toEqual([
      { type: 'document', document: { uri: PART.uri, name: PART.name } },
      { type: 'overrides', uri: PART.uri, values: {} },
    ]);
    expect(services.server.preview).toHaveBeenCalledWith(PART.uri);
    // The same script again changes nothing; a panel just connected asks, and is told again
    show(PART);
    expect(services.server.preview).toHaveBeenCalledOnce();
    host.post({ type: 'ready' });
    expect(told).toHaveLength(4);
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

  it('acts on the script shown alone', () => {
    const { host, show, services } = hostOn();
    show(PART);
    host.post({ type: 'setParams', uri: LID.uri, values: { width: 1 } });
    host.post({ type: 'export', uri: LID.uri });
    expect(services.server.setParams).not.toHaveBeenCalled();
    expect(services.save).not.toHaveBeenCalled();
    expect(services.log).toHaveBeenCalledTimes(2);
  });

  it('exports the script where the person saves it, in its format, with its values', async () => {
    const { host, show, services } = hostOn();
    show(PART);
    host.post({ type: 'setParams', uri: PART.uri, values: { width: 40, hollow: true } });
    host.post({ type: 'export', uri: PART.uri });
    await settled();
    const asked = services.save.mock.calls[0][0];
    expect(asked.defaultPath).toBe('part.stl');
    expect(asked.filters.map((/** @type {{ extensions: string[] }} */ f) => f.extensions)).toEqual([
      ['stl'],
      ['3mf'],
      ['step', 'stp'],
      ['glb'],
      ['gltf'],
      ['obj'],
      ['svg'],
      ['dxf'],
    ]);
    expect(services.exportModel).toHaveBeenCalledWith('/w/part.kup', '/out/part.3mf', '3mf', [
      ['width', '40'],
      ['hollow', 'true'],
    ]);
  });

  it("says why an export wasn't made: a name of no format, kupcad's error", async () => {
    const odd = hostOn({ saveAs: '/out/part.exe' });
    odd.show(PART);
    odd.host.post({ type: 'export', uri: PART.uri });
    await settled();
    expect(odd.services.exportModel).not.toHaveBeenCalled();
    expect(odd.services.tell.mock.calls[0][0]).toMatch(/names no format kupcad writes: .*\.3mf/);

    const failing = hostOn();
    failing.services.exportModel.mockRejectedValue(
      'info(x): log\nerror(vm): RuntimeError: too thin\nBuild failed: error.RuntimeError\n',
    );
    failing.show(PART);
    failing.host.post({ type: 'export', uri: PART.uri });
    await settled();
    expect(failing.services.tell).toHaveBeenCalledWith(
      "part.kup wasn't exported: RuntimeError: too thin",
    );
    // Cancelled, nothing is built
    const cancelled = hostOn({ saveAs: null });
    cancelled.show(PART);
    cancelled.host.post({ type: 'export', uri: PART.uri });
    await settled();
    expect(cancelled.services.exportModel).not.toHaveBeenCalled();
  });

  it('saves a screenshot where the person says, and shows a place a run named', async () => {
    const { host, show, services } = hostOn({ saveAs: '/out/part.png' });
    show(PART);
    host.post({ type: 'screenshot', png: btoa('PNG') });
    await settled();
    const [path, bytes] = services.writeFile.mock.calls[0];
    expect(path).toBe('/out/part.png');
    expect([...bytes]).toEqual([...new TextEncoder().encode('PNG')]);
    host.post({ type: 'reveal', uri: PART.uri, line: 3, column: 5 });
    expect(services.reveal).toHaveBeenCalledWith(PART.uri, 3, 5);
  });
});

it('reads an export file name as the format it is written in', () => {
  expect(['a.STL', 'a.stp', 'a.step', 'a.3mf', 'a.txt', 'stl'].map(formatOf)).toEqual([
    'stl',
    'step',
    'step',
    '3mf',
    null,
    'stl',
  ]);
});
