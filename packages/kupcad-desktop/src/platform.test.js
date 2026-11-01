// The app's platform on Tauri (platform.js), Tauri's modules stand-ins: what it asks of each,
// and what it makes of what they give back.

import { beforeEach, describe, expect, it, vi } from 'vitest';

const tauri = vi.hoisted(() => {
  /** A native menu: the items it was made with, closed once it is let go. */
  class FakeMenu {
    /** @param {{ items: unknown[] }} options */
    constructor(options) {
      this.items = options.items;
      this.closed = false;
    }
    async close() {
      this.closed = true;
    }
    async popup() {}
    /** Set as the app's menu: the one it replaces given back, as Tauri's is. */
    async setAsAppMenu() {
      const replaced = tauri.appMenu;
      tauri.appMenu = this;
      return replaced;
    }
  }
  return {
    FakeMenu,
    /** @type {FakeMenu | null} */
    appMenu: null,
    /** What each Menu.new waits for before it makes its menu, when set. */
    /** @type {Promise<void> | null} */
    menuDelay: null,
    invoke: vi.fn(),
    setTheme: vi.fn(),
    setZoom: vi.fn(),
    /** @type {((event: { preventDefault(): void }) => Promise<void>) | null} */
    closeHandler: null,
    store: { entries: vi.fn(), set: vi.fn() },
    load: vi.fn(),
    check: vi.fn(),
    relaunch: vi.fn(),
  };
});

vi.mock('@tauri-apps/api/core', () => ({ invoke: tauri.invoke }));
vi.mock('@tauri-apps/api/menu/menu', () => ({
  Menu: {
    /** @param {{ items: unknown[] }} options */
    async new(options) {
      const delay = tauri.menuDelay;
      if (delay) await delay;
      return new tauri.FakeMenu(options);
    },
  },
}));
vi.mock('@tauri-apps/api/webview', () => ({
  getCurrentWebview: () => ({ setZoom: tauri.setZoom }),
}));
vi.mock('@tauri-apps/api/window', () => ({
  getCurrentWindow: () => ({
    setTheme: tauri.setTheme,
    /** @param {(event: { preventDefault(): void }) => Promise<void>} handler */
    async onCloseRequested(handler) {
      tauri.closeHandler = handler;
      return () => {};
    },
  }),
}));
// The rest of each as it is: folder.js, which platform.js uses, reads more of them
vi.mock('@tauri-apps/plugin-dialog', async (original) => ({
  ...(await original()),
  confirm: vi.fn(),
  message: vi.fn(),
  save: vi.fn(),
}));
vi.mock('@tauri-apps/plugin-fs', async (original) => ({
  ...(await original()),
  readDir: vi.fn(),
  writeFile: vi.fn(),
}));
vi.mock('@tauri-apps/plugin-process', () => ({ relaunch: tauri.relaunch }));
vi.mock('@tauri-apps/plugin-store', () => ({ load: tauri.load }));
vi.mock('@tauri-apps/plugin-updater', () => ({ check: tauri.check }));

const { tauri: platform } = await import('./platform.js');

/** A promise and what resolves it (Promise.withResolvers is past the library this targets). */
function deferred() {
  /** @type {(() => void) | undefined} */
  let resolve;
  const promise = new Promise((done) => {
    resolve = () => done(undefined);
  });
  return { promise: /** @type {Promise<void>} */ (promise), resolve: () => resolve?.() };
}

beforeEach(() => {
  vi.clearAllMocks();
  tauri.menuDelay = null;
});

