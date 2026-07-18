#!/bin/bash

set -euo pipefail

readonly workspace="Larmindon.xcworkspace"
readonly scheme="Larmindon"
readonly bundle_id="com.davidedmiston.larmindon"
readonly derived_data=".build/DeviceDerivedData"
readonly app_path="${derived_data}/Build/Products/Debug-iphoneos/Larmindon.app"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

device_selector="${1:-${DEVICE:-}}"
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

if [[ -z "${device_selector}" ]]; then
  destinations="$({
    xcodebuild \
      -workspace "${workspace}" \
      -scheme "${scheme}" \
      -showdestinations
  } 2>/dev/null)"

  device_ids="$(
    printf '%s\n' "${destinations}" \
      | sed -nE 's/.*platform:iOS, arch:arm64, id:([^,]+), name:.*/\1/p'
  )"
  device_count="$(printf '%s\n' "${device_ids}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "${device_count}" != "1" ]]; then
    echo "Expected exactly one connected iOS device; found ${device_count}." >&2
    echo "Pass a device name or UDID explicitly:" >&2
    echo "  $0 \"My iPhone\"" >&2
    exit 1
  fi

  device_selector="${device_ids}"
fi

if [[ "${device_selector}" =~ ^[[:xdigit:]-]+$ ]]; then
  destination="platform=iOS,id=${device_selector}"
else
  destination="platform=iOS,name=${device_selector}"
fi

echo "Building ${scheme} for ${device_selector}..."
xcodebuild \
  -workspace "${workspace}" \
  -scheme "${scheme}" \
  -configuration Debug \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="${development_team}" \
  CODE_SIGN_STYLE=Automatic \
  -quiet \
  build

if [[ ! -d "${app_path}" ]]; then
  echo "Build succeeded, but the app was not found at ${app_path}." >&2
  exit 1
fi

echo "Installing ${scheme}..."
xcrun devicectl device install app \
  --device "${device_selector}" \
  "${app_path}"

echo "Launching ${scheme}..."
xcrun devicectl device process launch \
  --device "${device_selector}" \
  --terminate-existing \
  "${bundle_id}"

echo "Redeploy complete."
