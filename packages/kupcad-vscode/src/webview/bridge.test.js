import { expect, it } from 'vitest';
import { connectHost } from './bridge.js';

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
