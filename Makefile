CXX ?= g++

# ponytail: Fedora ships lua.pc, Arch lua5.4.pc
LUA_PC := $(shell pkg-config --exists lua5.4 && echo lua5.4 || echo lua)

# Parallel by default: the edit->build->hyprrestart->gate loop lives and dies
# by this. Override with make -j1 for readable error output.
MAKEFLAGS += -j$(shell nproc)

# -O2 is the shipped artifact and what every pixel gate grades. OPT=-O0 for
# debugging sessions where optimized frames confuse the picture.
OPT ?= -O2

PKGS := pixman-1 libdrm hyprland pangocairo fontconfig libinput libudev wayland-server \
        xkbcommon libsystemd gio-2.0 gio-unix-2.0 $(LUA_PC)

# Goals that compile nothing ask pkg-config nothing: install-only runs as a user
# who may not have the SDK on PKG_CONFIG_PATH at all (see install-only).
ifneq ($(if $(MAKECMDGOALS),$(filter-out install-only uninstall clean,$(MAKECMDGOALS)),all),)
CXXFLAGS := -fPIC $(OPT) -g -std=c++2b -Wno-narrowing -I.build \
            $(shell pkg-config --cflags $(PKGS))
# fontconfig: Fonts.cpp asks it which family "monospace" is and whether an icon
# font covers the UI glyphs. Hyprland's pango already loads it; linking it
# names the dependency instead of leaning on the host's.
LDLIBS   := $(shell pkg-config --libs libsystemd gio-2.0 gio-unix-2.0 fontconfig)
endif

ifeq ($(CXX),g++)
    CXXFLAGS += -fno-gnu-unique
endif

SRCS := $(wildcard *.cpp)
OBJS := $(SRCS:%.cpp=.build/%.o)
DEPS := $(OBJS:.o=.d)

VERSION_HEADER = .build/PluginVersion.hpp
VERSION_SCRIPT = scripts/generate-plugin-version.sh

.PHONY: all check clean install install-only uninstall FORCE

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
	bash scripts/host_tests.sh
	bash scripts/layout_cycle_test.sh
	python3 scripts/manifest_check.py
	python3 scripts/private_modes_test.py
	python3 scripts/hdicons_test.py
	python3 scripts/settings_app_test.py
	python3 scripts/integration_fallbacks_test.py

PREFIX ?= $(HOME)/.local

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
install-only:
	@[ -s hyprdrive.so ] || { echo "install-only: no hyprdrive.so -- run make (build + check) first" >&2; exit 1; }
	install -Dm755 hyprdrive.so $(PREFIX)/lib/hyprdrive/hyprdrive.so
	install -Dm644 assets/scratchpad-symbolic.svg $(PREFIX)/lib/hyprdrive/scratchpad-symbolic.svg
	PREFIX="$(PREFIX)" bash scripts/install-fragments.sh

uninstall:
	PREFIX="$(PREFIX)" bash scripts/uninstall.sh

clean:
	rm -rf .build hyprdrive.so

-include $(DEPS)
