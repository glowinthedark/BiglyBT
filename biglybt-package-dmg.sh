#!/usr/bin/env bash
APP_VERSION=8.0.8
set -xe -o pipefail

# ============================================================
#  BiglyBT – macOS arm64 DMG builder  (v2 – fixed)
#
#  Strategy:
#    Step 1 – jlink  : build a trimmed arm64 JRE explicitly
#                      (errors are visible; bypasses silent
#                       jlink-inside-jpackage failure mode)
#    Step 2 – jpackage --type app-image  : build .app bundle
#    Step 3 – patch Info.plist
#    Step 4 – jpackage --type dmg        : wrap in DMG
#
#  Fixed bugs vs v1:
#    • --jlink-options "--compress=2" caused silent jlink abort
#      (now runs jlink explicitly; compress arg auto-detected:
#       JDK 17 → numeric 2,  JDK 21+ → zip-6)
#    • jpackage now receives --runtime-image (pre-built JRE)
#      instead of running jlink internally (errors were hidden)
#    • each --java-options is a separate flag (jpackage does not
#      split space-separated values in a single --java-options)
#    • full stderr/stdout surfaced on any failure
#    • APP_VERSION auto-detected from MANIFEST.MF if not set
#    • --temp flag added for inspectable intermediate artefacts
#
#  Usage:
#    chmod +x biglybt-package-dmg.sh
#    ./biglybt-package-dmg.sh
#
#    APP_VERSION=4.1.0 ./biglybt-package-dmg.sh
#
#    SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#      ./biglybt-package-dmg.sh
#
#    ./biglybt-package-dmg.sh --make-icns biglybt-icon.png
# ============================================================
set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
hr()    { echo -e "${BOLD}────────────────────────────────────────────${NC}"; }

# ════════════════════════════════════════════════════════════
#  §1  USER-TUNABLE SETTINGS
# ════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Build artefacts ──────────────────────────────────────────
BIGLYBT_JAR="${SCRIPT_DIR}/uis/target/BiglyBT.jar"
CORE_JAR="${SCRIPT_DIR}/core/target/BiglyBT-Core.jar"
CORE_LIBS_DIR="${SCRIPT_DIR}/core/lib"

# ── arm64 SWT jar ────────────────────────────────────────────
SWT_VERSION="${SWT_VERSION:-3.128.0}"
SWT_AARCH64_JAR="${SCRIPT_DIR}/swt-cocoa-aarch64.jar"
SWT_MAVEN_URL="https://repo1.maven.org/maven2/org/eclipse/platform/org.eclipse.swt.cocoa.macosx.aarch64/${SWT_VERSION}/org.eclipse.swt.cocoa.macosx.aarch64-${SWT_VERSION}.jar"

# ── App metadata ─────────────────────────────────────────────
APP_NAME="BiglyBT"
APP_VENDOR="Bigly Software"
APP_COPYRIGHT="Copyright © Bigly Software"
BUNDLE_ID="com.biglybt.ui"
MAIN_CLASS="com.biglybt.ui.Main"

# APP_VERSION: auto-detected from MANIFEST.MF; override with env var.
# jpackage requires a purely numeric dotted version (e.g. 4.0.0).
_detect_version() {
    local v
    v=$(unzip -p "${BIGLYBT_JAR}" META-INF/MANIFEST.MF 2>/dev/null \
        | grep -i "^Implementation-Version" | head -1 \
        | awk -F': ' '{print $2}' | tr -d '\r' || true)
    v="${v%% *}"; v="${v%%-*}"   # strip suffix after space or dash
    [[ "${v}" =~ ^[0-9]+(\.[0-9]+)*$ ]] && echo "${v}" || echo "4.0.0"
}
APP_VERSION="${APP_VERSION:-$(_detect_version)}"

# ── Optional .icns icon ──────────────────────────────────────
APP_ICON="${SCRIPT_DIR}/biglybt.icns"

# ── Directories ──────────────────────────────────────────────
BUILD_DIR="${SCRIPT_DIR}/jpackage-build"
INPUT_DIR="${BUILD_DIR}/input"           # staged jars
RUNTIME_DIR="${BUILD_DIR}/runtime"       # jlink output (arm64 JRE)
APP_IMAGE_DIR="${BUILD_DIR}/app-image"   # jpackage app-image output
JPACKAGE_TEMP="${BUILD_DIR}/tmp"         # inspectable temp dir
DMG_DIR="${SCRIPT_DIR}/dist"             # final .dmg

