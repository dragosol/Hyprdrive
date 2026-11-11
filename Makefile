CXX ?= g++

# The Lua Hyprland itself is linked to (scripts/lua_pc.sh): its headers' constants
# must match the liblua the compositor runs. Arch has `lua` 5.5 (Hyprland's) AND
# `lua54` (via libinput); the old "lua5.4 whenever it exists" pick crashed
# `hyprctl hyprdrive-binds` (dragosol/Hyprdrive#1).
# THE PREREQUISITES (scripts/prereqs.sh): before anything compiles, whatever the
# build needs and the system lacks is installed (it asks first; HYPRDRIVE_YES=1
# does not), and where the distro ships no Hyprland headers of the installed
# version (Fedora) they are made from Hyprland's source into a private SDK,
# whose pkgconfig dir comes back here. Not for the goals that compile nothing.
ifneq ($(if $(MAKECMDGOALS),$(filter-out install-only uninstall clean,$(MAKECMDGOALS)),all),)
HYPRLAND_SDK_PC := $(shell bash scripts/prereqs.sh --make)
ifneq ($(.SHELLSTATUS),0)
$(error Hyprdrive cannot be built until the prerequisites above are installed)
endif
ifneq ($(HYPRLAND_SDK_PC),)
export PKG_CONFIG_PATH := $(HYPRLAND_SDK_PC)$(if $(PKG_CONFIG_PATH),:$(PKG_CONFIG_PATH))
endif
endif

LUA_PC := $(shell sh scripts/lua_pc.sh)

# Parallel by default: the edit->build->hyprrestart->gate loop lives and dies
# by this. Override with make -j1 for readable error output.
MAKEFLAGS += -j$(shell nproc)

# -O2 is the shipped artifact and what every pixel gate grades. OPT=-O0 for
# debugging sessions where optimized frames confuse the picture.
OPT ?= -O2

PKGS := pixman-1 libdrm hyprland pangocairo fontconfig libinput libudev wayland-server \
        xkbcommon libsystemd gio-2.0 gio-unix-2.0 $(LUA_PC)

