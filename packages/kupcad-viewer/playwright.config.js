import { defineConfig, devices } from '@playwright/test';
import { PORT } from './smoke/vite.config.js';

const url = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: 'smoke',
  forbidOnly: !!process.env.CI,
  use: {
    ...devices['Desktop Chrome'],
    baseURL: url,
    // Headless Chromium draws WebGL in software (SwiftShader), which CI's machines need
    launchOptions: { args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] },
  },
  webServer: {
    command: 'vite --config smoke/vite.config.js',
    url,
    reuseExistingServer: !process.env.CI,
  },
});
