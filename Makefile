CXX ?= g++

# ponytail: Fedora ships lua.pc, Arch lua5.4.pc
LUA_PC := $(shell pkg-config --exists lua5.4 && echo lua5.4 || echo lua)

EXTRA_FLAGS =
VERSION_HEADER = .build/PluginVersion.hpp
VERSION_SCRIPT = scripts/generate-plugin-version.sh

ifeq ($(CXX),g++)
    EXTRA_FLAGS += -fno-gnu-unique
endif

.PHONY: all clean FORCE

all: $(VERSION_HEADER)
	$(CXX) -shared -fPIC $(EXTRA_FLAGS) -I.build main.cpp AppSearch.cpp Dock.cpp Locations.cpp TileChrome.cpp Minimize.cpp SearchProviders.cpp LauncherEntry.cpp Config.cpp DropIndicator.cpp OverviewGesture.cpp OverviewManager.cpp OverviewPassElement.cpp OverviewRender.cpp Window.cpp scrollOverview.cpp -o scrolloverview.so -g `pkg-config --cflags pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server xkbcommon libsystemd gio-2.0 gio-unix-2.0 $(LUA_PC)` -std=c++2b -Wno-narrowing `pkg-config --libs libsystemd gio-2.0 gio-unix-2.0`

$(VERSION_HEADER): FORCE $(VERSION_SCRIPT)
	sh $(VERSION_SCRIPT) $@ .

FORCE:

clean:
	rm -f ./scrolloverview.so $(VERSION_HEADER)
