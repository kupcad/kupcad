#!/usr/bin/env bash
# package-release.sh VERSION BINARIES OUT
#
# Packages the kupcad binaries the release workflow built into the archives a GitHub release
# holds: BINARIES has a folder per archive, named <os>_<arch> (linux_amd64, windows_arm64, ...),
# holding that build's kupcad or kupcad.exe, and its debug information in symbols/. Each becomes
# OUT/kupcad_VERSION_<os>_<arch> (.zip for Windows, .tar.gz for the rest), with LICENSE,
# README.md, THIRD_PARTY_NOTICES.md and the license texts that file names, at the paths it
# gives, and its symbols OUT/kupcad_VERSION_<os>_<arch>_symbols; OUT/checksums.txt has the
# SHA-256 of each.
# Run from the repository root, with the vendored libraries' submodules checked out.
set -euo pipefail

version=$1
binaries=$2
out=$3

# The license files of the vendored libraries, and where THIRD_PARTY_NOTICES.md says they are
licenses=(
  "core/vendor/manifold/LICENSE:manifold"
  "core/vendor/Clipper2/LICENSE:clipper2"
  "core/vendor/oneTBB/LICENSE.txt:onetbb"
  "core/vendor/oneTBB/third-party-programs.txt:onetbb"
  "core/vendor/draco/LICENSE:draco"
  "core/vendor/eigen/LICENSE:eigen"
  "core/vendor/tatfi/LICENSE:tatfi"
)

mkdir -p "$out"
out=$(cd "$out" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

for build in "$binaries"/*/; do
  platform=$(basename "$build")
  name="kupcad_${version}_${platform}"
  dir="$stage/$name"
  mkdir -p "$dir/licenses"

  binary=$(find "$build" -maxdepth 1 -type f \( -name kupcad -o -name kupcad.exe \) | head -n 1)
  if [ -z "$binary" ]; then
    echo "error: no kupcad binary in $build" >&2
    exit 1
  fi
  cp "$binary" "$dir/"
  chmod +x "$dir/$(basename "$binary")"

  cp LICENSE README.md core/THIRD_PARTY_NOTICES.md "$dir/"
  cp core/licenses/* "$dir/licenses/"
  for entry in "${licenses[@]}"; do
    mkdir -p "$dir/licenses/${entry#*:}"
    cp "${entry%%:*}" "$dir/licenses/${entry#*:}/"
  done
  mkdir -p "$dir/licenses/eigen/LICENSES"
  cp core/vendor/eigen/LICENSES/* "$dir/licenses/eigen/LICENSES/"

  # The files at the archive's top level, by name (no "./" before each)
  if [[ $platform == windows_* ]]; then
    (cd "$dir" && zip -qr "$out/$name.zip" -- *)
  else
    (cd "$dir" && tar -czf "$out/$name.tar.gz" -- *)
  fi
  echo "packaged $name"

  # The debug information, for turning a crash report from this build into files and lines
  if [ -d "$build/symbols" ]; then
    if [[ $platform == windows_* ]]; then
      (cd "$build/symbols" && zip -qr "$out/${name}_symbols.zip" -- *)
    else
      (cd "$build/symbols" && tar -czf "$out/${name}_symbols.tar.gz" -- *)
    fi
    echo "packaged ${name}_symbols"
  fi
done

cd "$out"
if command -v sha256sum >/dev/null; then
  sha256sum kupcad_* > checksums.txt
else
  shasum -a 256 kupcad_* > checksums.txt
fi
cat checksums.txt
