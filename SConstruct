#!/usr/bin/env python
import os
import subprocess

env = SConscript("godot-cpp/SConstruct")

env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

# Dépendances système via pkg-config. Adapter le nom du paquet wlroots
# selon la version installée (wlroots-0.18, wlroots-0.19, ...).
env.ParseConfig("pkg-config --cflags --libs wlroots-0.18 wayland-server xkbcommon libdrm")

# Vulkan — nécessaire pour l'import zero-copy DMA-BUF → VkImage via
# VK_KHR_external_memory_fd.  Les headers (vulkan/vulkan.h) et la
# librairie de chargement (libvulkan.so) sont requis à la compilation.
env.ParseConfig("pkg-config --cflags --libs vulkan")

# dbus-1 pour le daemon de notification (optionnel)
if subprocess.call(["pkg-config", "--exists", "dbus-1"]) == 0:
    env.ParseConfig("pkg-config --cflags --libs dbus-1")
    env.Append(CPPDEFINES=["HAVE_DBUS"])
else:
    print("WARNING: dbus-1 not found — notification daemon disabled")

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

# Protocoles instables: pointer-constraints-v1 + relative-pointer-v1
pointer_constraints_xml = "/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml"
pointer_constraints_header = env.Command(
    "protocols/pointer-constraints-unstable-v1-protocol.h",
    pointer_constraints_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)

relative_pointer_xml = "/usr/share/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml"
relative_pointer_header = env.Command(
    "protocols/relative-pointer-unstable-v1-protocol.h",
    relative_pointer_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)

env.Depends(sources, pointer_constraints_header)
env.Depends(sources, relative_pointer_header)

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
