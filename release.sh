#!/bin/bash
# Produce Developer-ID signed, notarized, stapled, checksummed product
# ZIP and drag-to-Applications DMG artifacts.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/product-identity.sh

APP="$PRODUCT_APP_BUNDLE"
TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
PROJECT_VERSION="$(tr -d '[:space:]' < VERSION)"
VERSION="$(product_env_value VERSION "${TAG#v}")"
VERSION="${VERSION:-$PROJECT_VERSION}"
VERSION="${VERSION#v}"
DEFAULT_BUILD="$(git rev-list --count HEAD 2>/dev/null || printf '1')"
BUILD_NUMBER="$(product_env_value BUILD_NUMBER "$DEFAULT_BUILD")"
DIST_DIR="$(product_env_value DIST_DIR dist)"
RELEASE_VARIANT="$(product_env_value RELEASE_VARIANT)"
RELEASE_ALIAS_VARIANT="$(product_env_value RELEASE_ALIAS_VARIANT "$RELEASE_VARIANT")"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
NOTARY_TIMEOUT="$(product_env_value NOTARY_TIMEOUT 30m)"

if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "PRODUCT_VERSION must contain two or three numeric components (for example 1.2.0)" >&2
    exit 2
fi
if [ "$VERSION" != "$PROJECT_VERSION" ]; then
    echo "Release version $VERSION does not match VERSION ($PROJECT_VERSION)." >&2
    echo "Update VERSION and CHANGELOG.md in the release commit." >&2
    exit 2
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "PRODUCT_BUILD_NUMBER must be numeric" >&2
    exit 2
fi
if [ "$SKIP_NOTARIZE" != "0" ] && [ "$SKIP_NOTARIZE" != "1" ]; then
    echo "SKIP_NOTARIZE must be 0 or 1" >&2
    exit 2
fi
if [ -n "$RELEASE_VARIANT" ] \
   && ! [[ "$RELEASE_VARIANT" =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]]; then
    echo "PRODUCT_RELEASE_VARIANT must be lowercase letters, numbers, dots, and hyphens." >&2
    exit 2
fi
if [ -n "$RELEASE_ALIAS_VARIANT" ] \
   && ! [[ "$RELEASE_ALIAS_VARIANT" =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]]; then
    echo "PRODUCT_RELEASE_ALIAS_VARIANT must be lowercase letters, numbers, dots, and hyphens." >&2
    exit 2
fi

if [ "$SKIP_NOTARIZE" = "0" ]; then
    product_assert_canonical_checkout
fi

# A local rehearsal is intentionally not a publication claim.  The real path
# must be bound to an approved, exact source/evidence record before credentials
# are loaded or package bytes are produced.
if [ "$SKIP_NOTARIZE" = "0" ]; then
    python3 -B scripts/check-release-qualification.py publication --phase source
fi

NOTARY_AUTH=()
if [ "$SKIP_NOTARIZE" = "0" ]; then
    NOTARY_PROFILE="$(product_env_value NOTARY_PROFILE)"
    NOTARY_KEY_FILE="$(product_env_value NOTARY_KEY_FILE)"
    NOTARY_KEY_ID="$(product_env_value NOTARY_KEY_ID)"
    NOTARY_ISSUER_ID="$(product_env_value NOTARY_ISSUER_ID)"
    if [ -n "$NOTARY_PROFILE" ]; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "$NOTARY_KEY_FILE" ] && [ -n "$NOTARY_KEY_ID" ]; then
        if [ ! -f "$NOTARY_KEY_FILE" ]; then
            echo "PRODUCT_NOTARY_KEY_FILE does not exist: $NOTARY_KEY_FILE" >&2
            exit 2
        fi
        NOTARY_AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID")
        if [ -n "$NOTARY_ISSUER_ID" ]; then
            NOTARY_AUTH+=(--issuer "$NOTARY_ISSUER_ID")
        fi
    else
        echo "Notary credentials are required. Set PRODUCT_NOTARY_PROFILE, or" >&2
        echo "PRODUCT_NOTARY_KEY_FILE and PRODUCT_NOTARY_KEY_ID." >&2
        echo "Use SKIP_NOTARIZE=1 only for a signed local release rehearsal." >&2
        exit 2
    fi
fi

export PRODUCT_VERSION="$VERSION"
export PRODUCT_BUILD_NUMBER="$BUILD_NUMBER"
./package.sh

SIGNING_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if ! grep -Fq "Authority=Developer ID Application:" <<< "$SIGNING_INFO"; then
    echo "release.sh requires a Developer ID Application identity." >&2
    echo "Set PRODUCT_SIGN_ID to its SHA-1 hash and retry." >&2
    exit 3
fi
if ! grep -Eq 'flags=.*\(runtime\)' <<< "$SIGNING_INFO"; then
    echo "The app is not signed with hardened runtime." >&2
    exit 3
