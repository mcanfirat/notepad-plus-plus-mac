# Notepad++ for macOS — build
#   make            -> dist/Notepad++.app (universal arm64+x86_64)
#   make run        -> build and launch
#   make selftest   -> build and run headless self-test
#   make exercise   -> build and drive the GUI (menus, all languages/themes, 80 commands) headlessly
#   make screenshot -> build and render the main window to build/screenshot.png (no Screen Recording permission needed)
#   make dmg        -> dist/Notepad++.dmg
#   make syntax-Foo -> syntax-check src/Foo.mm only
# Requires: Xcode command line tools, python3 + Pillow (icon), ../notepad-plus-plus checkout (NPP=...)

NPP      ?= $(abspath ../notepad-plus-plus)
BUILD    := build
DIST     := dist
APP      := $(DIST)/Notepad++.app
ARCHS    ?= -arch arm64 -arch x86_64
XCARCHS  ?= arm64 x86_64
MINOS    ?= 12.0
CXX      := clang++
WARN     := -Wall -Wno-deprecated-declarations -Wno-unused-parameter
CXXFLAGS := -std=c++17 -O2 -mmacosx-version-min=$(MINOS) $(ARCHS) -DNDEBUG $(WARN)
SCI_SYM  := $(abspath $(BUILD)/sci)
SCI_FW   := $(SCI_SYM)/Release/Scintilla.framework
INCS     := -I$(NPP)/lexilla/include -I$(NPP)/scintilla/include -I$(NPP)/PowerEditor/src/uchardet -Isrc
APPFLAGS := $(CXXFLAGS) -fobjc-arc -fobjc-weak -x objective-c++ -F$(SCI_SYM)/Release $(INCS)

