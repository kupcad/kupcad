# KupCAD is a high-level, expression-based parametric CAD language [![Tests](https://github.com/kupcad/kupcad/actions/workflows/tests.yml/badge.svg)](https://github.com/kupcad/kupcad/actions/workflows/tests.yml)

## Work in progress

## Deps

```
zig build test -Dtest-filter="Point Segregation Bug"
```

```
brew install binaryen wabt wasmtime
wasm-opt --all-features -Oz kupcad.wasm -o kupcad_min.wasm
/opt/homebrew/opt/binaryen/bin/wasm-opt --all-features -Oz core/zig-out/bin/kupcad.wasm -o core/zig-out/bin/kupcad_min.wasm
```


## License

KupCAD is dual-licensed:

* **Open-Source:** Released under the [GNU Affero General Public License v3.0 (AGPLv3)](./LICENSE.txt).
* **Commercial:** For proprietary integrations, closed-source SaaS backends, or enterprise support, see our [Commercial Licensing Options](#).

> **Note on Model Output:** 3D files (STL, 3MF, STEP) exported by KupCAD belong 100% to you and are **not** subject to AGPL copyleft terms.

For common questions regarding commercial usage, derivative works, and contribution guidelines, read our [License FAQ](./LICENSE-FAQ.md) and [Contributor License Agreement (CLA)](./.github/CLA.md).
