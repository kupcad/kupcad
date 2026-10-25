import { defineConfig, devices } from '@playwright/test';
import { PORT } from './dev/vite.config.js';

const url = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: 'smoke',
  forbidOnly: !!process.env.CI,
  // The page as it is built, the core's worker and module bundled as a site's visitor gets them
  use: {
    ...devices['Desktop Chrome'],
    baseURL: url,
    // Headless Chromium draws WebGL in software (SwiftShader), which CI's machines need
    launchOptions: { args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] },
  },
  webServer: {
    command: 'vite build --config dev/vite.config.js && vite preview --config dev/vite.config.js',
    url,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
