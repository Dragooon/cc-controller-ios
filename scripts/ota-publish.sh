#!/usr/bin/env bash
# Publishes an install package built by the "Signed install" workflow: downloads the run's artifact, unseals it
# with the private key from 1Password, writes the manifest and install page, and serves it from the host.
# Needs gh, op, openssl and curl; runs on the host, which has no Xcode.
#
#   scripts/ota-publish.sh <run-id>
#
# CC_OTA_ROOT is the served directory (default /var/lib/cc-ota/cc), CC_OTA_HOST the host's HTTPS name (default
# its tailnet name), CC_OTA_KEY_REF the 1Password reference of the private key. --no-verify skips the HTTPS check,
# for trying this out against a scratch directory.
set -euo pipefail

repo=${CC_OTA_REPO:-Dragooon/cc-controller-ios}
root=${CC_OTA_ROOT:-/var/lib/cc-ota/cc}
key_ref=${CC_OTA_KEY_REF:-op://Private/cc-controller-ios install key/notesPlain}
keep_builds=3

verify=1
run_id=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-verify) verify=0; shift ;;
    *) run_id=$1; shift ;;
  esac
done
[[ "$run_id" =~ ^[0-9]+$ ]] || { printf 'usage: %s <run-id> [--no-verify]\n' "$0" >&2; exit 2; }

host=${CC_OTA_HOST:-$(tailscale status --json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')}
[[ -n "$host" ]] || { printf '%s\n' 'could not work out the host name; set CC_OTA_HOST' >&2; exit 2; }
[[ -w "$root" ]] || { printf '%s is not writable\n' "$root" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
gh run download "$run_id" -R "$repo" -n install-package -D "$work/sealed"
mkdir "$work/package"
openssl pkeyutl -decrypt -inkey <(op read "$key_ref") -pkeyopt rsa_padding_mode:oaep \
  -in "$work/sealed/install.key.enc" -out "$work/key"
openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -pass "file:$work/key" -in "$work/sealed/install.tar.enc" \
  | tar -C "$work/package" --no-same-owner --no-same-permissions -xf -

package_value() {
  sed -n "s/^$1=//p" "$work/package/package.env"
}
build=$(package_value build)
bundle=$(package_value bundle)
version=$(package_value version)
sha=$(package_value sha)
built=$(package_value built)
[[ "$build" =~ ^[0-9]+$ ]] || { printf 'bad build number in the package: %s\n' "$build" >&2; exit 1; }
[[ "$bundle" =~ ^[A-Za-z0-9.-]+$ ]] || { printf 'bad bundle ID in the package: %s\n' "$bundle" >&2; exit 1; }
[[ "$version" =~ ^[0-9.]+$ ]] || { printf 'bad version in the package: %s\n' "$version" >&2; exit 1; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { printf 'bad commit in the package: %s\n' "$sha" >&2; exit 1; }
[[ "$built" =~ ^[0-9:\ -]+UTC$ ]] || { printf 'bad build date in the package: %s\n' "$built" >&2; exit 1; }
for file in CCController.ipa AppIcon57.png AppIcon512.png; do
  [[ -f "$work/package/$file" ]] || { printf 'the package has no %s\n' "$file" >&2; exit 1; }
done
[[ ! -e "$root/$build" ]] || { printf 'build %s is already published\n' "$build" >&2; exit 2; }

base_url="https://$host/cc/$build"
staging="$root/.staging-$build"
mkdir "$staging"
cp "$work/package/CCController.ipa" "$work/package/AppIcon57.png" "$work/package/AppIcon512.png" "$staging/"
cat > "$staging/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>$base_url/CCController.ipa</string>
        </dict>
        <dict>
          <key>kind</key>
          <string>display-image</string>
          <key>url</key>
          <string>$base_url/AppIcon57.png</string>
        </dict>
        <dict>
          <key>kind</key>
          <string>full-size-image</string>
          <key>url</key>
          <string>$base_url/AppIcon512.png</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>$bundle</string>
        <key>bundle-version</key>
        <string>$build</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>cc-controller</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
cat > "$staging/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cc-controller build $build</title>
<p><a style="font: bold 2em system-ui" href="itms-services://?action=download-manifest&url=$base_url/manifest.plist">Install cc-controller</a></p>
<p>Build $build, version $version, commit ${sha:0:7}</p>
<p>Build date: $built</p>
HTML
chmod -R a+rX "$staging"
mv "$staging" "$root/$build"
cp "$root/$build/index.html" "$root/.latest.html"
chmod a+r "$root/.latest.html"
mv "$root/.latest.html" "$root/latest.html"

for old in $(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -E '^[0-9]+$' | sort -rn | tail -n +$((keep_builds + 1))); do
  rm -rf -- "${root:?}/$old"
  printf 'deleted old build %s\n' "$old"
done

if (( verify )); then
  address=$(tailscale ip -4)
  for path in "$build/manifest.plist" "$build/CCController.ipa" "$build/AppIcon57.png" "$build/AppIcon512.png" latest.html; do
    code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --resolve "$host:443:$address" "https://$host/cc/$path")
    [[ "$code" == 200 ]] || { printf 'https://%s/cc/%s returned %s\n' "$host" "$path" "$code" >&2; exit 1; }
  done
fi
printf 'published build %s: https://%s/cc/latest.html\n' "$build" "$host"
