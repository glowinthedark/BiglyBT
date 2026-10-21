# BiglyBT – native arm64 macOS .app + .dmg
#
#   make            build jar → arm64 JRE → BiglyBT.app → BiglyBT-<ver>-arm64.dmg
#   make app        stop after the .app bundle
#   make run        launch the bundled app in the foreground (stdout/stderr visible)
#   make verify     assert every Mach-O in the bundle is arm64 and the signature is valid
#   make clean      remove build/
#
# Overridable: JDK=/path/to/jdk  MVN_JDK=/path/to/jdk  SWT_VERSION=3.128.0  BUNDLE_ID=…  SIGN_ID="Developer ID Application: …"

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
.SUFFIXES:

ARCH := arm64
ifneq ($(shell uname -m),$(ARCH))
$(error host is $(shell uname -m); this Makefile builds a native $(ARCH) bundle)
endif

# ── toolchain ────────────────────────────────────────────────────────────────
# Runtime JDK: 21 LTS (SecurityManager path is skipped on 18+, Thread.stop is handled; 24+ is untested upstream).
JDK      ?= $(shell /usr/libexec/java_home -v 21 -a $(ARCH) 2>/dev/null)
MVN_JDK  ?= $(JDK)
MVN      ?= $(if $(wildcard ./mvnw),./mvnw,mvn)
JLINK    := $(JDK)/bin/jlink
JPACKAGE := $(JDK)/bin/jpackage
PLISTBUDDY := /usr/libexec/PlistBuddy

