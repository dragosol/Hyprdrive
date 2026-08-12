CXX ?= g++

# ponytail: Fedora ships lua.pc, Arch lua5.4.pc
LUA_PC := $(shell pkg-config --exists lua5.4 && echo lua5.4 || echo lua)

# Parallel by default: the edit->build->hyprrestart->gate loop lives and dies
# by this. Override with make -j1 for readable error output.
MAKEFLAGS += -j$(shell nproc)

# -O2 is the shipped artifact and what every pixel gate grades. OPT=-O0 for
# debugging sessions where optimized frames confuse the picture.
OPT ?= -O2

PKGS := pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server \
        xkbcommon libsystemd gio-2.0 gio-unix-2.0 $(LUA_PC)

CXXFLAGS := -fPIC $(OPT) -g -std=c++2b -Wno-narrowing -I.build \
            $(shell pkg-config --cflags $(PKGS))
LDLIBS   := $(shell pkg-config --libs libsystemd gio-2.0 gio-unix-2.0)

ifeq ($(CXX),g++)
    CXXFLAGS += -fno-gnu-unique
endif

SRCS := $(wildcard *.cpp)
OBJS := $(SRCS:%.cpp=.build/%.o)
DEPS := $(OBJS:.o=.d)

VERSION_HEADER = .build/PluginVersion.hpp
VERSION_SCRIPT = scripts/generate-plugin-version.sh

.PHONY: all check clean FORCE

# An undefined symbol is a lazy-bind compositor kill (three same-day incidents
# recorded in symcheck.sh's header), so the check IS part of the build. So is
# keycheck: a config key read through the deprecated alias resolves, returns the
# default forever and reports nothing -- see that script's header. And so is the
# schema: it MIRRORS Config.cpp for the settings app, and an unrefreshed mirror
# is an option the app cannot reach and nobody is told about.
all: hyprdrive.so check

hyprdrive.so: $(OBJS)
	$(CXX) -shared $(OBJS) -o $@ $(LDLIBS)

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
	python3 scripts/gen_schema.py --check

clean:
	rm -rf .build hyprdrive.so

-include $(DEPS)
