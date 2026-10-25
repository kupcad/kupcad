import { defineConfig, devices } from '@playwright/test';
import { PORT } from './astro.config.mjs';

const url = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: 'smoke',
  forbidOnly: !!process.env.CI,
  // The site as it is built, the core's worker and module bundled as a visitor gets them
  use: {
    ...devices['Desktop Chrome'],
    baseURL: url,
    // Headless Chromium draws WebGL in software (SwiftShader), which CI's machines need
    launchOptions: { args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] },
  },
  webServer: {
    // A one-off server in the foreground, for Playwright to stop: Astro runs `preview` in the
    // background where it thinks an agent called it, unless told so
    command: 'astro build && astro preview --ignore-lock',
    url,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
