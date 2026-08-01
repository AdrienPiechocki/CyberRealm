# Minimal Wayland kiosk compositor for CyberRealm.
#
# Usage:
#   make            build ./cyberrealm
#   ./cyberrealm    run compositor, launches CyberRealm/build/CyberRealm.x86_64
#   ./cyberrealm -c "my-command"   launch a custom command instead
#
# Headless test (no physical display):
#   WLR_BACKEND=headless WLR_RENDERER=pixman ./cyberrealm -c "weston-terminal"
#
# XDG_RUNTIME_DIR must be set (normally already is on a desktop session).

CC ?= cc
CFLAGS ?= -O2 -g
CFLAGS += -Wall -Wextra -DWLR_USE_UNSTABLE -I. $(shell pkg-config --cflags wlroots-0.18 wayland-server xkbcommon)
LDLIBS = $(shell pkg-config --libs wlroots-0.18 wayland-server xkbcommon)

PC_XML = $(shell pkg-config --variable=pkgdatadir wayland-protocols)

all: cyberrealm

pointer-constraints-unstable-v1-protocol.h: $(PC_XML)/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml
	wayland-scanner server-header $< $@

xdg-shell-protocol.h: $(PC_XML)/stable/xdg-shell/xdg-shell.xml
	wayland-scanner server-header $< $@

cyberrealm: main.c pointer-constraints-unstable-v1-protocol.h xdg-shell-protocol.h
	$(CC) $(CFLAGS) -o $@ main.c $(LDLIBS)

clean:
	rm -f cyberrealm pointer-constraints-unstable-v1-protocol.h xdg-shell-protocol.h

.PHONY: all clean