# The sources live in src/<area>/ (one folder per subsystem; see src/README.md),
# and a module of an area in src/<area>/<module>/ (src/apps/identity/).
# Every #include is still a bare name: each folder is on the include path, and no
# two files share a name, so the objects stay flat in .build/. --embed-dir=. is
# for BuiltinIcons.cpp's #embed "assets/icons/...", which resolves from the root.
SRC_DIRS := $(sort $(dir $(wildcard src/*/*.cpp src/*/*.hpp src/*/*/*.cpp src/*/*/*.hpp)))
SRC_INC  := $(addprefix -I,$(SRC_DIRS:/=))
SRCS := $(wildcard src/*/*.cpp src/*/*/*.cpp)
OBJS := $(addprefix .build/,$(notdir $(SRCS:.cpp=.o)))
DEPS := $(OBJS:.o=.d)
vpath %.cpp $(SRC_DIRS)
ifneq ($(words $(SRCS)),$(words $(sort $(notdir $(SRCS)))))
$(error two source files share a name: $(filter-out $(sort $(notdir $(SRCS))),$(notdir $(SRCS))) -- objects are flat in .build/)
endif

# Goals that compile nothing ask pkg-config nothing: install-only runs as a user
# who may not have the SDK on PKG_CONFIG_PATH at all (see install-only).
ifneq ($(if $(MAKECMDGOALS),$(filter-out install-only uninstall clean,$(MAKECMDGOALS)),all),)
CXXFLAGS := -fPIC $(OPT) -g -std=c++2b -Wno-narrowing -I.build $(SRC_INC) --embed-dir=. \
            $(shell pkg-config --cflags $(PKGS))
# fontconfig: Fonts.cpp asks it which family "monospace" is and whether an icon
# font covers the UI glyphs. Hyprland's pango already loads it; linking it
# names the dependency instead of leaning on the host's.
LDLIBS   := $(shell pkg-config --libs libsystemd gio-2.0 gio-unix-2.0 fontconfig xcb)
endif

ifeq ($(CXX),g++)
    CXXFLAGS += -fno-gnu-unique
endif

VERSION_HEADER = .build/PluginVersion.hpp
VERSION_SCRIPT = scripts/generate-plugin-version.sh

.PHONY: all check check-asan gates clean install install-only uninstall FORCE

# An undefined symbol is a lazy-bind compositor kill (three same-day incidents
# recorded in symcheck.sh's header), so the check IS part of the build. So is
# keycheck: a config key read through the deprecated alias resolves, returns the
# default forever and reports nothing -- see that script's header. And so are
# the host tests: they cost a second, they need no compositor, and a pure
# function that is only ever checked by photographing a tile is checked three
# minutes and one fixture at a time.
all: hyprdrive.so check

hyprdrive.so: $(OBJS)
	$(CXX) -shared $(OBJS) -o $@ $(LDLIBS)

# dock stacks C: the icons are #embed-ded, so their object depends on them.
.build/BuiltinIcons.o: $(wildcard assets/icons/*.svg) assets/scratchpad-symbolic.svg

.build/%.o: %.cpp | $(VERSION_HEADER)
	@mkdir -p .build
	$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

# FORCE re-runs the script every make; the script only touches the header when
# the hash actually changed (cmp -s inside), so incremental builds stay warm.
$(VERSION_HEADER): FORCE $(VERSION_SCRIPT)
	@sh $(VERSION_SCRIPT) $@ .

FORCE:

check: hyprdrive.so
	bash scripts/symcheck.sh
	bash scripts/keycheck.sh
	bash scripts/gen_keys_table.sh --check
	bash tests/host_tests.sh
	bash tests/layout_cycle_test.sh
	python3 tests/manifest_check.py
	python3 tests/schema_keys_test.py
	python3 tests/config_defaults_test.py
	python3 tests/private_modes_test.py
	python3 tests/hdicons_test.py
	python3 tests/settings_app_test.py
	python3 tests/update_cli_test.py
	python3 tests/fragment_test.py
	python3 tests/shell_restart_test.py
	python3 tests/agent_run_test.py
	python3 tests/tool_scripts_test.py
	python3 tests/integration_fallbacks_test.py

# The host tests again, every one built with AddressSanitizer + UBSan (leaks
# included) and any report a failure (tests/host_tests.sh, HOST_TEST_SANITIZE).
# Not part of `check`: it adds about 30 s to the host tests' 85 (measured
# 2026-11-11 on fedora, 8 jobs busy elsewhere), past what every build should
# pay. Run it after touching a pure function or a worker. Needs no compositor
# and no hyprdrive.so; g++ without libasan falls back to clang++.
check-asan:
	HOST_TEST_SANITIZE=1 bash tests/host_tests.sh

PREFIX ?= $(HOME)/.local

# gates: the behaviour gates on the headless rig (tests/gates/run.sh; see
# tests/README.md). NOT part of all/check: they need the rig's user hyprtest via
# passwordless sudo, mutter and kitty, and take ~6 min. Builds nothing: it tests
# the hyprdrive.so already here (make first). GATES=name... runs some;
# GATES_ARGS=--control runs each gate's control instead.
gates:
	bash tests/gates/run.sh $(GATES_ARGS) $(GATES)

# check, not just hyprdrive.so: `make install` used to skip symcheck entirely,
# which is how an undefined-symbol .so reached ~/.local/lib and killed every
# login until the plugin was moved aside (2026-09-15).
#
# Native and Omarchy alike (scripts/install-fragments.sh asks
# scripts/hyprdrive-integration which one this is): the .so and the scratchpad
# glyph under $(PREFIX)/lib/hyprdrive, the hyprdrive-integration CLI in
# $(PREFIX)/bin, the Lua fragments + loader in ~/.config/hypr, one require line
# in hyprland.lua, and the settings panel ONLY on Omarchy -- elsewhere the
# standalone settings app (settings/: $(PREFIX)/bin/hyprdrive-settings, its
# QML in $(PREFIX)/share/hyprdrive, hdpanel/hdicons in lib). Force a native
# install on a machine with Omarchy files: HYPRDRIVE_NO_OMARCHY=1 make install.
install: hyprdrive.so check
	$(MAKE) --no-print-directory install-only PREFIX="$(PREFIX)"

# install-only: the copy step alone, with NO prerequisites -- for installing a
# .so that was built and checked already, as another user. The .build/*.d deps
# name the SDK headers the objects were compiled against; a user who cannot
# read them (the headless harness's hyprtest, given a tree dragos built) sees
# every header as missing, so `make install` rebuilt the plugin there and
# failed. This target never compiles: it refuses when there is no .so, and it
# does not run `check` (the builder runs `make`, which does, first).
# The installed copy carries no debug information (it is most of the file: about
# 240 MB with it, 9 MB without). Function names stay, so a crash report still
# names where it died; KEEP_DEBUG=1 make install keeps line numbers for gdb.
# The build's own hyprdrive.so is left as it is.
install-only:
	@[ -s hyprdrive.so ] || { echo "install-only: no hyprdrive.so -- run make (build + check) first" >&2; exit 1; }
	install -Dm755 hyprdrive.so $(PREFIX)/lib/hyprdrive/hyprdrive.so
ifeq ($(KEEP_DEBUG),)
	strip --strip-debug $(PREFIX)/lib/hyprdrive/hyprdrive.so
endif
	install -Dm644 assets/scratchpad-symbolic.svg $(PREFIX)/lib/hyprdrive/scratchpad-symbolic.svg
	install -Dm755 ui/bin/agent-run $(PREFIX)/lib/hyprdrive/agent-run
	PREFIX="$(PREFIX)" bash scripts/install-fragments.sh

uninstall:
	PREFIX="$(PREFIX)" bash scripts/uninstall.sh

clean:
	rm -rf .build hyprdrive.so

# 1.9.50 moved the sources into src/, and a .build/ left by an older release holds
# .d files that name ./AppInfo.cpp and the rest. Reading them stopped every update
# across 1.9.50 at "No rule to make target 'AppInfo.cpp'" until a make clean
# (2026-11-09). An empty rule for each old name lets make rebuild those objects
# from src/ instead, the way -MP already treats a header that is gone.
# The move into src/<area>/ did the same to every .d written between 1.9.50 and
# then ("src/AppInfo.cpp", "src/Dock.hpp"), so those names get the empty rule too.
$(notdir $(SRCS)):
$(addprefix src/,$(notdir $(wildcard src/*/*.cpp src/*/*.hpp))):
# Phase 2 renamed three pairs of files (scrollOverview -> Overview, OmarchySearch ->
# SearchBackend, Spring -> SpringLoad). A .d written before that names the old
# spellings, at whichever of the three layouts it was built with, so each old
# name gets the same empty rule.
RENAMED_FROM := scrollOverview.cpp scrollOverview.hpp OmarchySearch.cpp OmarchySearch.hpp Spring.cpp Spring.hpp
$(RENAMED_FROM) $(addprefix src/,$(RENAMED_FROM)) src/overview/scrollOverview.cpp src/overview/scrollOverview.hpp \
    src/search/OmarchySearch.cpp src/search/OmarchySearch.hpp src/dock/Spring.cpp src/dock/Spring.hpp:

-include $(DEPS)
