import { describe, expect, it, vi } from 'vitest';
import { createPreviewHost, pngBytes } from './preview-host.js';

const PART = { uri: 'file:///w/part.kup', name: 'part.kup' };
const LID = { uri: 'file:///w/lid.kup', name: 'lid.kup' };

/** A host on stand-in services, and what it told the page. */
function hostOn() {
  const services = {
    server: { preview: vi.fn(async () => {}), setParams: vi.fn(async () => {}) },
    warn: vi.fn(),
    fail: vi.fn(),
    export: vi.fn(),
    screenshot: vi.fn(),
    reveal: vi.fn(),
    presets: vi.fn(),
    applyPreset: vi.fn(),
    savePreset: vi.fn(),
    keepSetting: vi.fn(),
  };
  const host = createPreviewHost(services);
  /** @type {unknown[]} */
  const told = [];
  const stop = host.listen((message) => told.push(message));
  return { host, services, told, stop };
}

const settled = () => new Promise((resolve) => setTimeout(resolve));

describe('the preview host', () => {
  it('tells the page the document shown, its values when it has some, and asks for its frame', () => {
    const { host, services, told } = hostOn();
    host.show(PART);
    expect(told).toEqual([{ type: 'document', document: PART }]);
    expect(services.server.preview).toHaveBeenCalledWith(PART.uri);
    expect(services.presets).toHaveBeenCalledWith(PART.uri);
    // The same again changes nothing; a page just loaded is told again, and asks again
    host.show(PART);
    expect(services.server.preview).toHaveBeenCalledOnce();
    host.post({ type: 'ready' });
    expect(told).toHaveLength(2);
    expect(services.server.preview).toHaveBeenCalledTimes(2);
    // Given values, the page sees them with the document, now and when it is shown again
    host.post({ type: 'setParams', uri: PART.uri, values: { w: 3 } });
    expect(services.server.setParams).toHaveBeenCalledWith(PART.uri, { w: 3 });
    host.show(LID);
    host.show(PART);
    expect(told.at(-1)).toEqual({ type: 'overrides', uri: PART.uri, values: { w: 3 } });
    expect(host.values.of(PART.uri)).toEqual({ w: 3 });
    host.show(null);
    expect(told.at(-1)).toEqual({ type: 'document', document: null });
    expect(host.shown).toBeNull();
  });

  it('acts on the document shown alone, and says so', () => {
    const { host, services } = hostOn();
    host.show(PART);
    host.post({ type: 'setParams', uri: LID.uri, values: { w: 1 } });
    host.post({ type: 'export', uri: LID.uri, format: 'stl' });
    host.post({ type: 'reveal', uri: LID.uri, line: 1, column: 1 });
    expect(services.server.setParams).not.toHaveBeenCalled();
    expect(services.export).not.toHaveBeenCalled();
    expect(services.reveal).not.toHaveBeenCalled();
    expect(services.warn).toHaveBeenCalledTimes(3);
    expect(services.warn.mock.calls[0][0]).toMatch(/which it isn't shown: refused$/);
  });

  it("hands each of the page's asks to its service, and a problem to the log", () => {
    const { host, services } = hostOn();
    host.show(PART);
    host.post({ type: 'export', uri: PART.uri, format: '3mf' });
    host.post({ type: 'screenshot', png: 'UE5H' });
    host.post({ type: 'reveal', uri: PART.uri, line: 2, column: 5 });
    host.post({ type: 'applyPreset', uri: PART.uri, name: 'Small' });
    host.post({ type: 'savePreset', uri: PART.uri, values: { w: 1 } });
    host.post({ type: 'setting', key: 'preview.params', value: 240 });
    host.post({ type: 'problem', message: 'the model has no parts' });
    expect(services.export).toHaveBeenCalledWith(PART.uri, '3mf');
    expect(services.screenshot).toHaveBeenCalledWith('UE5H');
    expect(services.reveal).toHaveBeenCalledWith(PART.uri, 2, 5);
    expect(services.applyPreset).toHaveBeenCalledWith(PART.uri, 'Small');
    expect(services.savePreset).toHaveBeenCalledWith(PART.uri, { w: 1 });
    expect(services.keepSetting).toHaveBeenCalledWith('preview.params', 240);
    expect(services.warn).toHaveBeenCalledWith('The page: the model has no parts');
  });

  it('gives values on its own (a preset), tells presets and the log, and says why a request failed', async () => {
    const { host, services, told, stop } = hostOn();
    services.server.setParams.mockRejectedValueOnce(new Error('the server stopped'));
    host.show(PART);
    host.setValues(PART.uri, { w: 1 });
    expect(told.at(-1)).toEqual({ type: 'overrides', uri: PART.uri, values: { w: 1 } });
    await settled();
    expect(services.fail).toHaveBeenCalledWith('Giving the values failed: the server stopped');
    // Another document's values are kept, and not shown
    host.setValues(LID.uri, { w: 2 });
    expect(told.at(-1)).toEqual({ type: 'overrides', uri: PART.uri, values: { w: 1 } });
    host.tellPresets(PART.uri, ['Small']);
    host.log('info(lsp): ready\n');
    expect(told.slice(-2)).toEqual([
      { type: 'presets', uri: PART.uri, names: ['Small'] },
      { type: 'log', text: 'info(lsp): ready\n' },
    ]);
    stop();
    host.log('more');
    expect(told.at(-1)).toEqual({ type: 'log', text: 'info(lsp): ready\n' });
  });

  it('decodes a screenshot from its base64', () => {
    expect([...pngBytes(btoa('PNG'))]).toEqual([80, 78, 71]);
  });
});
