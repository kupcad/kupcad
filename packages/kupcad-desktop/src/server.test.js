import { PROTOCOL_VERSION } from '@kupcad/protocol';
import { describe, expect, it, vi } from 'vitest';
import { fakeServer } from './fake-server.test-helper.js';
import { LanguageServer, RESTART_MS } from './server.js';

/** A server on `fake`, with what it told the app, and a clock the test moves. */
function serverOn(fake = fakeServer(), memoryLimit = () => 8) {
  const events = { viewport: vi.fn(), state: vi.fn(), log: vi.fn(), progress: vi.fn() };
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
    memoryLimit,
    spawn: fake.spawn,
    setTimeout: later,
  });
  return { server, events, fake, timers, waits };
}

/**
 * What the server says of a build: its token asked for (a request), then its begin.
 * @param {string} token
 * @param {string} title
 */
const begun = (token, title) => [
  {
    jsonrpc: '2.0',
    id: `ask-${token}`,
    method: 'window/workDoneProgress/create',
    params: { token },
  },
  { jsonrpc: '2.0', method: '$/progress', params: { token, value: { kind: 'begin', title } } },
];
/** @param {string} token */
const ended = (token) => ({
  jsonrpc: '2.0',
  method: '$/progress',
  params: { token, value: { kind: 'end' } },
});
/** The titles the app was told, in order. @param {import('vitest').Mock} progress */
const told = (progress) => progress.mock.calls.map(([title]) => title);

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

  it('tells the server of files changed on disk, and nothing while it is down', async () => {
    const { server, fake } = serverOn();
    server.filesChanged([{ uri: 'file:///w/data.json', type: 2 }]);
    await server.start();
    server.filesChanged([]);
    server.filesChanged([{ uri: 'file:///w/data.json', type: 2 }]);
    await vi.waitFor(() =>
      expect(
        fake.processes[0].received.filter(
          (message) => message.method === 'workspace/didChangeWatchedFiles',
        ),
      ).toEqual([
        expect.objectContaining({
          params: { changes: [{ uri: 'file:///w/data.json', type: 2 }] },
        }),
      ]),
    );
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
    fake.spawn = (origin, memoryLimit, on) =>
      refused-- > 0 ? Promise.reject(new Error('no sidecar')) : spawn(origin, memoryLimit, on);
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

  it('stops for good: the process killed, the app told, and not started again when it ends', async () => {
    const { server, events, fake, timers } = serverOn();
    await server.start();
    await server.stop();
    expect(fake.processes[0].killed).toBe(true);
    expect(events.state).toHaveBeenLastCalledWith(false);
    expect(events.viewport).toHaveBeenLastCalledWith(null);
    fake.processes[0].on.exit(0);
    expect(timers).toEqual([]);
    await expect(server.preview('file:///w/part.kup')).rejects.toThrow(/isn't running/);
  });

  it('starts kupcad lsp under the memory limit set, and at once under a new one', async () => {
    let limit = 8;
    const { server, events, fake, timers } = serverOn(fakeServer(), () => limit);
    await server.start();
    expect(fake.processes[0].memoryLimit).toBe(8);
    limit = 32;
    await server.restart();
    expect(fake.processes[0].killed).toBe(true);
    expect(fake.processes[1].memoryLimit).toBe(32);
    // Started again on purpose, not after a crash: nothing waits, nothing says it ended
    fake.processes[0].on.exit(0);
    expect(timers).toEqual([]);
    expect(events.log).not.toHaveBeenCalledWith(expect.stringMatching(/ended/));
    await server.preview('file:///w/part.kup');
  });

  it('waits for a start under way to restart: the start succeeds, and one server runs', async () => {
    const { server, events, fake } = serverOn();
    const starting = server.start();
    const restarting = server.restart();
    await expect(starting).resolves.toBeUndefined();
    await restarting;
    expect(fake.processes.map((p) => p.killed)).toEqual([true, false]);
    expect(events.log).not.toHaveBeenCalled();
    await server.preview('file:///w/part.kup');
  });

  it('runs restarts asked together one after another: one server runs at the end', async () => {
    let limit = 8;
    const { server, fake } = serverOn(fakeServer(), () => limit);
    await server.start();
    limit = 32;
    await Promise.all([server.restart(), server.restart()]);
    expect(fake.processes.filter((p) => !p.killed)).toHaveLength(1);
    expect(fake.processes.at(-1)?.memoryLimit).toBe(32);
  });

  it('stops a server being started again at once, waiting for it to be up no longer', async () => {
    const fake = fakeServer();
    const { server, events, timers } = serverOn(fake);
    await server.start();
    fake.processes[0].on.exit(1);
    // The one started again never answers
    fake.answers = false;
    timers[0]();
    await vi.waitFor(() => expect(fake.processes).toHaveLength(2));
    await server.stop();
    expect(fake.processes[1].killed).toBe(true);
    expect(events.state).toHaveBeenLastCalledWith(false);
    expect(events.viewport).toHaveBeenLastCalledWith(null);
    // Nothing more: no start again, no word of the start the stop cut short
    await new Promise((resolve) => setTimeout(resolve));
    expect(timers).toHaveLength(1);
    expect(events.log).not.toHaveBeenCalledWith(expect.stringMatching(/didn't start/));
  });

  it('kills the server a stop finds still being spawned, which no one would own', async () => {
    const fake = fakeServer();
    const spawn = fake.spawn;
    /** Lets the spawn under way go on, once there is one. @type {((value?: unknown) => void)[]} */
    const spawning = [];
    fake.spawn = async (origin, memoryLimit, on) => {
      await new Promise((resolve) => spawning.push(resolve));
      return spawn(origin, memoryLimit, on);
    };
    const { server, events } = serverOn(fake);
    const starting = server.start();
    await vi.waitFor(() => expect(spawning).toHaveLength(1));
    const stopping = server.stop();
    spawning[0]();
    await expect(starting).rejects.toThrow('kupcad lsp was stopped before it was up');
    await stopping;
    expect(fake.processes[0].killed).toBe(true);
    expect(events.state).not.toHaveBeenCalled();
    await expect(server.preview('file:///w/part.kup')).rejects.toThrow(/isn't running/);
  });

  describe("tells the server's long work", () => {
    it('saying it takes it, its token granted, from begin to end, the newest of several shown', async () => {
      const { server, events, fake } = serverOn();
      await server.start();
      const [process] = fake.processes;
      expect(process.received[0].params.capabilities.window).toMatchObject({
        workDoneProgress: true,
      });
      for (const message of [...begun('1', 'Building a.kup'), ...begun('2', 'Building b.kup')]) {
        process.tell(message);
      }
      await vi.waitFor(() =>
        expect(told(events.progress)).toEqual(['Building a.kup', 'Building b.kup']),
      );
      expect(process.received).toContainEqual({ jsonrpc: '2.0', id: 'ask-1', result: null });
      expect(process.received).toContainEqual({ jsonrpc: '2.0', id: 'ask-2', result: null });
      process.tell(ended('2'));
      await vi.waitFor(() => expect(events.progress).toHaveBeenCalledTimes(3));
      process.tell(ended('1'));
      await vi.waitFor(() => expect(events.progress).toHaveBeenCalledTimes(4));
      expect(told(events.progress).slice(2)).toEqual(['Building a.kup', null]);
    });

    it('as over when the server ends or is restarted, whose ends never come', async () => {
      const { server, events, fake, timers } = serverOn();
      await server.start();
      for (const message of begun('1', 'Building part.kup')) fake.processes[0].tell(message);
      await vi.waitFor(() => expect(told(events.progress)).toEqual(['Building part.kup']));
      await server.restart();
      expect(told(events.progress)).toEqual(['Building part.kup', null]);
      for (const message of begun('1', 'Building part.kup')) fake.processes[1].tell(message);
      await vi.waitFor(() => expect(events.progress).toHaveBeenCalledTimes(3));
      fake.processes[1].on.exit(1);
      expect(told(events.progress)).toEqual(['Building part.kup', null, 'Building part.kup', null]);
      expect(timers).toHaveLength(1);
    });
  });
});
