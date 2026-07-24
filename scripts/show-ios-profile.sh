#!/bin/bash

set -euo pipefail

readonly bundle_id="com.davidedmiston.larmindon"
readonly embedded_profile=".build/DeviceDerivedData/Build/Products/Debug-iphoneos/Larmindon.app/embedded.mobileprovision"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

plist_value() {
  local plist="$1"
  local key="$2"

  plutil -extract "${key}" raw -o - "${plist}" 2>/dev/null || true
}

format_date() {
  local iso_date="$1"
  local epoch

  epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "${iso_date}" '+%s')"
  date -r "${epoch}" '+%a %b %d %Y %H:%M:%S %Z'
}

expiration_status() {
  local expiration_date="$1"
  local expiration_epoch
  local now_epoch
  local remaining_seconds
  local days
  local hours

  expiration_epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "${expiration_date}" '+%s')"
  now_epoch="$(date '+%s')"
  remaining_seconds=$((expiration_epoch - now_epoch))

  if [[ ${remaining_seconds} -ge 0 ]]; then
    days=$((remaining_seconds / 86400))
    hours=$(((remaining_seconds % 86400) / 3600))
    printf 'VALID — %dd %dh remaining' "${days}" "${hours}"
  else
    remaining_seconds=$((-remaining_seconds))
    days=$((remaining_seconds / 86400))
    hours=$(((remaining_seconds % 86400) / 3600))
    printf 'EXPIRED — %dd %dh ago' "${days}" "${hours}"
  fi
}

last_uuid=""

show_profile() {
  local label="$1"
  local profile="$2"
  local decoded_profile
  local app_id
  local created
  local debuggable
  local expires
  local name
  local platform
  local profile_type
  local team
  local uuid
  local device_count

  decoded_profile="$(mktemp "${TMPDIR:-/tmp}/larmindon-profile.XXXXXX")"
  if ! openssl cms -verify -noverify -inform DER \
    -in "${profile}" -out "${decoded_profile}" >/dev/null 2>&1; then
    rm -f -- "${decoded_profile}"
    echo "Could not decode ${label}: ${profile}" >&2
    return 1
  fi

  app_id="$(plist_value "${decoded_profile}" 'Entitlements.application-identifier')"
  if [[ "${app_id}" != *."${bundle_id}" ]]; then
    rm -f -- "${decoded_profile}"
    return 2
  fi

  created="$(plist_value "${decoded_profile}" 'CreationDate')"
  debuggable="$(plist_value "${decoded_profile}" 'Entitlements.get-task-allow')"
  expires="$(plist_value "${decoded_profile}" 'ExpirationDate')"
  name="$(plist_value "${decoded_profile}" 'Name')"
  platform="$(plist_value "${decoded_profile}" 'Platform.0')"
  team="$(plist_value "${decoded_profile}" 'TeamIdentifier.0')"
  uuid="$(plist_value "${decoded_profile}" 'UUID')"
  device_count="$(
    plutil -extract ProvisionedDevices xml1 -o - "${decoded_profile}" 2>/dev/null \
      | grep -c '<string>' || true
  )"
  rm -f -- "${decoded_profile}"

  if [[ "${debuggable}" == "true" ]]; then
    profile_type="Development"
  else
    profile_type="Distribution"
  fi

  echo "${label}"
  printf '  Name:       %s\n' "${name}"
  printf '  UUID:       %s\n' "${uuid}"
  printf '  Type:       %s\n' "${profile_type}"
  printf '  Platform:   %s\n' "${platform}"
  printf '  Team:       %s\n' "${team}"
  printf '  App ID:     %s\n' "${app_id}"
  printf '  Devices:    %s\n' "${device_count}"
  printf '  Issued:     %s (%s)\n' "$(format_date "${created}")" "${created}"
  printf '  Expires:    %s (%s)\n' "$(format_date "${expires}")" "${expires}"
  printf '  Status:     %s\n' "$(expiration_status "${expires}")"
  echo

  last_uuid="${uuid}"
}

cache_count=0
cached_uuids=()
cache_dirs=(
  "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "${HOME}/Library/MobileDevice/Provisioning Profiles"
)

echo "Larmindon iOS provisioning profile status"
echo

for cache_dir in "${cache_dirs[@]}"; do
  [[ -d "${cache_dir}" ]] || continue

  for profile in "${cache_dir}"/*.mobileprovision "${cache_dir}"/*.provisionprofile; do
    [[ -f "${profile}" ]] || continue

    if show_profile "Cached profile" "${profile}"; then
      cache_count=$((cache_count + 1))
      cached_uuids+=("${last_uuid}")
    fi
  done
done

if [[ ${cache_count} -eq 0 ]]; then
  echo "Cached profile"
  echo "  Not found."
  echo
fi

embedded_uuid=""
if [[ -f "${embedded_profile}" ]]; then
  if show_profile "Embedded build profile" "${embedded_profile}"; then
    embedded_uuid="${last_uuid}"
  fi
else
  echo "Embedded build profile"
  echo "  Not found; run the device build first."
  echo
fi

if [[ -n "${embedded_uuid}" ]]; then
  match=false
  for cached_uuid in "${cached_uuids[@]}"; do
    if [[ "${embedded_uuid}" == "${cached_uuid}" ]]; then
      match=true
      break
    fi
  done

  if [[ "${match}" == true ]]; then
    echo "Result: embedded build profile matches the current cache."
  else
    echo "Result: embedded build profile does not match any current cached profile."
    exit 1
  fi
fi
