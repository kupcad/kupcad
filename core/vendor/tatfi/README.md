![alt text](tatfi.jpg "tatfi")

# `tatfi` - TTF parsing in Zig

`tatfi` is an almost state-less, almost allocation-free, high level font parser of `TTF`, `OTF` and `AAT` written in pure Zig. It has no dependencies outside of the Zig standard library. It aims to be completely safe and completely panic free. If you find it panics in any compilation mode, please report it as a bug.

The start point of the Library is the `Face` struct, with its different methods. However, the individual font tables can be accessed individually. Also, any additional tables should be able to be requested by `Tag`, (although I have not tested that yet.)

## `ttf_parser`

Almost the entire Rust ecosystem depends on [`ttf_parser`](https://docs.rs/ttf-parser/latest/ttf_parser/) by the venerable [RazrFalcon](https://github.com/RazrFalcon). Any large enough Rust project you can think of that involves text somehow includes `ttf_parser` in its dependency tree.

`tatfi` is an almost line-by-line port of `ttf-parser`. Obviously, Zig does not offer the same memory safety guarantees Rust does, but I promise I have done my best. More eyes on the code would be helpful in tightening the screws.

## Status

`tatfi` is pretty much complete as a port. It is possible to build a rasterizer or a shaper on top of `tatfi`. Future work of this library will be mostly keeping up with Zig releases.

Many `ttf_parser` tests are ported (used to be all before a recent change in maintainership). Even so, the crate depended on `rustybuzz` (and from there, the `HarfBuzz` test suite), for testing. Without actual real use of this library it is not possible to test exhaustively.

You can see the API surface on `main.zig`.

## Maintenance Note

For LLM-usage related reasons, I will no longer be backporting patches for the `ttf-parser` crate. Also due to LLMs I really do not enjoy coding anymore, so I no longer follow Zig releases and whatnot.

If you find any bugs or would like to upgrade the code to Zig's master branch or any future tagged release, please send in a patch.

If you'd like to add fuzzing or benchmarks or a C-API, please do not hesitate.

## License

The original `ttf-parser` is dual licensed under the MIT License and the Apache 2.0 License. _This_ library is, however, licensed under the Mozilla Public License 2.0.

## Why Host at sr.ht

I am trying to wean off Microsoft and the rest of the Torment Nexus due to [their aiding and abetting an active occupation and genocide](https://www.un.org/unispal/document/a-hrc-59-23-from-economy-of-occupation-to-economy-of-genocide-report-special-rapporteur-francesca-albanese-palestine-2025/). (Search for Microsoft)
