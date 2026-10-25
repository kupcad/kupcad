// What a failed `kupcad build` said of why, read from its output, for a host that runs it (the
// VS Code extension, the desktop app) to tell the person: the script's error, not the CLI's log.

/**
 * The lines of a failed build that say why, best first, each giving its words: an error the run
 * raised (its log line), a syntax or compile error at its place, the CLI's refusal, its summary.
 * The script's own output (`puts`, a warning) is none of them.
 */
const WHY = [
  /^error\([^)]*\):\s*(.+)$/,
  /^(.+:\d+:\d+: E: .+)$/,
  /^Error: (.+)$/,
  /^(\w+ failed: .+)$/,
];

/**
 * What a failed build said of why (`WHY`'s first line found), or null when it said nothing that
 * does.
 * @param {string} stderr
 * @returns {string | null}
 */
export function whyBuildFailed(stderr) {
  const lines = stderr.split('\n').map((line) => line.trim());
  for (const pattern of WHY) {
    for (const line of lines) {
      const said = pattern.exec(line);
      if (said) return said[1];
    }
  }
  return null;
}
