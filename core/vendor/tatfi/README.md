![alt text](tatfi.jpg "tatfi")

# `tatfi` - TTF parsing in Zig

`tatfi` is an almost state-less, almost allocation-free, high level font parser of `TTF`, `OTF` and `AAT` written in pure Zig. It has no dependencies outside of the Zig standard library. It aims to be completely safe and completely panic free. If you find it panics in any compilation mode, please report it as a bug.

The start point of the Library is the `Face` struct, with its different methods. However, the individual font tables can be accessd individually. Also, any additional tables should be able to be requested by `Tag`, (although I have not tested that yet.)

## `ttf_parser`

Almost the entire Rust ecosystem depends on [`ttf_parser`](https://docs.rs/ttf-parser/latest/ttf_parser/) by the venerable [RazrFalcom](https://github.com/RazrFalcon). Any large enough Rust project you can think of that involves text somehow includes `ttf_parser` in its dependency tree.

`tatfi` is an almost line-by-line port of `ttf-parser`. Obviously, Zig does not offer the same memory safety guarantees Rust does, but I promise I have done my best. More eyes on the code would be helpful in tightening the screws.

## Status

`tatfi` is pretty much complete as a port. It is possible to build a rasterizer or a shaper on top of `tatfi`. Future work of this library will be mostly keeping up with Zig releaes.

Many `ttf_parser` tests are ported (used to be all before a recent change in maintainership). Even so, the crate depended on `rustybuzz` (and from there, the `HarfBuzz` test suite), for testing. Without actual real use of this library it is not possible to test exhaustively.

As of Aug 6th, 2026, I do not plan on backporting bugfixes and tests from `ttf-parser` any more. The new maintainers are seemingly very active with long walls of text. If you find any bugs in real usage, please send them my way with a test case.

You can see the API surface on `main.zig`. If you'd like to help, please see any of the following topics.

### Fuzzing and Benchmarks

I am done adding unit tests and integration tests. I tried to add fuzzing using AFL++ (like ttf_parser does), but being on macOS makes me [fight the system incessantly](https://ziggit.dev/t/trouble-figuring-out-fuzzing-with-afl/13625/3?u=asibahi).

If you depend (or plan to depend) on the libraary, I would really appreciate help adding proper benchmarks and fuzzing infrastructure.

### C API

`ttf_parser` has a [minimal C API](https://github.com/harfbuzz/ttf-parser/blob/main/c-api/lib.rs). Porting that interface to this library would be nice, too. The C interface is also used in testing comparison with FreeType. The C++ code to set that part up is beyond my ability.

### Better Errors

For most of the public API, either the data is there or it is not. Considering for most uses the font file is what it is, the error type does not really matter, and so most of the public API returns optionals. However, in some places, like for example `Face.outline_glyph` and the different methods it calls, could give more speciic errors. For example a hypothetical `error.GlyphNotFound` vs `error.EmptyGlyph` (like a space, which is really fine..) would be helpful.

Going over the API either as a user or as a writer and identifying places for more helpful errors rather than returning optionals would be of great help.

## License

The originai `ttf-parser` is dual licensed under the MIT License and the Apache 2.0 License. _This_ library is, however, licensed under the Mozilla Public License 2.0.

## Why Host at sr.ht

I am trying to wean off Microsoft and the rest of the Torment Nexus due to [their aiding and abetting an active occupation and genocide](https://www.un.org/unispal/document/a-hrc-59-23-from-economy-of-occupation-to-economy-of-genocide-report-special-rapporteur-francesca-albanese-palestine-2025/). (Search for Microsoft)