# ── JVM heap (written into the bundled launcher) ─────────────
JVM_XMX="-Xmx512m"
JVM_XMS="-Xms128m"

# ── Code-signing identity ────────────────────────────────────
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# ════════════════════════════════════════════════════════════
#  §2  PRE-FLIGHT CHECKS
# ════════════════════════════════════════════════════════════

check_prereqs() {
    hr; info "Pre-flight checks …"

    # Locate JDK bin dir
    if [[ -n "${JAVA_HOME:-}" ]]; then
        JDK_BIN="${JAVA_HOME}/bin"
    else
        JDK_BIN="$(dirname "$(command -v java 2>/dev/null || true)")"
    fi

    JAVA_CMD="${JDK_BIN}/java"
    JLINK_CMD="${JDK_BIN}/jlink"
    JPACKAGE_CMD="${JDK_BIN}/jpackage"

    for cmd in "${JAVA_CMD}" "${JLINK_CMD}" "${JPACKAGE_CMD}"; do
        [[ -x "${cmd}" ]] \
            || die "Not found / not executable: ${cmd}\nSet JAVA_HOME to your JDK 17 directory."
    done

    local jver
    jver=$("${JAVA_CMD}" -version 2>&1 \
           | awk -F '"' '/version/{print $2}' | cut -d. -f1)
    [[ "${jver}" -ge 17 ]] || die "JDK 17+ required (found ${jver})."

    local arch
    arch=$("${JAVA_CMD}" -XshowSettings:all -version 2>&1 \
           | awk '/os\.arch/{print $3}')
    if [[ "${arch}" != "aarch64" ]]; then
        warn "JVM os.arch='${arch}' – expected aarch64 for a native arm64 build."
        warn "Install an arm64 JDK: brew install --cask temurin@17"
    else
        ok "JVM arch: aarch64 ✓"
    fi

    if ! xcode-select -p &>/dev/null; then
        warn "Xcode CLI tools not detected – DMG creation may fail."
        warn "Fix: xcode-select --install"
    fi

    [[ -f "${BIGLYBT_JAR}" ]] \
        || die "BiglyBT UI jar not found: ${BIGLYBT_JAR}\nRun 'mvn clean package' first."

    info "App name    : ${APP_NAME}"
    info "App version : ${APP_VERSION}"
    info "JDK         : $("${JAVA_CMD}" -version 2>&1 | head -1)"
    ok "Pre-flight passed"
}

# ════════════════════════════════════════════════════════════
#  §3  DOWNLOAD arm64 SWT JAR
# ════════════════════════════════════════════════════════════

ensure_swt_jar() {
    hr; info "Checking arm64 SWT jar …"
    if [[ -f "${SWT_AARCH64_JAR}" ]]; then
        ok "Already present: $(basename "${SWT_AARCH64_JAR}")"
        return
    fi
    info "Downloading arm64 SWT ${SWT_VERSION} from Maven Central …"
    if command -v curl &>/dev/null; then
        curl -fL --progress-bar -o "${SWT_AARCH64_JAR}" "${SWT_MAVEN_URL}" \
            || die "Download failed: ${SWT_MAVEN_URL}"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "${SWT_AARCH64_JAR}" "${SWT_MAVEN_URL}" \
            || die "Download failed: ${SWT_MAVEN_URL}"
    else
        die "curl/wget not found.\nManually download:\n  ${SWT_MAVEN_URL}\n  → ${SWT_AARCH64_JAR}"
    fi
    ok "Downloaded: $(basename "${SWT_AARCH64_JAR}")"
}

# ════════════════════════════════════════════════════════════
#  §4  CLEAR STALE x86_64 SWT CACHE
# ════════════════════════════════════════════════════════════

clear_swt_cache() {
    local SWT_CACHE="${HOME}/.swt/lib/macosx/aarch64"
    if [[ -d "${SWT_CACHE}" ]]; then
        local BAD
        BAD=$(find "${SWT_CACHE}" -name "*.jnilib" \
              -exec file {} \; 2>/dev/null | grep -c "x86_64" || true)
        if [[ "${BAD}" -gt 0 ]]; then
            warn "Removing ${BAD} stale x86_64 jnilib(s) from SWT cache …"
            rm -rf "${SWT_CACHE}"
            ok "SWT cache cleared"
        fi
    fi
}

