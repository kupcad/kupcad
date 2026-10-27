// The test settings of a package of Svelte components (@kupcad/viewer, @kupcad/panels), which its
// Vitest config spreads, adding what jsdom needs set up first (`setupFiles`): the tests mount
// the components under jsdom, on models the real core makes. Typed where they are spread: the
// root has no Vitest of its own to type them by.

export const SVELTE_TESTS = {
  environment: 'jsdom',
  include: ['src/**/*.test.js'],
  // Imported by Node itself: under jsdom, Vite would make the module's URL of its wasm one its
  // dev server serves, and the tests run none
  server: { deps: { external: [/kupcad-wasm\/src/] } },
};
