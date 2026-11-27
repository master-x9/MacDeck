#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl --fail --location --silent --show-error https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz -o "$tmp/Sparkle.tar.xz"
(cd "$tmp" && echo '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  Sparkle.tar.xz' | shasum -a 256 -c -)
mkdir -p Vendor/Sparkle
tar -xf "$tmp/Sparkle.tar.xz" -C Vendor/Sparkle
