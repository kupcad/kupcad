// The extension in a real VS Code (downloaded once into .vscode-test/), on the real kupcad lsp:
// the core's build, `zig build`, or the one KUPCAD names. VS Code runs test/suite.cjs in its
// extension host, on a copy of test/workspace/, with settings of its own; on Linux it needs a
// display (CI runs it under xvfb-run).

import { cpSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runTests } from '@vscode/test-electron';

const EXTENSION = fileURLToPath(new URL('..', import.meta.url));
const KUPCAD =
  process.env.KUPCAD ?? fileURLToPath(new URL('../../../core/zig-out/bin/kupcad', import.meta.url));

// Run from a process VS Code started (a task, an extension's terminal), Electron would run as
// Node, and take the workspace for a script
delete process.env.ELECTRON_RUN_AS_NODE;

const scratch = mkdtempSync(join(tmpdir(), 'kupcad-vscode-'));
try {
  const workspace = join(scratch, 'workspace');
  cpSync(fileURLToPath(new URL('workspace', import.meta.url)), workspace, { recursive: true });
  const userData = join(scratch, 'user-data');
  mkdirSync(join(userData, 'User'), { recursive: true });
  // Machine settings, which a workspace's can't set: this kupcad, and no update looked for
  writeFileSync(
    join(userData, 'User', 'settings.json'),
    JSON.stringify({
      'kupcad.serverPath': KUPCAD,
      'kupcad.binary.autoUpdate': false,
      'kupcad.viewport.port': 0,
      'security.workspace.trust.enabled': false,
    }),
  );
  await runTests({
    extensionDevelopmentPath: EXTENSION,
    extensionTestsPath: fileURLToPath(new URL('suite.cjs', import.meta.url)),
    extensionTestsEnv: { KUPCAD_WORKSPACE: workspace },
    launchArgs: [
      workspace,
      `--user-data-dir=${userData}`,
      `--extensions-dir=${join(scratch, 'extensions')}`,
      '--disable-extensions',
      '--skip-welcome',
      '--skip-release-notes',
    ],
  });
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
