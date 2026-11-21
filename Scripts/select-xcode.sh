#!/usr/bin/env bash
# Selects the newest installed Xcode 26+ toolchain on macOS CI runners.
set -euo pipefail

candidates=()
shopt -s nullglob
for app in /Applications/Xcode_27*.app /Applications/Xcode_26*.app /Applications/Xcode.app; do
  if [[ -d "$app/Contents/Developer" ]]; then
    candidates+=("$app")
  fi
done
shopt -u nullglob

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "::error::No Xcode 26+ install found on ${RUNNER_NAME:-$(hostname)}" >&2
  ls /Applications | grep -i xcode >&2 || true
  exit 1
fi

# Sort versioned Xcode bundles descending (newest first), keeping /Applications/Xcode.app as fallback.
selected=""
while IFS= read -r app; do
  if [[ -n "$app" ]]; then
    selected="$app"
    break
  fi
done < <(
  for app in "${candidates[@]}"; do
    base=$(basename "$app" .app)
    if [[ "$base" == "Xcode" ]]; then
      printf '0000\t%s\n' "$app"
    else
      ver=${base#Xcode_}
      printf '%s\t%s\n' "$ver" "$app"
    fi
  done | sort -t $'\t' -k1,1Vr | cut -f2
)

if [[ -z "$selected" ]]; then
  echo "::error::Failed to select an Xcode installation" >&2
  exit 1
fi

sudo xcode-select -s "$selected/Contents/Developer"
echo "Selected $selected"
xcodebuild -version