fi
codesign --verify --deep --strict --verbose=2 "$APP"

ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/$PRODUCT_EXECUTABLE" | tr ' ' '-')"
mkdir -p "$DIST_DIR"
VARIANT_SUFFIX="${RELEASE_VARIANT:+-$RELEASE_VARIANT}"
REHEARSAL_SUFFIX=""
if [ "$SKIP_NOTARIZE" = "1" ]; then
    REHEARSAL_SUFFIX="-rehearsal"
fi
ARTIFACT_STEM="$PRODUCT_RELEASE_PREFIX-${VERSION}${VARIANT_SUFFIX}-macOS-${ARCHITECTURES}${REHEARSAL_SUFFIX}"
ARCHIVE="$DIST_DIR/$ARTIFACT_STEM.zip"
ARCHIVE_CHECKSUM="$ARCHIVE.sha256"
DMG="$DIST_DIR/$ARTIFACT_STEM.dmg"
DMG_CHECKSUM="$DMG.sha256"
DMG_SIGN_ID="$(product_env_value SIGN_ID "$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application/{print $2; exit}')")"
DMG_WORK_DIR=""
DMG_MOUNT_POINT=""
DMG_IS_MOUNTED=0
ARCHIVE_NOTARY_RESULT=""
DMG_NOTARY_RESULT=""
ARCHIVE_SUBMITTED_SHA256=""
DMG_SUBMITTED_SHA256=""
QUALIFICATION_RECORD="$DIST_DIR/$ARTIFACT_STEM.publication.json"
if [ "$SKIP_NOTARIZE" = "0" ]; then
    # Apple receipts are public release evidence, not disposable scratch.
    # Keep the exact accepted JSON beside the artifacts so the UUID and raw
    # receipt hash in *.publication.json remain independently auditable.
    ARCHIVE_NOTARY_RESULT="$DIST_DIR/$ARTIFACT_STEM.archive-notary.json"
    DMG_NOTARY_RESULT="$DIST_DIR/$ARTIFACT_STEM.dmg-notary.json"
fi

make_archive() {
    rm -f "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
}

cleanup_dmg_work() {
    if [ "$DMG_IS_MOUNTED" = "1" ] && [ -n "$DMG_MOUNT_POINT" ]; then
        hdiutil detach "$DMG_MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    DMG_IS_MOUNTED=0
    if [ -n "$DMG_WORK_DIR" ] && [ "$DMG_WORK_DIR" != "/" ]; then
        rm -rf "$DMG_WORK_DIR"
    fi
    DMG_WORK_DIR=""
    DMG_MOUNT_POINT=""
}

cleanup_all() {
    cleanup_dmg_work
}
trap cleanup_all EXIT INT TERM

make_dmg() {
    if [ -z "$DMG_SIGN_ID" ] || [ "$DMG_SIGN_ID" = "-" ]; then
        echo "A Developer ID Application identity is required to sign the DMG." >&2
        exit 3
    fi

    cleanup_dmg_work
    DMG_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$PRODUCT_SLUG-dmg.XXXXXX")"
    DMG_MOUNT_POINT="$DMG_WORK_DIR/volume"
    local sparse_base="$DMG_WORK_DIR/$PRODUCT_SLUG-rw"
    local sparse_image="${sparse_base}.sparseimage"
    local app_kib
    local image_mib
    app_kib="$(du -sk "$APP" | awk '{print $1}')"
    image_mib=$(( (app_kib + 1023) / 1024 + 96 ))
    if [ "$image_mib" -lt 192 ]; then image_mib=192; fi

    mkdir -p "$DMG_MOUNT_POINT"
    hdiutil create -ov -size "${image_mib}m" -fs APFS \
        -volname "$PRODUCT_TITLE_NAME" -type SPARSE "$sparse_base" >/dev/null
    hdiutil attach "$sparse_image" -nobrowse \
        -mountpoint "$DMG_MOUNT_POINT" >/dev/null
    DMG_IS_MOUNTED=1
    ditto "$APP" "$DMG_MOUNT_POINT/$PRODUCT_APP_BUNDLE"
    ln -s /Applications "$DMG_MOUNT_POINT/Applications"
    sync
    hdiutil detach "$DMG_MOUNT_POINT" >/dev/null
    DMG_IS_MOUNTED=0

    rm -f "$DMG"
    hdiutil convert "$sparse_image" -format UDZO -imagekey zlib-level=9 \
        -o "$DMG" >/dev/null
    codesign --force --timestamp --sign "$DMG_SIGN_ID" "$DMG"
    codesign --verify --verbose=2 "$DMG"
    hdiutil verify "$DMG" >/dev/null
    cleanup_dmg_work
}