describe('the menus', () => {
  it("are Tauri's items: separators, the system's own, submenus, and items that act", async () => {
    const action = vi.fn();
    await platform.setMenu([
      {
        text: 'KupCAD',
        items: [{ predefined: 'About' }, '-', { predefined: 'Quit' }],
      },
      { text: 'Export…', accelerator: 'CmdOrCtrl+E', action },
      { text: 'Undo', enabled: false, action },
    ]);
    const menu = /** @type {InstanceType<typeof tauri.FakeMenu>} */ (tauri.appMenu);
    const [app, exportItem, disabled] = /** @type {any[]} */ (menu.items);
    expect(app).toEqual({
      text: 'KupCAD',
      items: [{ item: { About: { name: 'KupCAD' } } }, { item: 'Separator' }, { item: 'Quit' }],
    });
    expect(exportItem).toMatchObject({
      text: 'Export…',
      accelerator: 'CmdOrCtrl+E',
      enabled: true,
    });
    expect(disabled.enabled).toBe(false);
    exportItem.action();
    expect(action).toHaveBeenCalledOnce();
  });

  it('are the last asked for, the menu they replace let go, and one asked for before them too', async () => {
    const before = tauri.appMenu;
    const delay = deferred();
    tauri.menuDelay = delay.promise;
    const first = platform.setMenu([{ text: 'first', action: () => {} }]);
    tauri.menuDelay = null;
    await platform.setMenu([{ text: 'second', action: () => {} }]);
    const second = /** @type {InstanceType<typeof tauri.FakeMenu>} */ (tauri.appMenu);
    expect(before?.closed).toBe(true);
    delay.resolve();
    await first;
    // The first, made last, is let go, not set over the second
    expect(tauri.appMenu).toBe(second);
    expect(/** @type {any} */ (second.items[0]).text).toBe('second');
  });

  it('pop up one at a time, the last let go when the next shows', async () => {
    const popup = vi.spyOn(tauri.FakeMenu.prototype, 'popup');
    await platform.popupMenu([{ text: 'Rename', action: () => {} }]);
    const shown = /** @type {InstanceType<typeof tauri.FakeMenu>} */ (popup.mock.contexts[0]);
    expect(shown.closed).toBe(false);
    await platform.popupMenu([{ text: 'Delete', action: () => {} }]);
    expect(shown.closed).toBe(true);
    expect(popup).toHaveBeenCalledTimes(2);
  });
});

describe('the settings', () => {
  it("are the store's, and each change is written to it", async () => {
    tauri.store.entries.mockResolvedValue([['viewer.size', 0.4]]);
    tauri.load.mockResolvedValue(tauri.store);
    const settings = await platform.settings();
    expect(tauri.load).toHaveBeenCalledWith('settings.json', { defaults: {}, autoSave: 250 });
    expect(settings.get('viewer.size')).toBe(0.4);
    settings.set('console.open', true);
    expect(settings.get('console.open')).toBe(true);
    expect(tauri.store.set).toHaveBeenCalledWith('console.open', true);
  });
});

describe('an update', () => {
  it('is none when the releases have nothing newer', async () => {
    tauri.check.mockResolvedValue(null);
    expect(await platform.checkUpdate()).toBeNull();
  });

  it('says its version and ours, installs and then restarts, or is let go', async () => {
    const steps = /** @type {string[]} */ ([]);
    const update = {
      version: '0.2.0',
      currentVersion: '0.1.7',
      downloadAndInstall: vi.fn(async () => void steps.push('installed')),
      close: vi.fn(),
    };
    tauri.check.mockResolvedValue(update);
    tauri.relaunch.mockImplementation(async () => void steps.push('restarted'));
    const found = await platform.checkUpdate();
    expect(found).toMatchObject({ version: '0.2.0', current: '0.1.7' });
    await found?.install();
    expect(steps).toEqual(['installed', 'restarted']);
    await found?.dismiss();
    expect(update.close).toHaveBeenCalledOnce();
  });
});

describe('the window', () => {
  it('stays open when it may not close, and closes when it may', async () => {
    let may = false;
    await platform.onClose(async () => may);
    const event = { preventDefault: vi.fn() };
    await tauri.closeHandler?.(event);
    expect(event.preventDefault).toHaveBeenCalledOnce();
    may = true;
    await tauri.closeHandler?.(event);
    expect(event.preventDefault).toHaveBeenCalledOnce();
  });

  it("follows the system's theme when the app's is the system's", async () => {
    await platform.setTheme('system');
    expect(tauri.setTheme).toHaveBeenCalledWith(null);
    await platform.setTheme('dark');
    expect(tauri.setTheme).toHaveBeenLastCalledWith('dark');
  });

  it('asks the native side for its commands by name', async () => {
    await platform.trash('/w/old.kup');
    expect(tauri.invoke).toHaveBeenCalledWith('move_to_trash', { path: '/w/old.kup' });
    await platform.exportModel('/w/a.kup', '/w/a.stl', 'stl', [['w', '5']], 8);
    expect(tauri.invoke).toHaveBeenLastCalledWith('export_model', {
      script: '/w/a.kup',
      output: '/w/a.stl',
      format: 'stl',
      params: [['w', '5']],
      memoryLimit: 8,
    });
  });
});
