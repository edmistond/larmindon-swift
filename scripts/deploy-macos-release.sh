#!/bin/bash

set -euo pipefail

readonly workspace="Larmindon.xcworkspace"
readonly scheme="Larmindon-macOS"
readonly architecture="$(uname -m)"
readonly derived_data=".build/MacReleaseDerivedData"
readonly built_app="${derived_data}/Build/Products/Release/Larmindon_macOS.app"
readonly installed_app="${HOME}/Larmindon_macOS.app"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Sign with the Apple Development identity rather than ad hoc. An ad-hoc signature's
# designated requirement is the code hash, so TCC treats every rebuild as a new app and
# asks for microphone access again; a certificate-backed requirement is stable across
# builds. The free personal-team certificate is enough: the macOS target has no
# entitlements, so no provisioning profile is involved. Mirrors redeploy-device.sh.
development_team="${DEVELOPMENT_TEAM:-}"

if [[ -z "${development_team}" ]]; then
  identity_names="$(
    security find-identity -v -p codesigning \
      | sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p'
  )"
  identity_count="$(printf '%s\n' "${identity_names}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "${identity_count}" != "1" ]]; then
    echo "Expected exactly one Apple Development signing identity; found ${identity_count}." >&2
    echo "Set DEVELOPMENT_TEAM explicitly, for example:" >&2
    echo "  DEVELOPMENT_TEAM=YOURTEAMID $0" >&2
    exit 1
  fi

  certificate_subject="$(
    security find-certificate -c "${identity_names}" -p \
      | openssl x509 -noout -subject -nameopt RFC2253
  )"
  development_team="$(printf '%s\n' "${certificate_subject}" | sed -nE 's/.*OU=([^,]+).*/\1/p')"

  if [[ -z "${development_team}" ]]; then
    echo "Could not determine the development team from the signing certificate." >&2
    exit 1
  fi
fi
readonly development_team

echo "Building ${scheme} in Release configuration (team ${development_team})..."
xcodebuild \
  -workspace "${workspace}" \
  -scheme "${scheme}" \
  -configuration Release \
  -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "${derived_data}" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="${development_team}" \
  -quiet \
  build

if [[ ! -d "${built_app}" ]]; then
  echo "Build succeeded, but the app was not found at ${built_app}." >&2
  exit 1
fi

echo "Verifying the built app..."
codesign --verify --deep --strict "${built_app}"
if codesign -dv "${built_app}" 2>&1 | grep -q "Signature=adhoc"; then
  echo "The built app is still ad-hoc signed; TCC will re-prompt on every build." >&2
  exit 1
fi

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
