import { expect, it } from 'vitest';
import { connectHost, hostSettings } from './bridge.js';

/** The host posts the page `data`, as a window message. @param {unknown} data */
const send = (data) => window.dispatchEvent(new MessageEvent('message', { data }));

it('posts what the page asks, and gives it what the host tells it, nothing else, until stopped', () => {
  /** @type {unknown[]} */
  const posted = [];
  const host = connectHost({ postMessage: (message) => posted.push(message) });
  host.post({ type: 'ready' });
  expect(posted).toEqual([{ type: 'ready' }]);

  /** @type {unknown[]} */
  const told = [];
  const stop = host.listen((message) => told.push(message));
  send({ type: 'document', document: null });
  send({ type: 'document' });
  send({ type: 'ready' });
  send('document');
  stop();
  send({ type: 'document', document: null });
  expect(told).toEqual([{ type: 'document', document: null }]);
});

it('keeps the settings the extension wrote in the page, and sends it each one changed', () => {
  const page = document.implementation.createHTMLDocument();
  page.head.innerHTML = '<meta name="kupcad-settings" content="{&quot;preview.params&quot;:320}">';
  /** @type {unknown[]} */
  const posted = [];
  const settings = hostSettings({ postMessage: (message) => posted.push(message) }, page);
  expect(settings.get('preview.params')).toBe(320);
  expect(settings.get('preview.paramsOpen')).toBeUndefined();
  settings.set('preview.paramsOpen', false);
  expect(settings.get('preview.paramsOpen')).toBe(false);
  expect(posted).toEqual([{ type: 'setting', key: 'preview.paramsOpen', value: false }]);
  // The view's choices are text, kept too: the page made again on each server start forgot them
  settings.set('view.renderMode', 'xray');
  expect(posted.at(-1)).toEqual({ type: 'setting', key: 'view.renderMode', value: 'xray' });
  // A value the extension wouldn't keep stays the page's
  settings.set('preview.note', { kept: 'here' });
  settings.set('preview.text', 'o'.repeat(65));
  expect(posted).toHaveLength(2);
  expect(settings.get('preview.note')).toEqual({ kept: 'here' });
});

it('starts with no settings where the page has none it reads', () => {
  for (const content of [null, '', 'not json', '[1]', 'null']) {
    const page = document.implementation.createHTMLDocument();
    if (content !== null) {
      const meta = page.createElement('meta');
      meta.name = 'kupcad-settings';
      meta.content = content;
      page.head.append(meta);
    }
    expect(hostSettings({ postMessage() {} }, page).get('preview.params')).toBeUndefined();
  }
});
