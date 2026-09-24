#!/bin/bash

set -e

BASE_DIR=$(mktemp -d)
CURRENT_DIR=$(pwd)

echo "Temporary directory at $BASE_DIR"

APP_BUNDLE_PATH=$1
SIGNING_CERTIFICATE=$2
ENTITLEMENTS_PATH=$3
OUTPUT_FILE=$4

mkdir "$BASE_DIR/Payload"

cp -R "$APP_BUNDLE_PATH" "$BASE_DIR/Payload/"

# Sign inside-out: frameworks, then each embedded extension, then the main executable.
codesign -f -s "$SIGNING_CERTIFICATE" "$BASE_DIR/Payload/iCube.app/Frameworks/"*
EXTENSION_ENTITLEMENTS="$(dirname "$ENTITLEMENTS_PATH")/Extension.entitlements"
if [ -d "$BASE_DIR/Payload/iCube.app/PlugIns" ]; then
  for appex in "$BASE_DIR/Payload/iCube.app/PlugIns/"*.appex; do
    [ -e "$appex" ] || continue
    codesign -f -s "$SIGNING_CERTIFICATE" --entitlements "$EXTENSION_ENTITLEMENTS" "$appex"
  done
fi
codesign -f -s "$SIGNING_CERTIFICATE" --entitlements "$ENTITLEMENTS_PATH" "$BASE_DIR/Payload/iCube.app"

cd "$BASE_DIR"

zip -r "$OUTPUT_FILE" .

cd "$CURRENT_DIR"

echo "Cleaning up"

rm -rf "$BASE_DIR"

echo "Done"
