import { PROTOCOL_VERSION } from '@kupcad/protocol';
import { describe, expect, it, vi } from 'vitest';
import { fakeServer } from './fake-server.test-helper.js';
import { LanguageServer, RESTART_MS } from './server.js';

/** A server on `fake`, with what it told the app, and a clock the test moves. */
function serverOn(fake = fakeServer()) {
  const events = { viewport: vi.fn(), state: vi.fn(), log: vi.fn() };
  /** @type {(() => void)[]} */
  const timers = [];
  /** @type {number[]} */
  const waits = [];
  const later = /** @type {typeof setTimeout} */ (
    /** @type {unknown} */ (
      (/** @type {() => void} */ run, /** @type {number} */ ms) => {
        timers.push(run);
        waits.push(ms);
        return timers.length;
      }
    )
  );
  const server = new LanguageServer({
    rootUri: 'file:///w',
    origin: 'tauri://localhost',
    on: events,
    spawn: fake.spawn,
    setTimeout: later,
  });
  return { server, events, fake, timers, waits };
}

describe('the language server', () => {
  it("starts kupcad lsp for the page's origin, and the client initializes over its stdio", async () => {
    const { server, events, fake } = serverOn();
    await server.start();
    expect(fake.processes[0].origin).toBe('tauri://localhost');
    const initialize = fake.processes[0].received[0];
    expect(initialize).toMatchObject({ method: 'initialize', params: { rootUri: 'file:///w' } });
    expect(fake.processes[0].received[1]).toMatchObject({ method: 'initialized' });
    expect(events.state).toHaveBeenCalledWith(true);
    await vi.waitFor(() => expect(events.viewport).toHaveBeenCalledWith('ws://127.0.0.1:9001'));
  });

  it("asks the server to show a script, and to run it with the panel's values", async () => {
    const { server, fake } = serverOn();
    await server.start();
    await server.preview('file:///w/part.kup');
    await server.setParams('file:///w/part.kup', { width: 40 });
    const commands = fake.processes[0].received.filter(
      (message) => message.method === 'workspace/executeCommand',
    );
    expect(commands.map((message) => message.params)).toEqual([
      { command: 'kupcad.preview', arguments: [{ uri: 'file:///w/part.kup' }] },
      {
        command: 'kupcad.setParams',
        arguments: [{ uri: 'file:///w/part.kup', values: { width: 40 } }],
      },
    ]);
  });

  it('shows no viewport at what is no port, and says why', async () => {
    // It took whatever came: ws://127.0.0.1:undefined
    const { server, events } = serverOn(fakeServer({ port: /** @type {any} */ ('9001') }));
    await server.start();
    await vi.waitFor(() => expect(events.viewport).toHaveBeenCalledWith(null));
    expect(events.log).toHaveBeenCalledWith(
      "kupcad named no port for its viewport (9001): the model can't be shown",
    );
  });

  it('shows no viewport of a server that speaks another protocol, and says why', async () => {
    const { server, events } = serverOn(fakeServer({ protocolVersion: PROTOCOL_VERSION + 1 }));
    await server.start();
    await vi.waitFor(() => expect(events.viewport).toHaveBeenCalledWith(null));
    expect(events.log.mock.calls.at(-1)?.[0]).toMatch(/speaks protocol 2, and this app reads 1/);
  });

  it('starts a server that ended again, its client reconnected', async () => {
    const { server, events, fake, timers, waits } = serverOn();
    await server.start();
    fake.processes[0].on.exit(1);
    expect(events.state).toHaveBeenLastCalledWith(false);
    expect(events.viewport).toHaveBeenLastCalledWith(null);
    // Asked meanwhile, it says so at once
    await expect(server.preview('file:///w/part.kup')).rejects.toThrow(/isn't running/);
    expect(fake.processes).toHaveLength(1);
    timers[0]();
    await vi.waitFor(() => expect(events.state).toHaveBeenLastCalledWith(true));
    await server.preview('file:///w/part.kup');
    expect(fake.processes[1].received[0]).toMatchObject({ method: 'initialize' });
    // One that was up starts from the first wait again
    fake.processes[1].on.exit(1);
    expect(waits).toEqual([RESTART_MS.first, RESTART_MS.first]);
  });

  it('waits longer each time a server ends before it is up, and says it never was', async () => {
    const { server, fake, timers, waits } = serverOn(fakeServer({ answers: false }));
    const first = server.start();
    await vi.waitFor(() => expect(fake.processes).toHaveLength(1));
    fake.processes[0].on.exit(127);
    await expect(first).rejects.toThrow('kupcad lsp ended (code 127) before it was up');
    timers[0]();
    await vi.waitFor(() => expect(fake.processes).toHaveLength(2));
    fake.processes[1].on.exit(127);
    expect(waits).toEqual([RESTART_MS.first, RESTART_MS.first * 2]);
  });

  it('tries again, later each time, when the server it starts again fails to start', async () => {
    const fake = fakeServer();
    const spawn = fake.spawn;
    let refused = 0;
    fake.spawn = (origin, on) =>
      refused-- > 0 ? Promise.reject(new Error('no sidecar')) : spawn(origin, on);
    const { server, events, timers, waits } = serverOn(fake);
    await server.start();
    refused = 2;
    fake.processes[0].on.exit(1);
    timers[0]();
    await vi.waitFor(() => expect(timers).toHaveLength(2));
    expect(events.log).toHaveBeenCalledWith("kupcad lsp didn't start: Error: no sidecar");
    timers[1]();
    await vi.waitFor(() => expect(timers).toHaveLength(3));
    timers[2]();
    await vi.waitFor(() => expect(events.state).toHaveBeenLastCalledWith(true));
    expect(fake.processes).toHaveLength(2);
    expect(waits).toEqual([RESTART_MS.first, RESTART_MS.first * 2, RESTART_MS.first * 4]);
  });

  it('stops for good: the process killed, and not started again when it ends', async () => {
    const { server, fake, timers } = serverOn();
    await server.start();
    await server.stop();
    expect(fake.processes[0].killed).toBe(true);
    fake.processes[0].on.exit(0);
    expect(timers).toEqual([]);
    await expect(server.preview('file:///w/part.kup')).rejects.toThrow(/isn't running/);
  });
});
