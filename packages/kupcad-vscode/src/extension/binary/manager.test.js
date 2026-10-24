import { beforeEach, describe, expect, it } from 'vitest';
// The module Vitest gives the code as `vscode`
import { fake, memento, resetFake, window } from '../testing/vscode.js';
import { BinaryManager, UPDATE_EVERY_MS } from './manager.js';
import { RELEASES_PAGE } from './releases.js';

/** @import { Found } from './resolve.js' */
/** @import { Release } from './releases.js' */

const RANGE = '>=0.1.0 <0.2.0';
const NOW = 1_800_000_000_000;

/** @param {string} version @returns {Release} */
const release = (version) => ({ version, prerelease: version.includes('-'), assets: {} });

/**
 * A manager whose world the test sets: what is found, the releases listed, and what installing
 * does.
 * @param {{ found?: Found | null, notes?: string[], releases?: Release[], settings?: Record<string, unknown>, failInstall?: boolean }} [world]
 */
function managerIn(world = {}) {
  const installed = /** @type {string[]} */ ([]);
  const state = memento();
  let now = NOW;
  const manager = new BinaryManager({
    range: RANGE,
    managedDir: '/storage/bin',
    extensionPath: '/ext',
    state: /** @type {any} */ (state),
    log: /** @type {any} */ (window.createOutputChannel()),
    settings: () =>
      /** @type {any} */ ({
        get: (/** @type {string} */ key, /** @type {unknown} */ fallback) =>
          world.settings?.[key] ?? fallback,
      }),
    find: async () => ({ found: world.found ?? null, notes: world.notes ?? [] }),
    readReleases: async () => {
      if (!world.releases) throw new Error('offline');
      return { etag: null, releases: world.releases };
    },
    install: async (wanted, { progress }) => {
      if (world.failInstall) throw new Error("doesn't match its checksum");
      progress?.(50, 100);
      progress?.(100, 100);
      installed.push(wanted.version);
      return `/storage/bin/${wanted.version}/kupcad`;
    },
    now: () => now,
  });
  return {
    manager,
    installed,
    state,
    /** @param {number} ms */
    later: (ms) => {
      now += ms;
    },
  };
}

/**
 * A manager running its own install of 0.1.2, found, in the world given.
 * @param {Parameters<typeof managerIn>[0]} world
 */
async function runningOwn(world) {
  const found = {
    path: '/storage/bin/0.1.2/kupcad',
    version: '0.1.2',
    source: /** @type {const} */ ('managed'),
  };
  const running = managerIn({ found, ...world });
  await running.manager.server();
  return running;
}

beforeEach(() => resetFake());

describe('BinaryManager.server', () => {
  it('runs the kupcad found, and downloads nothing', async () => {
    const found = {
      path: '/usr/local/bin/kupcad',
      version: '0.1.2',
      source: /** @type {const} */ ('path'),
    };
    const { manager, installed } = managerIn({ found, releases: [release('0.1.5')] });
    expect(await manager.server()).toEqual(found);
    expect(installed).toEqual([]);
  });

  it('installs the newest release in range when none is found, its download shown', async () => {
    const { manager, installed } = managerIn({
      releases: [release('0.2.0'), release('0.1.4'), release('0.1.5-rc.1')],
    });
    expect(await manager.server()).toEqual({
      path: '/storage/bin/0.1.4/kupcad',
      version: '0.1.4',
      source: 'managed',
    });
    expect(installed).toEqual(['0.1.4']);
    expect(fake.progress).toEqual([
      { title: 'Downloading kupcad 0.1.4', reports: [{ increment: 50 }, { increment: 50 }] },
    ]);
  });

  it('takes a pre-release on the prerelease channel', async () => {
    const { manager } = managerIn({
      releases: [release('0.1.4'), release('0.1.5-rc.1')],
      settings: { 'binary.channel': 'prerelease' },
    });
    expect((await manager.server())?.version).toBe('0.1.5-rc.1');
  });

  it("says why it couldn't install one, and opens the releases page if asked", async () => {
    fake.answer = 'Open Releases';
    const { manager } = managerIn({ releases: [release('0.1.4')], failInstall: true });
    expect(await manager.server()).toBeNull();
    expect(fake.messages[0].text).toMatch(/couldn't be installed \(doesn't match its checksum\)/);
    await new Promise((resolve) => setTimeout(resolve));
    expect(fake.opened).toEqual([RELEASES_PAGE]);

    resetFake();
    const offline = managerIn();
    expect(await offline.manager.server()).toBeNull();
    expect(fake.messages[0].text).toMatch(/\(offline\)/);
  });

  it('runs the kupcad the setting names, with a word when it is out of range, and tells when it is none', async () => {
    const mine = {
      path: '/opt/kupcad',
      version: '0.3.0',
      source: /** @type {const} */ ('setting'),
    };
    const chosen = managerIn({
      found: mine,
      notes: ['kupcad.serverPath (/opt/kupcad) is kupcad 0.3.0'],
      settings: { serverPath: '/opt/kupcad' },
    });
    expect(await chosen.manager.server()).toEqual(mine);
    expect(fake.messages).toEqual([
      { level: 'warning', text: 'kupcad.serverPath (/opt/kupcad) is kupcad 0.3.0', buttons: [] },
    ]);

    resetFake();
    const broken = managerIn({
      notes: ['kupcad.serverPath (/opt/kupcad) is no kupcad executable'],
      settings: { serverPath: '/opt/kupcad' },
      releases: [release('0.1.4')],
    });
    expect(await broken.manager.server()).toBeNull();
    expect(broken.installed).toEqual([]);
    expect(fake.messages[0]).toMatchObject({ level: 'error', buttons: ['Open Settings'] });
  });
});

