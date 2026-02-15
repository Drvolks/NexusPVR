#!/bin/bash
# Archive and upload NexusPVR + DispatcherPVR for iOS, tvOS, and macOS to TestFlight
#
# Requirements:
#   App Store Connect API key (.p8 file)
#   Apple Distribution certificate in local Keychain
#   Set these environment variables or edit the values below:
#     ASC_KEY_ID       - API Key ID
#     ASC_ISSUER_ID    - Issuer ID
#     ASC_KEY_PATH     - Path to AuthKey_XXXX.p8 file

set -e

# App Store Connect API key config
KEY_ID="${ASC_KEY_ID:?Set ASC_KEY_ID environment variable}"
ISSUER_ID="${ASC_ISSUER_ID:?Set ASC_ISSUER_ID environment variable}"
KEY_PATH="${ASC_KEY_PATH:?Set ASC_KEY_PATH environment variable}"

ARCHIVE_DIR=~/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)
EXPORT_DIR=/tmp/NexusPVR-export
PROJECT=NexusPVR.xcodeproj
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPORT_PLIST="$SCRIPT_DIR/ExportOptions.plist"

SCHEMES=(NexusPVR DispatcherPVR)
PLATFORMS=(iOS tvOS macOS)

AUTH_FLAGS=(-allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID")

rm -rf "$EXPORT_DIR"

# --- Bump build number once for all archives ---

cd "$SCRIPT_DIR"
CURRENT_BUILD=$(agvtool what-version -terse)
NEW_BUILD=$((CURRENT_BUILD + 1))
echo "=== Bumping build number: $CURRENT_BUILD → $NEW_BUILD ==="
agvtool new-version -all "$NEW_BUILD" > /dev/null

# --- Archive ---

for SCHEME in "${SCHEMES[@]}"; do
  for PLATFORM in "${PLATFORMS[@]}"; do
    echo "=== Archiving $SCHEME ($PLATFORM) ==="
    xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" \
      -destination "generic/platform=$PLATFORM" \
      -archivePath "$ARCHIVE_DIR/$SCHEME-$PLATFORM.xcarchive" \
      "${AUTH_FLAGS[@]}"
  done
done

# --- Export (sign for distribution) ---

for SCHEME in "${SCHEMES[@]}"; do
  for PLATFORM in "${PLATFORMS[@]}"; do
    echo "=== Exporting $SCHEME ($PLATFORM) ==="
    mkdir -p "$EXPORT_DIR/$SCHEME/$PLATFORM"
    xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_DIR/$SCHEME-$PLATFORM.xcarchive" \
      -exportOptionsPlist "$EXPORT_PLIST" \
      -exportPath "$EXPORT_DIR/$SCHEME/$PLATFORM" \
      "${AUTH_FLAGS[@]}"
  done
done

# --- Upload to TestFlight ---

for SCHEME in "${SCHEMES[@]}"; do
  for PLATFORM in "${PLATFORMS[@]}"; do
    echo "=== Uploading $SCHEME ($PLATFORM) to TestFlight ==="
    ARTIFACT=$(find "$EXPORT_DIR/$SCHEME/$PLATFORM" \( -name "*.ipa" -o -name "*.pkg" \) -print -quit)
    if [ -z "$ARTIFACT" ]; then
      echo "ERROR: No IPA/PKG found for $SCHEME ($PLATFORM) in $EXPORT_DIR/$SCHEME/$PLATFORM"
      exit 1
    fi

    case "$PLATFORM" in
      iOS)   TYPE=ios ;;
      tvOS)  TYPE=appletvos ;;
      macOS) TYPE=osx ;;
    esac

    xcrun altool --upload-app \
      -f "$ARTIFACT" \
      -t "$TYPE" \
      --apiKey "$KEY_ID" \
      --apiIssuer "$ISSUER_ID"
  done
done

echo "=== All schemes and platforms archived and uploaded to TestFlight ==="