ifeq ($(JDK),)
$(error no arm64 JDK 21 found; install one (brew install --cask temurin@21) or pass JDK=/path/to/jdk)
endif
JDK_MAJOR := $(shell "$(JDK)/bin/java" -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.specification.version/{print $$2}')
JDK_ARCH  := $(shell "$(JDK)/bin/java" -XshowSettings:properties -version 2>&1 | awk -F'= ' '/os.arch/{print $$2}')
ifneq ($(JDK_ARCH),aarch64)
$(error JDK $(JDK) is $(JDK_ARCH), need aarch64)
endif
ifeq ($(shell [ "$(JDK_MAJOR)" -ge 17 ] 2>/dev/null && echo ok),)
$(error JDK $(JDK) is version '$(JDK_MAJOR)', need 17+ for jpackage)
endif
JLINK_COMPRESS := $(if $(shell [ $(JDK_MAJOR) -ge 21 ] && echo y),zip-6,2)

# ── app metadata ─────────────────────────────────────────────────────────────
APP_NAME  := BiglyBT
MAIN_CLASS := com.biglybt.ui.Main
BUNDLE_ID ?= com.biglybt.ui.lk
VENDOR    := Bigly Software
# Constants.BIGLYBT_VERSION, e.g. 4.1.0.1_B07 → full string kept for display, CFBundleVersion needs ≤3 numeric parts.
FULL_VERSION := $(shell sed -n 's/.*BIGLYBT_VERSION *= *"\([^"]*\)".*/\1/p' core/src/com/biglybt/core/util/Constants.java)
APP_VERSION  := $(shell echo '$(FULL_VERSION)' | grep -oE '^[0-9]+(\.[0-9]+){0,2}')
ifeq ($(APP_VERSION),)
$(error could not derive version from core/src/com/biglybt/core/util/Constants.java)
endif
ICON := app.icns

# ── SWT (arm64 natives) ──────────────────────────────────────────────────────
# 3.128.0 == SWT 4967r8, the same SWT build upstream ships in uis/lib/swt-cocoa-4967r8.jar (x86_64 only).
SWT_VERSION ?= 3.128.0
SWT_ARTIFACT := org.eclipse.swt.cocoa.macosx.aarch64
SWT_URL := https://repo1.maven.org/maven2/org/eclipse/platform/$(SWT_ARTIFACT)/$(SWT_VERSION)/$(SWT_ARTIFACT)-$(SWT_VERSION).jar

# ── JRE modules ──────────────────────────────────────────────────────────────
# BiglyBT and its plugins load lots of JDK API reflectively, so jdeps under-reports; ship java.se plus the
# service-provider / unsupported modules it touches. Modules absent from the chosen JDK are dropped.
WANT_MODULES := java.se jdk.unsupported jdk.crypto.ec jdk.crypto.cryptoki jdk.charsets jdk.localedata \
                jdk.zipfs jdk.net jdk.naming.dns jdk.management jdk.accessibility jdk.httpserver \
                jdk.security.auth jdk.security.jgss jdk.xml.dom jdk.dynalink
empty :=
space := $(empty) $(empty)
comma := ,
JDK_MODULES  := $(shell "$(JDK)/bin/java" --list-modules 2>/dev/null | sed 's/@.*//')
MODULES      := $(subst $(space),$(comma),$(strip $(filter $(JDK_MODULES),$(WANT_MODULES))))

# $APPDIR is expanded by the jpackage launcher at runtime to <bundle>/Contents/app.
JAVA_OPTIONS := \
  -XstartOnFirstThread \
  -Dazureus.install.path=$$APPDIR \
  -Djava.library.path=$$APPDIR \
  -Dswt.library.path=$$APPDIR \
  -Dazureus.app.name=$(APP_NAME) \
  -Dfile.encoding=UTF-8 \
  -Dsun.jnu.encoding=UTF-8 \
  --add-opens=java.base/java.net=ALL-UNNAMED \
  --add-opens=java.base/java.lang=ALL-UNNAMED \
  --add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
  --add-opens=java.base/java.io=ALL-UNNAMED \
  --add-opens=java.base/java.util=ALL-UNNAMED \
  --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
  --add-opens=java.base/sun.net.www.protocol.http=ALL-UNNAMED \
  --add-opens=java.base/sun.net.www.protocol.https=ALL-UNNAMED

# ── layout ───────────────────────────────────────────────────────────────────
BUILD   := build
CACHE   := $(BUILD)/cache
INPUT   := $(BUILD)/input
RUNTIME := $(BUILD)/runtime
IMAGE   := $(BUILD)/image
APP     := $(IMAGE)/$(APP_NAME).app
DMG     := $(BUILD)/$(APP_NAME)-$(FULL_VERSION)-$(ARCH).dmg

UI_JAR  := uis/target/BiglyBT.jar
SWT_JAR := $(CACHE)/$(SWT_ARTIFACT)-$(SWT_VERSION).jar
CLI_JAR := core/lib/commons-cli.jar
OSXACCESS := core/lib/libOSXAccess/libOSXAccess_10.5.jnilib

SOURCES := $(shell find core/src uis/src -type f ! -name '.DS_Store' 2>/dev/null) pom.xml core/pom.xml uis/pom.xml

.PHONY: all jar app dmg run verify clean distclean info
all: dmg
jar: $(UI_JAR)
app: $(BUILD)/.app.stamp
dmg: $(DMG)

info:
	@echo "JDK         $(JDK) ($(JDK_MAJOR), $(JDK_ARCH))"
	@echo "MVN_JDK     $(MVN_JDK)"
	@echo "version     $(FULL_VERSION) → CFBundleVersion $(APP_VERSION)"
	@echo "SWT         $(SWT_ARTIFACT) $(SWT_VERSION)"
	@echo "modules     $(MODULES)"

# ── 1. application jar (shaded core+ui; SWT and commons-cli stay external per manifest Class-Path) ─────────
$(UI_JAR): $(SOURCES)
	JAVA_HOME="$(MVN_JDK)" $(MVN) -q -B -DskipTests clean package
	@test -s $@

# ── 2. arm64 SWT jar, checksum-verified against Maven Central ────────────────
$(SWT_JAR):
	@mkdir -p $(@D)
	curl -fsSL --retry 3 -o $@.part "$(SWT_URL)"
	expected=$$(curl -fsSL --retry 3 "$(SWT_URL).sha1" | awk '{print $$1}'); \
	actual=$$(shasum -a 1 $@.part | awk '{print $$1}'); \
	[ -n "$$expected" ] && [ "$$expected" = "$$actual" ] || { echo "SHA-1 mismatch for $(SWT_URL): $$actual != $$expected" >&2; rm -f $@.part; exit 1; }
	mv $@.part $@

# ── 3. trimmed arm64 JRE ─────────────────────────────────────────────────────
$(RUNTIME)/release: Makefile
	rm -rf $(RUNTIME)
	@mkdir -p $(BUILD)
	"$(JLINK)" --add-modules $(MODULES) --strip-debug --no-header-files --no-man-pages \
	  --compress=$(JLINK_COMPRESS) --output $(RUNTIME)
	lipo -archs $(RUNTIME)/lib/server/libjvm.dylib | grep -qw $(ARCH)

# ── 4. jpackage input: jars + natives unpacked so nothing is extracted to ~/.swt at runtime ─────────────
$(BUILD)/.input.stamp: $(UI_JAR) $(SWT_JAR) $(CLI_JAR) $(OSXACCESS) Makefile
	rm -rf $(INPUT)
	@mkdir -p $(INPUT)
	cp $(UI_JAR) $(INPUT)/BiglyBT.jar
	cp $(SWT_JAR) $(INPUT)/swt.jar
	cp $(CLI_JAR) $(INPUT)/commons-cli.jar
	unzip -qjo $(SWT_JAR) '*.jnilib' -d $(INPUT)
	cp $(OSXACCESS) $(INPUT)/
	for f in $(INPUT)/*.jnilib; do \
	  lipo -archs "$$f" | grep -qw $(ARCH) || { echo "$$f lacks $(ARCH): $$(lipo -archs "$$f")" >&2; exit 1; }; \
	done
	@touch $@

# Hardened runtime (Developer ID signing only): the JVM needs JIT memory and must load our unsigned-by-Apple JNI libs.
$(BUILD)/entitlements.plist:
	@mkdir -p $(@D)
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>com.apple.security.cs.allow-jit</key><true/>' \
	  '<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>' \
	  '<key>com.apple.security.cs.disable-library-validation</key><true/>' \
	  '<key>com.apple.security.network.client</key><true/>' \
	  '<key>com.apple.security.network.server</key><true/>' \
	  '</dict></plist>' > $@

$(BUILD)/torrent.properties:
	@mkdir -p $(@D)
	printf '%s\n' 'extension=torrent' 'mime-type=application/x-bittorrent' 'description=BitTorrent File' \
	  'mac.CFBundleTypeRole=Viewer' 'mac.LSHandlerRank=Owner' 'mac.CFBundleTypeName=BitTorrent File' > $@

# ── 5. .app bundle ───────────────────────────────────────────────────────────
$(BUILD)/.app.stamp: $(BUILD)/.input.stamp $(RUNTIME)/release $(BUILD)/torrent.properties $(BUILD)/entitlements.plist $(ICON) Makefile
	rm -rf $(IMAGE) $(BUILD)/jpackage-tmp
	"$(JPACKAGE)" --type app-image \
	  --name $(APP_NAME) --app-version $(APP_VERSION) --vendor "$(VENDOR)" \
	  --copyright "Copyright © $(VENDOR)" \
	  --input $(INPUT) --main-jar BiglyBT.jar --main-class $(MAIN_CLASS) \
	  --runtime-image $(RUNTIME) --icon $(ICON) \
	  --mac-package-identifier $(BUNDLE_ID) --mac-package-name $(APP_NAME) \
	  --file-associations $(BUILD)/torrent.properties \
	  --temp $(BUILD)/jpackage-tmp \
	  $(foreach o,$(JAVA_OPTIONS),--java-options '$(o)') \
	  --dest $(IMAGE)
	$(MAKE) --no-print-directory plist
	codesign --force --deep --timestamp=none --sign "$(or $(SIGN_ID),-)" \
	  $(if $(SIGN_ID),--options runtime --entitlements $(BUILD)/entitlements.plist) $(APP)
	@touch $@

.PHONY: plist
plist:
	p=$(APP)/Contents/Info.plist; \
	$(PLISTBUDDY) -c 'Set :CFBundleShortVersionString $(FULL_VERSION)' $$p; \
	$(PLISTBUDDY) -c 'Delete :CFBundleURLTypes' $$p 2>/dev/null || true; \
	$(PLISTBUDDY) -c 'Add :CFBundleURLTypes array' \
	  -c 'Add :CFBundleURLTypes:0 dict' \
	  -c 'Add :CFBundleURLTypes:0:CFBundleURLName string Magnet URI' \
	  -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' \
	  -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string magnet' \
	  -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string bc' \
	  -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:2 string bctp' $$p; \
	$(PLISTBUDDY) -c 'Delete :NSHighResolutionCapable' $$p 2>/dev/null || true; \
	$(PLISTBUDDY) -c 'Add :NSHighResolutionCapable bool true' $$p; \
	$(PLISTBUDDY) -c 'Delete :LSArchitecturePriority' $$p 2>/dev/null || true; \
	$(PLISTBUDDY) -c 'Add :LSArchitecturePriority array' -c 'Add :LSArchitecturePriority:0 string $(ARCH)' $$p; \
	plutil -lint $$p

# ── 6. checks ────────────────────────────────────────────────────────────────
verify: $(BUILD)/.app.stamp
	@bad=0; \
	while IFS= read -r -d '' f; do \
	  if file -b "$$f" | grep -q 'Mach-O'; then \
	    lipo -archs "$$f" | grep -qw $(ARCH) || { echo "NOT $(ARCH): $$f ($$(lipo -archs "$$f"))"; bad=1; }; \
	  fi; \
	done < <(find $(APP) -type f -print0); \
	unzip -l $(APP)/Contents/app/swt.jar | grep -q 'libswt-cocoa-.*\.jnilib' || { echo 'swt.jar has no cocoa natives'; bad=1; }; \
	codesign --verify --deep --strict $(APP) || bad=1; \
	grep -q 'XstartOnFirstThread' $(APP)/Contents/app/$(APP_NAME).cfg || { echo 'launcher cfg lacks -XstartOnFirstThread'; bad=1; }; \
	[ $$bad -eq 0 ] && echo "verify OK: $(APP) is $(ARCH)-clean and signed" || exit 1

run: $(BUILD)/.app.stamp
	$(APP)/Contents/MacOS/$(APP_NAME)

# ── 7. dmg (hdiutil directly: no Finder/AppleScript automation, works headless) ─────────────────────────
$(DMG): $(BUILD)/.app.stamp
	$(MAKE) --no-print-directory verify
	rm -rf $(BUILD)/dmg-root $@
	@mkdir -p $(BUILD)/dmg-root
	ditto $(APP) $(BUILD)/dmg-root/$(APP_NAME).app
	ln -s /Applications $(BUILD)/dmg-root/Applications
	hdiutil create -quiet -volname "$(APP_NAME) $(FULL_VERSION)" -srcfolder $(BUILD)/dmg-root \
	  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov $@
	$(if $(SIGN_ID),codesign --force --timestamp --sign "$(SIGN_ID)" $@)
	hdiutil verify -quiet $@
	rm -rf $(BUILD)/dmg-root
	@echo "→ $@"

clean:
	rm -rf $(BUILD)

distclean: clean
	JAVA_HOME="$(MVN_JDK)" $(MVN) -q -B clean