# ════════════════════════════════════════════════════════════
#  §5  STAGE INPUT DIRECTORY
# ════════════════════════════════════════════════════════════

stage_input() {
    hr; info "Staging input jars into ${INPUT_DIR} …"
    rm -rf "${INPUT_DIR}"
    mkdir -p "${INPUT_DIR}"

    cp "${SWT_AARCH64_JAR}" "${INPUT_DIR}/swt-cocoa-aarch64.jar"
    cp "${BIGLYBT_JAR}"     "${INPUT_DIR}/BiglyBT.jar"

    if [[ -f "${CORE_JAR}" ]]; then
        cp "${CORE_JAR}" "${INPUT_DIR}/$(basename "${CORE_JAR}")"
    else
        warn "Core jar not found at ${CORE_JAR} – skipping"
    fi

    local count=0
    if [[ -d "${CORE_LIBS_DIR}" ]]; then
        for jar in "${CORE_LIBS_DIR}"/*.jar; do
            [[ -f "${jar}" ]] || continue
            local fname; fname="$(basename "${jar}")"
            # Skip non-arm64 SWT jars that may be in core/lib
            if [[ "${fname}" == swt-cocoa-64* || \
                  "${fname}" == swt-win*       || \
                  "${fname}" == swt-linux*     ]]; then
                warn "Skipping incompatible SWT jar: ${fname}"
                continue
            fi
            cp "${jar}" "${INPUT_DIR}/${fname}"
            (( count++ )) || true
        done
    fi
    ok "Staged ${count} dependency jars from core/lib"

    # Copy any OSX native helper libs (.jnilib) if present
    for jnilib in "${SCRIPT_DIR}"/*.jnilib "${SCRIPT_DIR}"/dll/*.jnilib; do
        [[ -f "${jnilib}" ]] || continue
        cp "${jnilib}" "${INPUT_DIR}/"
        ok "Staged native lib: $(basename "${jnilib}")"
    done
}

# ════════════════════════════════════════════════════════════
#  §6  STEP 1 – BUILD arm64 JRE WITH JLINK
#
#  WHY we do this ourselves instead of letting jpackage do it:
#  ─────────────────────────────────────────────────────────
#  When jpackage runs jlink internally, any jlink error causes
#  jpackage to exit 0 but produce no .app – there is no error
#  message.  By running jlink explicitly we get real diagnostics.
#
#  KEY FIX: --compress is version-dependent
#  ─────────────────────────────────────────────────────────
#  JDK 17  → numeric values only: 0 | 1 | 2
#            "zip-6" does NOT exist in JDK 17 and causes:
#            "Error: Invalid compression level zip-6"
#  JDK 21+ → zip-[0-9] is the new form; numeric is deprecated
#  The script auto-detects the JDK version and passes the right value.
# ════════════════════════════════════════════════════════════

build_runtime() {
    hr; info "Step 1/4: jlink – building arm64 JRE …"
    rm -rf "${RUNTIME_DIR}"
    mkdir -p "${BUILD_DIR}"

    local LOG="${BUILD_DIR}/jlink.log"
    info "Log: ${LOG}"

    # --compress syntax is JDK-version-dependent:
    #   JDK 17 : numeric 0 | 1 | 2   ("zip-N" does not exist yet)
    #   JDK 21+: zip-[0-9]            (numeric form deprecated)
    local jver; jver=$("${JAVA_CMD}" -version 2>&1 | awk -F '"' '/version/{print $2}' | cut -d. -f1)
    local COMPRESS_ARG="2"          # JDK 17 default (≡ zip-6 on JDK 21+)
    if [[ "${jver}" -ge 21 ]]; then
        COMPRESS_ARG="zip-6"
    fi
    info "jlink --compress ${COMPRESS_ARG}  (JDK ${jver})"

    # NOTE: --strip-native-commands is intentionally omitted.
    # That flag deletes bin/java from the runtime image; jpackage
    # requires bin/java to exist in --runtime-image to build its launcher.
    # Without bin/java, jpackage exits 0 but produces no .app bundle.
    set +e
    "${JLINK_CMD}" \
        --add-modules \
"java.base,java.desktop,java.logging,java.management,java.naming,java.net.http,java.prefs,java.scripting,java.security.jgss,java.sql,jdk.unsupported,jdk.crypto.ec,jdk.crypto.cryptoki" \
        --no-header-files \
        --no-man-pages \
        --strip-debug \
        --compress "${COMPRESS_ARG}" \
        --output "${RUNTIME_DIR}" \
        2>&1 | tee "${LOG}"
    local RC="${PIPESTATUS[0]}"
    set -e

    if [[ "${RC}" -ne 0 ]]; then
        echo ""; die "jlink failed (exit ${RC}). See: ${LOG}"
    fi

    # Verify using lib/ (always present).
    # Do NOT check bin/java — --strip-native-commands removes it and
    # we no longer use that flag, but lib/ is the robust sentinel.
    [[ -d "${RUNTIME_DIR}/lib" ]] \
        || die "jlink produced no usable output in ${RUNTIME_DIR}. See: ${LOG}"

    local rt_arch
    rt_arch=$(file "${RUNTIME_DIR}/bin/java" 2>/dev/null \
              | grep -o "arm64\|x86_64" || echo "unknown (stripped)")
    ok "JRE built → ${RUNTIME_DIR}  (arch: ${rt_arch})"
}

# ════════════════════════════════════════════════════════════
#  §7  STEP 2 – BUILD APP-IMAGE
# ════════════════════════════════════════════════════════════

build_app_image() {
    hr; info "Step 2/4: jpackage app-image …"
    rm -rf "${APP_IMAGE_DIR}" "${JPACKAGE_TEMP}"
    mkdir -p "${APP_IMAGE_DIR}" "${JPACKAGE_TEMP}"

    local ICON_FLAGS=()
    if [[ -f "${APP_ICON}" ]]; then
        ICON_FLAGS=(--icon "${APP_ICON}")
        info "Icon: ${APP_ICON}"
    else
        warn "No .icns at ${APP_ICON} – using default icon."
    fi

    local SIGN_FLAGS=()
    if [[ -n "${SIGN_IDENTITY}" ]]; then
        SIGN_FLAGS=(--mac-sign --mac-signing-key-user-name "${SIGN_IDENTITY}")
        info "Signing: ${SIGN_IDENTITY}"
    fi

    local LOG="${BUILD_DIR}/jpackage-app-image.log"
    info "Log: ${LOG}"

    set +e
    "${JPACKAGE_CMD}" \
        --type          app-image \
        --verbose \
        \
        --input         "${INPUT_DIR}" \
        --runtime-image "${RUNTIME_DIR}" \
        --dest          "${APP_IMAGE_DIR}" \
        --temp          "${JPACKAGE_TEMP}" \
        \
        --name          "${APP_NAME}" \
        --app-version   "${APP_VERSION}" \
        --vendor        "${APP_VENDOR}" \
        --copyright     "${APP_COPYRIGHT}" \
        --main-jar      "BiglyBT.jar" \
        --main-class    "${MAIN_CLASS}" \
        \
        "${ICON_FLAGS[@]+"${ICON_FLAGS[@]}"}" \
        \
        --mac-package-name        "${APP_NAME}" \
        --mac-package-identifier  "${BUNDLE_ID}" \
        \
        --java-options  "-XstartOnFirstThread" \
        --java-options  "${JVM_XMX}" \
        --java-options  "${JVM_XMS}" \
        --java-options  "--add-opens=java.base/java.net=ALL-UNNAMED" \
        --java-options  "--add-opens=java.base/java.lang=ALL-UNNAMED" \
        --java-options  "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED" \
        --java-options  "--add-opens=java.base/java.io=ALL-UNNAMED" \
        --java-options  "--add-opens=java.base/java.util=ALL-UNNAMED" \
        --java-options  "--add-opens=java.base/java.util.concurrent=ALL-UNNAMED" \
        --java-options  "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED" \
        --java-options  "--add-opens=java.base/sun.net.www.protocol.http=ALL-UNNAMED" \
        --java-options  "--add-opens=java.base/sun.net.www.protocol.https=ALL-UNNAMED" \
        --java-options  "-Djava.security.manager=allow" \
        --java-options  "-Dapple.laf.useScreenMenuBar=true" \
        --java-options  "-Dcom.apple.macos.use-file-dialog-packages=true" \
        --java-options  "-Dcom.apple.mrj.application.apple.menu.about.name=${APP_NAME}" \
        \
        "${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"}" \
        2>&1 | tee "${LOG}"
    local RC="${PIPESTATUS[0]}"
    set -e

    if [[ "${RC}" -ne 0 ]]; then
        echo ""
        echo -e "${RED}══ Last 50 lines of jpackage output ══${NC}"
        tail -50 "${LOG}"
        echo -e "${RED}═══════════════════════════════════════${NC}"
        echo ""
        die "jpackage app-image failed (exit ${RC}).\nFull log : ${LOG}\nTemp dir : ${JPACKAGE_TEMP}"
    fi

    # Locate the .app bundle
    local APP_BUNDLE="${APP_IMAGE_DIR}/${APP_NAME}.app"
    if [[ ! -d "${APP_BUNDLE}" ]]; then
        # Search in case jpackage placed it in a sub-directory
        APP_BUNDLE="$(find "${APP_IMAGE_DIR}" -maxdepth 3 -name "*.app" -type d | head -1 || true)"
        if [[ -z "${APP_BUNDLE}" || ! -d "${APP_BUNDLE}" ]]; then
            echo ""
            echo -e "${RED}── Contents of ${APP_IMAGE_DIR} ──${NC}"
            find "${APP_IMAGE_DIR}" -maxdepth 4 | sort
            echo ""
            die "jpackage exited 0 but no .app found.\nLog: ${LOG}"
        fi
        warn "Found .app at non-standard path: ${APP_BUNDLE}"
    fi

    ok "Step 2/4 complete: ${APP_BUNDLE}"
    echo "${APP_BUNDLE}"
}

# ════════════════════════════════════════════════════════════
#  §8  STEP 3 – PATCH Info.plist
# ════════════════════════════════════════════════════════════

patch_plist() {
    local APP_BUNDLE="$1"
    hr; info "Step 3/4: patching Info.plist …"

    local PLIST="${APP_BUNDLE}/Contents/Info.plist"
    [[ -f "${PLIST}" ]] || die "Info.plist not found: ${PLIST}"

    local PB="/usr/libexec/PlistBuddy"
    [[ -x "${PB}" ]] || die "PlistBuddy not found (Xcode CLI required)."

    plist_set() {
        local type="$1" key="$2" value="$3"
        "${PB}" -c "Delete :${key}"                  "${PLIST}" 2>/dev/null || true
        "${PB}" -c "Add    :${key} ${type} ${value}" "${PLIST}"
    }

    plist_set bool   NSHighResolutionCapable               true
    plist_set bool   NSSupportsAutomaticGraphicsSwitching  true
    plist_set string NSPrincipalClass                      NSApplication
    plist_set string CFBundleDisplayName                   "${APP_NAME}"
    plist_set string CFBundleShortVersionString            "${APP_VERSION}"

    # JAVA_LIBRARY_PATH so native .jnilib files are found at runtime
    "${PB}" -c "Delete :LSEnvironment"                                         "${PLIST}" 2>/dev/null || true
    "${PB}" -c "Add    :LSEnvironment dict"                                    "${PLIST}"
    "${PB}" -c "Add    :LSEnvironment:JAVA_LIBRARY_PATH string \$APP_PACKAGE/Contents/app" "${PLIST}"

    ok "Info.plist patched"
    info "Verify: plutil -p \"${PLIST}\""
}

# ════════════════════════════════════════════════════════════
#  §9  STEP 4 – WRAP IN DMG
# ════════════════════════════════════════════════════════════

build_dmg() {
    local APP_BUNDLE="$1"
    hr; info "Step 4/4: jpackage dmg …"
    rm -rf "${DMG_DIR}"
    mkdir -p "${DMG_DIR}"

    local SIGN_FLAGS=()
    if [[ -n "${SIGN_IDENTITY}" ]]; then
        SIGN_FLAGS=(--mac-sign --mac-signing-key-user-name "${SIGN_IDENTITY}")
    fi

    local LOG="${BUILD_DIR}/jpackage-dmg.log"
    info "Log: ${LOG}"

    set +e
    "${JPACKAGE_CMD}" \
        --type          dmg \
        --verbose \
        \
        --app-image     "${APP_BUNDLE}" \
        --dest          "${DMG_DIR}" \
        \
        --name          "${APP_NAME}" \
        --app-version   "${APP_VERSION}" \
        --vendor        "${APP_VENDOR}" \
        --copyright     "${APP_COPYRIGHT}" \
        \
        --mac-package-name        "${APP_NAME}" \
        --mac-package-identifier  "${BUNDLE_ID}" \
        \
        "${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"}" \
        2>&1 | tee "${LOG}"
    local RC="${PIPESTATUS[0]}"
    set -e

    if [[ "${RC}" -ne 0 ]]; then
        echo ""; tail -40 "${LOG}"
        die "jpackage dmg failed (exit ${RC}). See: ${LOG}"
    fi

    local DMG
    DMG="$(find "${DMG_DIR}" -maxdepth 1 -name "*.dmg" | head -1 || true)"
    [[ -f "${DMG}" ]] || die "No .dmg found in ${DMG_DIR}. See: ${LOG}"

    ok "Step 4/4 complete: ${DMG}"
    echo "${DMG}"
}

# ════════════════════════════════════════════════════════════
#  §10  REMOVE QUARANTINE (ad-hoc builds)
# ════════════════════════════════════════════════════════════

remove_quarantine() {
    local DMG="$1"
    if [[ -z "${SIGN_IDENTITY}" ]]; then
        info "Stripping quarantine attribute (ad-hoc build) …"
        xattr -c "${DMG}" 2>/dev/null || true
        ok "Quarantine removed (Gatekeeper will not block on THIS machine)"
        warn "To distribute externally: sign with Developer ID + xcrun notarytool"
    fi
}

# ════════════════════════════════════════════════════════════
#  §11  MAIN
# ════════════════════════════════════════════════════════════

main() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  BiglyBT  •  macOS arm64  •  DMG Builder  v2  ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    check_prereqs
    ensure_swt_jar
    clear_swt_cache
    stage_input
    build_runtime

    local APP_BUNDLE
    APP_BUNDLE="$(build_app_image)"
    patch_plist "${APP_BUNDLE}"

    local DMG
    DMG="$(build_dmg "${APP_BUNDLE}")"
    remove_quarantine "${DMG}"

    hr
    echo -e "${BOLD}${GREEN}  ✓  BUILD SUCCESSFUL${NC}"
    hr
    echo ""
    echo -e "  DMG        : ${BOLD}${DMG}${NC}"
    echo -e "  App bundle : ${BOLD}${APP_BUNDLE}${NC}"
    echo ""
    echo -e "  Install    :  open \"${DMG}\""
    echo -e "  Test run   :  open \"${APP_BUNDLE}\""
    echo ""
}

# ════════════════════════════════════════════════════════════
#  §12  MAKE-ICNS HELPER
# ════════════════════════════════════════════════════════════

make_icns() {
    local SRC="${1:-${SCRIPT_DIR}/biglybt-icon.png}"
    local OUT="${APP_ICON}"

    [[ -f "${SRC}" ]]   || die "Source PNG not found: ${SRC}"
    command -v sips     &>/dev/null || die "sips not found (requires macOS + Xcode CLI)"
    command -v iconutil &>/dev/null || die "iconutil not found (requires macOS + Xcode CLI)"

    local ICONSET="${SCRIPT_DIR}/biglybt.iconset"
    rm -rf "${ICONSET}"; mkdir "${ICONSET}"

    info "Building iconset from ${SRC} …"
    for SIZE in 16 32 64 128 256 512; do
        sips -z "${SIZE}" "${SIZE}"               "${SRC}" \
            --out "${ICONSET}/icon_${SIZE}x${SIZE}.png"       &>/dev/null
        sips -z "$((SIZE*2))" "$((SIZE*2))"       "${SRC}" \
            --out "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png"    &>/dev/null
    done

    iconutil -c icns "${ICONSET}" -o "${OUT}"
    rm -rf "${ICONSET}"
    ok "Icon written: ${OUT}"
}

# ─── Entry point ─────────────────────────────────────────────
case "${1:-}" in
    --make-icns) make_icns "${2:-}"; exit 0 ;;
    "")          main ;;
    *)           die "Unknown argument: $1\nUsage: $0 [--make-icns [icon.png]]" ;;
esac