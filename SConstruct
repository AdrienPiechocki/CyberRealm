#!/usr/bin/env python
import os

env = SConscript("godot-cpp/SConstruct")

env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

# Dépendances système via pkg-config. Adapter le nom du paquet wlroots
# selon la version installée (wlroots-0.18, wlroots-0.19, ...).
env.ParseConfig("pkg-config --cflags --libs wlroots-0.18 wayland-server xkbcommon libdrm")

# wlroots 0.18 masque son API derrière cette macro tant qu'elle n'est pas
# stabilisée - sans elle, tous ses headers refusent de compiler.
env.Append(CPPDEFINES=["WLR_USE_UNSTABLE"])

# xdg-shell-protocol.h/.c ne sont pas fournis par wlroots: ils doivent être
# générés à partir du XML de wayland-protocols via wayland-scanner. Adapter
# le chemin si votre distro l'installe ailleurs
# (`pkg-config --variable=pkgdatadir wayland-protocols` donne le bon chemin).
xdg_shell_xml = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"

xdg_shell_header = env.Command(
    "protocols/xdg-shell-protocol.h",
    xdg_shell_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)
xdg_shell_source = env.Command(
    "protocols/xdg-shell-protocol.c",
    xdg_shell_xml,
    "wayland-scanner private-code $SOURCE $TARGET",
)

env.Append(CPPPATH=["protocols/"])
sources += [xdg_shell_source]
# Force la génération du header avant toute compilation qui l'inclut
# (wlr_compositor.h dépend indirectement de xdg-shell-protocol.h).
env.Depends(sources, xdg_shell_header)

if env["platform"] == "macos":
    library = env.SharedLibrary(
        "demo/bin/libwaylandgodot.{}.{}.framework/libwaylandgodot.{}.{}".format(
            env["platform"], env["target"], env["platform"], env["target"]
        ),
        source=sources,
    )
else:
    library = env.SharedLibrary(
        "demo/bin/libwaylandgodot{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
        source=sources,
    )

Default(library)
