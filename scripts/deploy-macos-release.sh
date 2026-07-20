#!/bin/bash

set -euo pipefail

readonly workspace="Larmindon.xcworkspace"
readonly scheme="Larmindon-macOS"
readonly architecture="$(uname -m)"
readonly derived_data=".build/MacReleaseDerivedData"
readonly built_app="${derived_data}/Build/Products/Release/Larmindon_macOS.app"
readonly installed_app="${HOME}/Larmindon_macOS.app"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Building ${scheme} in Release configuration..."
xcodebuild \
  -workspace "${workspace}" \
  -scheme "${scheme}" \
  -configuration Release \
  -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "${derived_data}" \
  -quiet \
  build

if [[ ! -d "${built_app}" ]]; then
  echo "Build succeeded, but the app was not found at ${built_app}." >&2
  exit 1
fi

echo "Verifying the built app..."
codesign --verify --deep --strict "${built_app}"

if [[ -L "${installed_app}" ]] || { [[ -e "${installed_app}" ]] && [[ ! -d "${installed_app}" ]]; }; then
  echo "Refusing to replace non-app destination: ${installed_app}" >&2
  exit 1
fi

staging_dir="$(mktemp -d "${HOME}/.larmindon-deploy.XXXXXX")"
readonly staging_dir
readonly staged_app="${staging_dir}/Larmindon_macOS.app"
readonly previous_app="${staging_dir}/previous-Larmindon_macOS.app"

cleanup() {
  if [[ -d "${staging_dir}" ]] && [[ "${staging_dir}" == "${HOME}/.larmindon-deploy."* ]]; then
    rm -rf -- "${staging_dir}"
  fi
}
trap cleanup EXIT

echo "Staging ${installed_app}..."
ditto "${built_app}" "${staged_app}"
codesign --verify --deep --strict "${staged_app}"

had_previous=false
if [[ -d "${installed_app}" ]]; then
  mv "${installed_app}" "${previous_app}"
  had_previous=true
fi

if ! mv "${staged_app}" "${installed_app}"; then
  if [[ "${had_previous}" == true ]] && [[ -d "${previous_app}" ]]; then
    mv "${previous_app}" "${installed_app}"
  fi
  echo "Install failed; the previous app was restored." >&2
  exit 1
fi

echo "Installed Release build at ${installed_app}."