describe('BinaryManager.checkForUpdates', () => {
  it('installs a newer release in range at once, by default, and gives its path to run', async () => {
    const { manager, installed } = await runningOwn({
      releases: [release('0.1.3'), release('0.1.2')],
    });
    expect(await manager.checkForUpdates({ asked: false })).toBe('/storage/bin/0.1.3/kupcad');
    expect(installed).toEqual(['0.1.3']);
  });

  it('asks first without autoUpdate, and installs nothing the user leaves', async () => {
    const leaves = await runningOwn({
      releases: [release('0.1.3')],
      settings: { 'binary.autoUpdate': false },
    });
    expect(await leaves.manager.checkForUpdates({ asked: false })).toBeNull();
    expect(fake.messages[0]).toEqual({
      level: 'information',
      text: 'kupcad 0.1.3 is out (this is 0.1.2).',
      buttons: ['Update'],
    });

    fake.answer = 'Update';
    const takes = await runningOwn({
      releases: [release('0.1.3')],
      settings: { 'binary.autoUpdate': false },
    });
    expect(await takes.manager.checkForUpdates({ asked: false })).toBe('/storage/bin/0.1.3/kupcad');
  });

  it('looks once a day unless asked', async () => {
    const { manager, installed, later } = await runningOwn({ releases: [release('0.1.2')] });
    expect(await manager.checkForUpdates({ asked: false })).toBeNull();
    later(UPDATE_EVERY_MS / 2);
    expect(await manager.checkForUpdates({ asked: true })).toBeNull();
    expect(fake.messages.at(-1)?.text).toBe('kupcad 0.1.2 is the newest.');
    expect(installed).toEqual([]);
  });

  it('says a newer release out of range needs a newer extension', async () => {
    const { manager } = await runningOwn({ releases: [release('0.2.0'), release('0.1.2')] });
    expect(await manager.checkForUpdates({ asked: false })).toBeNull();
    expect(fake.messages[0].text).toMatch(
      /kupcad 0\.2\.0 is out, for a newer version of this extension/,
    );
  });

  it("leaves a kupcad that isn't its own, saying so when asked", async () => {
    const found = {
      path: '/usr/local/bin/kupcad',
      version: '0.1.0',
      source: /** @type {const} */ ('path'),
    };
    const { manager, installed } = managerIn({ found, releases: [release('0.1.9')] });
    await manager.server();
    expect(await manager.checkForUpdates({ asked: false })).toBeNull();
    expect(await manager.checkForUpdates({ asked: true })).toBeNull();
    expect(installed).toEqual([]);
    expect(fake.messages[0].text).toMatch(/isn't the extension's own/);
  });
});
