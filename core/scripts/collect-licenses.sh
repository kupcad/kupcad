#!/usr/bin/env bash
# collect-licenses.sh DEST
#
# Copies core/THIRD_PARTY_NOTICES.md and the license texts it names, at the paths it gives
# them, into DEST: what a release archive carries beside kupcad (package-release.sh), and a Ruby
# gem or a Python wheel beside libkupcad (the release's build job puts them beside the library).
# Run from the repository root, with the vendored libraries' submodules checked out.
set -euo pipefail

dest=$1

# The license files of the vendored libraries, and where THIRD_PARTY_NOTICES.md says they are
licenses=(
  "core/vendor/manifold/LICENSE:manifold"
  "core/vendor/oneTBB/LICENSE.txt:onetbb"
  "core/vendor/oneTBB/third-party-programs.txt:onetbb"
  "core/vendor/draco/LICENSE:draco"
  "core/vendor/eigen/LICENSE:eigen"
  "core/vendor/tatfi/LICENSE:tatfi"
  "core/vendor/harfbuzz/COPYING:harfbuzz"
  "core/vendor/harfbuzz/src/ms-use/COPYING:harfbuzz/ms-use"
  "core/vendor/sheenbidi/LICENSE:sheenbidi"
)

mkdir -p "$dest/licenses"
cp core/THIRD_PARTY_NOTICES.md "$dest/"
cp core/licenses/* "$dest/licenses/"
for entry in "${licenses[@]}"; do
  mkdir -p "$dest/licenses/${entry#*:}"
  cp "${entry%%:*}" "$dest/licenses/${entry#*:}/"
done
mkdir -p "$dest/licenses/eigen/LICENSES"
cp core/vendor/eigen/LICENSES/* "$dest/licenses/eigen/LICENSES/"
