// The app against the real kupcad (src/*.integration.js), apart from its unit tests: they need
// the core built (`zig build`), as CI's core job has it.

import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { include: ['src/**/*.integration.js'], environment: 'node' },
});
