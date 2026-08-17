#!/usr/bin/env python
import os
import subprocess

env = SConscript("godot-cpp/SConstruct", {"api_version": "4.7"})

env.Append(CPPPATH=["compositors/ingame/"])
sources = Glob("compositors/ingame/*.cpp") + Glob("compositors/ingame/*.c")

# Dépendances système via pkg-config. Adapter le nom du paquet wlroots
# selon la version installée (wlroots-0.18, wlroots-0.19, ...).
env.ParseConfig("pkg-config --cflags --libs wlroots-0.19 wayland-server xkbcommon libdrm")

# Vulkan — nécessaire pour l'import zero-copy DMA-BUF → VkImage via
# VK_KHR_external_memory_fd.  Les headers (vulkan/vulkan.h) et la
# librairie de chargement (libvulkan.so) sont requis à la compilation.
env.ParseConfig("pkg-config --cflags --libs vulkan")

# Audio de session pour le partage LAN : capture du monitor PipeWire du sink
# par défaut (thread) + encodage/décodage OPUS.
env.ParseConfig("pkg-config --cflags --libs libpipewire-0.3 libspa-0.2 opus")

# Vidéo pour le partage LAN : encodeur inter-frame (remplacement du JPEG par
# frame). FFmpeg (libavcodec/libavutil/libswscale) pour l'encodage/décodage
# H.264/AV1, libva pour l'accélération matérielle VAAPI (radeonsi). Le
# fallback logiciel (libx264) est fourni par libavcodec lui-même.
env.ParseConfig("pkg-config --cflags --libs libavcodec libavutil libswscale libva")

# X11 (Xlib) pour le partage audio des fenêtres X11 (xwayland) : le vrai PID
# d'une app X11 est lu via la propriété EWMH _NET_WM_PID sur le serveur X du
# satellite (xwayland-satellite), puis matché contre les nodes PipeWire.
env.ParseConfig("pkg-config --cflags --libs x11")

# dbus-1 pour le daemon de notification (optionnel)
if subprocess.call(["pkg-config", "--exists", "dbus-1"]) == 0:
    env.ParseConfig("pkg-config --cflags --libs dbus-1")
    env.Append(CPPDEFINES=["HAVE_DBUS"])
else:
    print("WARNING: dbus-1 not found — notification daemon disabled")

# wlroots 0.19 masque son API derrière cette macro tant qu'elle n'est pas
# stabilisée - sans elle, tous ses headers refusent de compiler.
env.Append(CPPDEFINES=["WLR_USE_UNSTABLE"])

# xdg-shell-protocol.h/.c ne sont pas fournis par wlroots: ils doivent être
# générés à partir du XML de wayland-protocols via wayland-scanner. Adapter
# le chemin si votre distro l'installe ailleurs
# (`pkg-config --variable=pkgdatadir wayland-protocols` donne le bon chemin).
xdg_shell_xml = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"

xdg_shell_header = env.Command(
    "compositors/protocols/xdg-shell-protocol.h",
    xdg_shell_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)
xdg_shell_source = env.Command(
    "compositors/protocols/xdg-shell-protocol.c",
    xdg_shell_xml,
    "wayland-scanner private-code $SOURCE $TARGET",
)

env.Append(CPPPATH=["compositors/protocols/"])
sources += [xdg_shell_source]
# Force la génération du header avant toute compilation qui l'inclut
# (wlr_compositor.h dépend indirectement de xdg-shell-protocol.h).
env.Depends(sources, xdg_shell_header)

# wlr-layer-shell-unstable-v1: protocole wlroots (pas dans wayland-protocols).
# Le XML est versionné dans protocols/ car il n'est pas installé sur toutes
# les distros; seul le header serveur est nécessaire (wlroots fournit déjà
# l'implémentation côté serveur via wlr_layer_shell_v1_create).
layer_shell_xml = "compositors/protocols/wlr-layer-shell-unstable-v1.xml"
layer_shell_header = env.Command(
    "compositors/protocols/wlr-layer-shell-unstable-v1-protocol.h",
    layer_shell_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)
env.Depends(sources, layer_shell_header)

# Protocoles instables: pointer-constraints-v1 + relative-pointer-v1
pointer_constraints_xml = "/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml"
pointer_constraints_header = env.Command(
    "compositors/protocols/pointer-constraints-unstable-v1-protocol.h",
    pointer_constraints_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)

relative_pointer_xml = "/usr/share/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml"
relative_pointer_header = env.Command(
    "compositors/protocols/relative-pointer-unstable-v1-protocol.h",
    relative_pointer_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)

env.Depends(sources, pointer_constraints_header)
env.Depends(sources, relative_pointer_header)

# ext-image-copy-capture-v1 + ext-image-capture-source-v1 (staging): requis
# par xdg-desktop-portal-wlr pour la capture écran (output) et fenêtre
# (foreign toplevel). Le header serveur est généré depuis le staging de
# wayland-protocols ; l'implémentation des sessions/frames est fournie par
# wlroots (wlr_ext_image_copy_capture_manager_v1_create +
# wlr_ext_output_image_capture_source_manager_v1_create). Seul le manager
# "foreign toplevel" n'existe pas encore dans wlroots 0.19 : son interface
# wire est définie dans ext_foreign_toplevel_image_capture_source.c.
ext_image_copy_capture_xml = "/usr/share/wayland-protocols/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml"
ext_image_copy_capture_header = env.Command(
    "compositors/protocols/ext-image-copy-capture-v1-protocol.h",
    ext_image_copy_capture_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)

ext_image_capture_source_xml = "/usr/share/wayland-protocols/staging/ext-image-capture-source/ext-image-capture-source-v1.xml"
ext_image_capture_source_header = env.Command(
    "compositors/protocols/ext-image-capture-source-v1-protocol.h",
    ext_image_capture_source_xml,
    "wayland-scanner server-header $SOURCE $TARGET",
)

env.Depends(sources, ext_image_copy_capture_header)
env.Depends(sources, ext_image_capture_source_header)

if env["platform"] == "macos":
    library = env.SharedLibrary(
        "Game/source/bin/libwaylandgodot.{}.{}.framework/libwaylandgodot.{}.{}".format(
            env["platform"], env["target"], env["platform"], env["target"]
        ),
        source=sources,
    )
else:
    library = env.SharedLibrary(
        "Game/source/bin/libwaylandgodot{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
        source=sources,
    )

Default(library)
