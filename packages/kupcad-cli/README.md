# kupcad

[KupCAD](https://kupcad.org) is code-CAD in a Ruby-like language: a script is a model, built to
STL, 3MF, STEP, glTF, OBJ, SVG or DXF. This package is its command line, `kupcad`: build, run,
watch, check and format scripts, and the language server editors use.

```sh
npm install --global kupcad
kupcad build part.kup -o part.stl

# or, without installing
npx kupcad build part.kup -o part.stl
```

`kupcad --help` lists the commands. The language and the commands are documented at
<https://docs.kupcad.org>.

## How it is installed

`kupcad` is a native program. npm installs the build for your system as an optional dependency
of this package (`@kupcad/cli-darwin-arm64`, `-darwin-x64`, `-linux-arm64`, `-linux-x64`,
`-win32-arm64`, `-win32-x64`), and the `kupcad` command runs it. The Linux builds need glibc
2.28 or later; on a system npm has no build for, `kupcad` says so. Installing with optional
dependencies left out (`--omit=optional`) leaves no build to run.

The same builds are on [GitHub's releases](https://github.com/kupcad/kupcad/releases), each with
its licenses and a build attestation (`gh attestation verify <file> --repo kupcad/kupcad`).

## License

AGPL-3.0-only. The builds carry the licenses of the libraries they include
(`THIRD_PARTY_NOTICES.md`, `licenses/`).
