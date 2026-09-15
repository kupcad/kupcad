# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Fixed

- Fixed `VariationAxis.hidden` flag location. See `ttf-parser` PR: https://github.com/harfbuzz/ttf-parser/pull/216
- Fixed `VariationAxis.name_id` from using `u16` to `NameId` to be more concsitent with the rest of the library.
- Patched font not being outlined if it has 65563 glyphs: https://github.com/harfbuzz/ttf-parser/issues/213#issuecomment-4629493102
- Ignore the deprecated dotsection operator in CFF charstrings: https://github.com/harfbuzz/ttf-parser/pull/228
- Fixed off by one error in `set_variation`. Now you can use up to 64 variation axis in your fonts instead of 63.
- Fixed typo in `head` table `units_per_em` boundary.
- Fixed bug in `finish_contour` in `glyf` table. Thanks to Michael Pollind for the patch.

## 0.1.3 - 2026-04-16

Turns out 0.16.0 is just a one line change.

## 0.1.2 - 2026-03-27

Last update before Zig 0.16

### Fixed

- Expose `SequenceRule` and `ChainedSequenceRule` and added missing `parse` methods that were not checked before. Damn you lazy compilation
- Adjust `class_needle` paramter in `aat.ExtendedStateTable` to `u16` instead of `u8`. It doesn't really matter but it aligns better with `ttf-parser` API.

### Added

- Added default value for `ankr.Point`
- Added predefined_state in `apple_layout`
- Expose `LookupFlags` and added default init.
- Expose `Feature`
- `find_substitute` public method for `FeatureVariations`.
- `find_index` public method for `FeatureVariations`.
- Expose `Ligature`
- Expose the generic paramter of `LookupTable`s.

## 0.1.1 - 2026-02-02

### Added

- This Changelog
