# Changesets

A change to a published package in `packages/` comes with a changeset: run `pnpm changeset`,
pick the packages and the kind of bump, and describe the change for their changelogs. The file
it writes here goes in the same commit. Releasing (`pnpm changeset version`, then publishing)
turns the changesets into version bumps and changelog entries.

The packages the site and other tools install (`@kupcad/protocol`, `wasm`, `viewer`, `ui`,
`editor` and `playground`) take no changesets: their version is the core's, published from the
release tag (the Release workflow's npm job).
Private packages (the VS Code extension, the apps) aren't versioned here.
