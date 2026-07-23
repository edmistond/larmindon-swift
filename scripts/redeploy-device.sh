#!/bin/bash

set -euo pipefail

readonly workspace="Larmindon.xcworkspace"
readonly scheme="Larmindon"
readonly bundle_id="com.davidedmiston.larmindon"
readonly derived_data=".build/DeviceDerivedData"
readonly app_path="${derived_data}/Build/Products/Debug-iphoneos/Larmindon.app"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  cat <<EOF
Usage: $0 [--refresh-profile] [device-name-or-UDID]

Options:
  --refresh-profile  Move cached Larmindon development profiles aside before
                     building so Xcode requests a newly issued profile.
  -h, --help         Show this help.
EOF
}

refresh_profile=false
device_selector="${DEVICE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh-profile)
      refresh_profile=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "${device_selector}" ]]; then
        echo "Only one device name or UDID may be specified." >&2
        usage >&2
        exit 1
      fi
      device_selector="$1"
      ;;
  esac
  shift
done

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

profile_originals=()
profile_backups=()
profile_backup_dir=""

restore_profiles() {
  local index

  for ((index = 0; index < ${#profile_originals[@]}; index++)); do
    if [[ -f "${profile_backups[index]}" ]]; then
      mkdir -p "$(dirname "${profile_originals[index]}")"
      mv "${profile_backups[index]}" "${profile_originals[index]}"
    fi
  done

  if [[ -n "${profile_backup_dir}" ]]; then
    rmdir "${profile_backup_dir}" 2>/dev/null || true
  fi
}

refresh_cached_profiles() {
  local cache_dir
  local decoded_profile
  local profile
  local profile_app_id
  local profile_debuggable
  local backup_path
  local backup_index=0
  local timestamp
  local -a cache_dirs

  cache_dirs=(
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
  )

  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  profile_backup_dir="${HOME}/Library/Application Support/Larmindon/Provisioning Profile Backups/${timestamp}"

  for cache_dir in "${cache_dirs[@]}"; do
    [[ -d "${cache_dir}" ]] || continue

    for profile in "${cache_dir}"/*.mobileprovision "${cache_dir}"/*.provisionprofile; do
      [[ -f "${profile}" ]] || continue

      decoded_profile="$(mktemp "${TMPDIR:-/tmp}/larmindon-profile.XXXXXX")"
      if ! openssl cms -verify -noverify -inform DER \
        -in "${profile}" -out "${decoded_profile}" >/dev/null 2>&1; then
        rm -f -- "${decoded_profile}"
        continue
      fi

      profile_app_id="$(
        /usr/libexec/PlistBuddy \
          -c 'Print :Entitlements:application-identifier' \
          "${decoded_profile}" 2>/dev/null || true
      )"
      profile_debuggable="$(
        /usr/libexec/PlistBuddy \
          -c 'Print :Entitlements:get-task-allow' \
          "${decoded_profile}" 2>/dev/null || true
      )"
      rm -f -- "${decoded_profile}"

      if [[ "${profile_app_id}" != "${development_team}.${bundle_id}" ]] \
        || [[ "${profile_debuggable}" != "true" ]]; then
        continue
      fi

      if [[ "${backup_index}" == 0 ]]; then
        mkdir -p "${profile_backup_dir}"
        chmod 700 "${profile_backup_dir}"
      fi

      backup_index=$((backup_index + 1))
      backup_path="${profile_backup_dir}/${backup_index}-$(basename "${profile}")"
      mv "${profile}" "${backup_path}"
      profile_originals+=("${profile}")
      profile_backups+=("${backup_path}")
    done
  done

  if [[ "${backup_index}" == 0 ]]; then
    profile_backup_dir=""
    echo "No matching cached profile was found; Xcode will request one during the build."
  else
    echo "Moved ${backup_index} cached Larmindon development profile(s) aside."
  fi
}

if [[ "${refresh_profile}" == true ]]; then
  echo "Profile refresh requires an Apple account in Xcode Settings > Accounts."
  echo "Forcing a fresh Larmindon development provisioning profile..."
  refresh_cached_profiles
fi

echo "Building ${scheme} for ${device_selector}..."
if ! xcodebuild \
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
    build; then
  if [[ "${refresh_profile}" == true ]] && [[ ${#profile_originals[@]} -gt 0 ]]; then
    echo "Build failed; restoring the previous provisioning profile." >&2
    restore_profiles
  fi
  exit 1
fi

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

if [[ -n "${profile_backup_dir}" ]]; then
  echo "Previous profile backup: ${profile_backup_dir}"
fi

echo "Redeploy complete."