submit_and_require_accepted() {
    local artifact="$1"
    local label="$2"
    local result_path="$3"
    local result
    local result_code
    local result_status
    local result_id
    NOTARY_SUBMITTED_SHA256="$(shasum -a 256 "$artifact" | awk '{print $1}')"
    echo "Submitting $artifact to Apple's notary service..."
    set +e
    result="$(xcrun notarytool submit "${NOTARY_AUTH[@]}" \
        --wait --timeout "$NOTARY_TIMEOUT" --output-format json "$artifact")"
    result_code=$?
    set -e
    printf '%s\n' "$result" > "$result_path"
    printf '%s\n' "$result"
    result_status="$(printf '%s\n' "$result" \
        | plutil -extract status raw -o - - 2>/dev/null || true)"
    if [ "$result_code" -ne 0 ] || [ "$result_status" != "Accepted" ]; then
        result_id="$(printf '%s\n' "$result" \
            | plutil -extract id raw -o - - 2>/dev/null || true)"
        if [ -n "$result_id" ]; then
            echo "$label notarization failed; fetching Apple's diagnostic log..." >&2
            xcrun notarytool log "${NOTARY_AUTH[@]}" "$result_id" || true
        fi
        exit 4
    fi
}

make_archive

if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "Skipping notarization (release rehearsal only)."
else
    submit_and_require_accepted "$ARCHIVE" "App" "$ARCHIVE_NOTARY_RESULT"
    ARCHIVE_SUBMITTED_SHA256="$NOTARY_SUBMITTED_SHA256"
    xcrun stapler staple -v "$APP"
    xcrun stapler validate -v "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    spctl --assess --type execute --verbose=2 "$APP"

    # Stapling mutates the bundle, so the downloadable archive must be rebuilt
    # after the ticket is attached.
    make_archive
fi

make_dmg
if [ "$SKIP_NOTARIZE" != "1" ]; then
    submit_and_require_accepted "$DMG" "DMG" "$DMG_NOTARY_RESULT"
    DMG_SUBMITTED_SHA256="$NOTARY_SUBMITTED_SHA256"
    xcrun stapler staple -v "$DMG"
    xcrun stapler validate -v "$DMG"
    codesign --verify --verbose=2 "$DMG"
    hdiutil verify "$DMG" >/dev/null
    spctl --assess --type open --context context:primary-signature \
        --verbose=2 "$DMG"
fi

shasum -a 256 "$ARCHIVE" > "$ARCHIVE_CHECKSUM"
shasum -a 256 "$DMG" > "$DMG_CHECKSUM"
if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "Signed local rehearsal archive: $ARCHIVE"
    echo "Rehearsal archive checksum:      $ARCHIVE_CHECKSUM"
    echo "Signed local rehearsal DMG:     $DMG"
    echo "Rehearsal DMG checksum:         $DMG_CHECKSUM"
else
    python3 -B scripts/check-release-qualification.py publication \
        --phase artifact \
        --app "$APP" \
        --archive "$ARCHIVE" \
        --archive-checksum "$ARCHIVE_CHECKSUM" \
        --archive-notary-result "$ARCHIVE_NOTARY_RESULT" \
        --archive-submitted-sha256 "$ARCHIVE_SUBMITTED_SHA256" \
        --dmg "$DMG" \
        --dmg-checksum "$DMG_CHECKSUM" \
        --dmg-notary-result "$DMG_NOTARY_RESULT" \
        --dmg-submitted-sha256 "$DMG_SUBMITTED_SHA256" \
        --version "$VERSION" \
        --build "$BUILD_NUMBER" \
        --variant "$RELEASE_VARIANT" \
        --output "$QUALIFICATION_RECORD"
    echo "Release archive: $ARCHIVE"
    echo "Archive checksum: $ARCHIVE_CHECKSUM"
    echo "Release DMG:      $DMG"
    echo "DMG checksum:     $DMG_CHECKSUM"
    echo "Archive receipt:  $ARCHIVE_NOTARY_RESULT"
    echo "DMG receipt:      $DMG_NOTARY_RESULT"
    echo "Qualification:    $QUALIFICATION_RECORD"

    # Stable aliases let the public website link directly to the latest signed
    # installer without hard-coding a release or Browser component version.
    ALIAS_VARIANT_SUFFIX="${RELEASE_ALIAS_VARIANT:+-$RELEASE_ALIAS_VARIANT}"
    ALIAS_DMG="$DIST_DIR/$PRODUCT_RELEASE_PREFIX$ALIAS_VARIANT_SUFFIX-macOS-$ARCHITECTURES.dmg"
    cp "$DMG" "$ALIAS_DMG"
    cmp -s "$DMG" "$ALIAS_DMG" || {
        echo "Stable DMG alias differs from the qualified artifact." >&2
        exit 5
    }
    shasum -a 256 "$ALIAS_DMG" > "$ALIAS_DMG.sha256"
    echo "Stable DMG alias: $ALIAS_DMG"
fi
