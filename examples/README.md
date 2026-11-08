# Examples

Complete KupCAD models, each a script of its own: a cup, a hinge, a planetary gearbox and more.
Each begins with its title and description (`# @title`, `# @description`) and builds with
`kupcad build <name>.kup -o <name>.stl`. The core's tests build every one of them
(`core/src/examples_test.zig`), so they stay working as the language changes.

The [docs' gallery](https://docs.kupcad.org/examples/) shows them with their pictures, and the
[website's playground](https://kupcad.org) offers them; both keep copies of these files.

## License

These examples are MIT-licensed ([LICENSE](./LICENSE)), unlike the rest of KupCAD (AGPLv3):
copy them, change them and use them in your own projects, commercial ones too.