# ---------- Lexilla (static, incl. N++'s LexUser/LexObjC/LexSearchResult) ----------
LEX_SRCS := $(NPP)/lexilla/src/Lexilla.cxx $(wildcard $(NPP)/lexilla/lexlib/*.cxx) $(wildcard $(NPP)/lexilla/lexers/*.cxx)
LEX_OBJS := $(patsubst %.cxx,$(BUILD)/lexilla/%.o,$(notdir $(LEX_SRCS)))
vpath %.cxx $(NPP)/lexilla/src $(NPP)/lexilla/lexlib $(NPP)/lexilla/lexers

$(BUILD)/lexilla/%.o: %.cxx | $(BUILD)/lexilla
	$(CXX) $(CXXFLAGS) -fvisibility=hidden -I$(NPP)/lexilla/include -I$(NPP)/scintilla/include -I$(NPP)/lexilla/lexlib -Icompat -c $< -o $@

$(BUILD)/liblexilla.a: $(LEX_OBJS)
	libtool -static -o $@ $^

# ---------- uchardet (N++'s vendored copy; charset detection) ----------
UCD_SRCS := $(wildcard $(NPP)/PowerEditor/src/uchardet/*.cpp)
UCD_OBJS := $(patsubst %.cpp,$(BUILD)/uchardet/%.o,$(notdir $(UCD_SRCS)))
vpath %.cpp $(NPP)/PowerEditor/src/uchardet

$(BUILD)/uchardet/%.o: %.cpp | $(BUILD)/uchardet
	$(CXX) $(CXXFLAGS) -fvisibility=hidden -w -I$(NPP)/PowerEditor/src/uchardet -c $< -o $@

$(BUILD)/libuchardet.a: $(UCD_OBJS)
	libtool -static -o $@ $^

# ---------- Scintilla.framework (Cocoa backend from the N++ tree) ----------
.PHONY: scintilla
scintilla:
	xcodebuild -project $(NPP)/scintilla/cocoa/Scintilla/Scintilla.xcodeproj -target Scintilla -configuration Release \
	  ARCHS="$(XCARCHS)" ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=$(MINOS) \
	  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
	  SYMROOT=$(SCI_SYM) OBJROOT=$(abspath $(BUILD)/sci-obj) build -quiet

# ---------- App ----------
APP_SRCS := $(wildcard src/*.mm)
APP_HDRS := $(wildcard src/*.h)
APP_OBJS := $(patsubst src/%.mm,$(BUILD)/app/%.o,$(APP_SRCS))

$(BUILD)/app/%.o: src/%.mm $(APP_HDRS) | $(BUILD)/app scintilla
	$(CXX) $(APPFLAGS) -c $< -o $@

$(BUILD)/Notepad++: $(APP_OBJS) $(BUILD)/liblexilla.a $(BUILD)/libuchardet.a
	$(CXX) $(CXXFLAGS) -fobjc-arc -F$(SCI_SYM)/Release -framework Scintilla -framework Cocoa -framework UniformTypeIdentifiers \
	  $^ -o $@ -Wl,-rpath,@executable_path/../Frameworks

# ---------- Bundle ----------
.PHONY: all bundle run clean distclean selftest exercise dialogs screenshot dmg install
all: bundle

bundle: $(BUILD)/Notepad++ Resources/Info.plist Resources/npp.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Frameworks $(APP)/Contents/Resources/themes
	cp $(BUILD)/Notepad++ $(APP)/Contents/MacOS/
	cp -R $(SCI_FW) $(APP)/Contents/Frameworks/
	rm -rf $(APP)/Contents/Frameworks/Scintilla.framework/Versions/A/Headers $(APP)/Contents/Frameworks/Scintilla.framework/Headers $(APP)/Contents/Frameworks/Scintilla.framework/Versions/A/Modules $(APP)/Contents/Frameworks/Scintilla.framework/Modules
	cp Resources/Info.plist $(APP)/Contents/
	cp Resources/npp.icns $(APP)/Contents/Resources/
	cp $(NPP)/PowerEditor/src/langs.model.xml $(NPP)/PowerEditor/src/stylers.model.xml $(APP)/Contents/Resources/
	cp $(NPP)/PowerEditor/installer/themes/*.xml $(APP)/Contents/Resources/themes/
	mkdir -p $(APP)/Contents/Resources/functionList $(APP)/Contents/Resources/userDefineLangs $(APP)/Contents/Resources/autoCompletion
	cp $(NPP)/PowerEditor/installer/functionList/*.xml $(APP)/Contents/Resources/functionList/
	cp $(NPP)/PowerEditor/installer/APIs/*.xml $(APP)/Contents/Resources/autoCompletion/
	mkdir -p $(APP)/Contents/Resources/nativeLang
	cp $(NPP)/PowerEditor/installer/nativeLang/*.xml $(APP)/Contents/Resources/nativeLang/
	-cp $(NPP)/PowerEditor/bin/userDefineLangs/*.xml $(APP)/Contents/Resources/userDefineLangs/ 2>/dev/null
	cp $(NPP)/LICENSE $(APP)/Contents/Resources/LICENSE.txt
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	# Sign inside-out (--deep is deprecated and re-seals nested code with the wrong identity).
	codesign --force --sign - $(APP)/Contents/Frameworks/Scintilla.framework/Versions/A
	codesign --force --sign - $(APP)
	@echo "==> $(APP)"

run: bundle
	open $(APP)

selftest: bundle
	$(APP)/Contents/MacOS/Notepad++ --selftest

dialogs: bundle
	@-pkill -f 'Notepad\+\+.app/Contents/MacOS' 2>/dev/null; true
	NPP_EXERCISE_DIALOGS=1 $(APP)/Contents/MacOS/Notepad++ "$(abspath fixtures/hello.cpp)"

exercise: bundle
	@-pkill -f 'Notepad\+\+.app/Contents/MacOS' 2>/dev/null; true
	NPP_EXERCISE=1 $(APP)/Contents/MacOS/Notepad++ "$(abspath fixtures/hello.cpp)" "$(abspath fixtures/script.py)" 2>&1 | grep -v '^skip'

screenshot: bundle
	@-pkill -f 'Notepad\+\+.app/Contents/MacOS' 2>/dev/null; true
	NPP_SCREENSHOT=$(abspath $(BUILD)/screenshot.png) $(APP)/Contents/MacOS/Notepad++ "$(abspath fixtures/hello.cpp)" "$(abspath fixtures/page.html)" 2>&1 | grep -v 'frame='
	@echo "==> $(BUILD)/screenshot.png"

# The app is ad-hoc signed (no Apple Developer ID), so macOS quarantines and blocks it after a download.
# Installing locally never sets the quarantine flag; the DMG carries the one command that clears it.
install: bundle
	rm -rf /Applications/Notepad++.app
	cp -R $(APP) /Applications/
	xattr -dr com.apple.quarantine /Applications/Notepad++.app
	@echo "==> /Applications/Notepad++.app"

dmg: bundle
	rm -rf $(BUILD)/dmg $(DIST)/Notepad++.dmg
	mkdir -p $(BUILD)/dmg
	cp -R $(APP) $(BUILD)/dmg/
	ln -s /Applications $(BUILD)/dmg/Applications
	cp Resources/INSTALL.txt "$(BUILD)/dmg/OKU - READ ME.txt"
	hdiutil create -volname "Notepad++" -srcfolder $(BUILD)/dmg -ov -format UDZO $(DIST)/Notepad++.dmg
	@echo "==> $(DIST)/Notepad++.dmg"
	@echo "    After copying to /Applications, run: xattr -dr com.apple.quarantine /Applications/Notepad++.app"

# syntax-only check for a single source: make syntax-NPPDocument
syntax-%: src/%.mm | scintilla
	$(CXX) $(APPFLAGS) -fsyntax-only $<

$(BUILD)/lexilla $(BUILD)/uchardet $(BUILD)/app:
	mkdir -p $@

clean:
	rm -rf $(BUILD)/app $(BUILD)/Notepad++ $(DIST)
distclean:
	rm -rf $(BUILD) $(DIST)
