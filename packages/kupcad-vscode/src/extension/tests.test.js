import { beforeEach, describe, expect, it } from 'vitest';
import { RUN_TEST_COMMAND, registerTestCommands, TERMINAL_NAME, testCommand } from './tests.js';
import { commands, documentAt, fake, resetFake, window } from './testing/vscode.js';

const TEST_URI = 'file:///work/bolt_test.kup';

/** @param {{ kupcad?: string | null }} [world] */
function registered(world = {}) {
  registerTestCommands({
    kupcad: () => (world.kupcad === undefined ? '/usr/local/bin/kupcad' : world.kupcad),
    log: /** @type {any} */ (window.createOutputChannel()),
  });
}

beforeEach(() => resetFake());

describe('run test', () => {
  it('runs the named test in the tests terminal, from the script’s folder, saving it first', async () => {
    const document = documentAt('/work/bolt_test.kup');
    document.isDirty = true;
    registered();
    await commands.executeCommand(RUN_TEST_COMMAND, { uri: TEST_URI, name: "a bolt's length" });
    expect(document.isDirty).toBe(false);
    expect(fake.terminals).toHaveLength(1);
    const terminal = fake.terminals[0];
    expect(terminal.name).toBe(TERMINAL_NAME);
    expect(terminal.cwd).toBe('/work');
    expect(terminal.shown).toBe(true);
    expect(terminal.sent).toEqual([
      "/usr/local/bin/kupcad test /work/bolt_test.kup --filter 'a bolt'\\''s length'",
    ]);
  });

  it('runs the whole file without a name, in the terminal it already has', async () => {
    documentAt('/work/bolt_test.kup');
    registered();
    await commands.executeCommand(RUN_TEST_COMMAND, { uri: TEST_URI, name: 'one' });
    await commands.executeCommand(RUN_TEST_COMMAND, { uri: TEST_URI });
    expect(fake.terminals).toHaveLength(1);
    expect(fake.terminals[0].sent[1]).toBe('/usr/local/bin/kupcad test /work/bolt_test.kup');
  });

  it('says so when no kupcad is running', async () => {
    documentAt('/work/bolt_test.kup');
    registered({ kupcad: null });
    await commands.executeCommand(RUN_TEST_COMMAND, { uri: TEST_URI });
    expect(fake.terminals).toHaveLength(0);
    expect(fake.messages[0].level).toBe('error');
  });

  it('quotes what the shell would read otherwise', () => {
    expect(testCommand('/opt/kup cad/kupcad', '/work/a b.kup', 'x')).toBe(
      "'/opt/kup cad/kupcad' test '/work/a b.kup' --filter x",
    );
  });
});
