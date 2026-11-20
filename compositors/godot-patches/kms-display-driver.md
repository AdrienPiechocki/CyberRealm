# Godot DisplayServer `kms` (WIP)

Patch : `kms-display-driver.patch` (sur Godot 4.7.2, `git apply`).
Build : `scons platform=linuxbsd kms=yes ...` (libseat, libdrm, libinput, libudev requis ; Vulkan obligatoire).
Lancement : `--display-driver kms` depuis un VT (session logind/seatd).

État (testé sur Radeon 780M + RX 7600M XT, RADV, 1920x1080@60, depuis un TTY) :
- libseat + surface Vulkan VK_EXT_acquire_drm_display / VK_KHR_display : OK, le jeu s'affiche et tourne.
- Entrées (kms_input) : libinput + xkbcommon, clavier/souris OK. Touches mortes/Compose via xkb_compose (table de la locale LC_ALL/LC_CTYPE/LANG), pas de tactile.
- Curseur : logiciel, côté jeu (Game/source/scripts/kms_cursor.gd), visible en MOUSE_MODE_VISIBLE.
- Changement de VT : NON SUPPORTÉ. Le raccourci Ctrl+Alt+Fn (libseat_switch_session) a été retiré :
  l'aller (F2) marche, mais au retour le jeu se bloque et les écrans gèlent (reboot nécessaire). La
  ré-acquisition de l'écran (_seat_enable) est donc suspecte ; ne pas réactiver sans filet (ssh).
  Avec le clavier en K_OFF, ni Ctrl+C ni Ctrl+Alt+Fn ne marchent : sortir par le menu pause du jeu.
- TODO : multi-écrans, compose, branchement dans install.sh (option --with-kms ; build avec
  `kms=yes disable_path_overrides=no` pour lancer depuis les sources).

Choix de la sortie : par défaut la dalle interne (eDP/LVDS/DSI, supposée écran principal), sinon le premier connecteur connecté. Variable
`CYBERREALM_KMS_OUTPUT` (ex. `DP-1`, `eDP-2`) pour forcer une sortie ; en session, la mettre dans
`~/.config/cyberrealm/kms.env`. Le GPU est imposé par `device_supports_present` : seul le GPU
propriétaire de l'écran est éligible (machine hybride : sinon Godot choisit le dGPU et la swapchain
échoue en VK_ERROR_INITIALIZATION_FAILED, écran figé).

Fin de session : le wrapper `cyberrealm-kms-session` (généré par install.sh) ne fait plus `exec` : à la
sortie du jeu il appelle `loginctl terminate-session $XDG_SESSION_ID` pour ramener au gestionnaire de connexion.

Mode d'affichage : par défaut le plus grand mode de l'écran. `CYBERREALM_KMS_MODE=1920x1080` (ou `@60`)
le force ; si le mode n'existe pas, repli sur le meilleur (avertissement). Les fenêtres clientes du
compositeur embarqué ne sont pas rééchelonnées : sur un écran plus dense (ex. eDP 2560x1440 au lieu de
1920x1080 sous KDE) leur texte paraît plus flou.

Retour au greeter plasmalogin : le kwin_wayland du greeter (kwin 6.8.3) peut segfaulter au démarrage si la
souris bouge (InputRedirection::syncTabletWithMouse) — bug KDE, pas du driver. Le wrapper attend
`CYBERREALM_KMS_LOGOUT_DELAY` secondes (3 par défaut) avant `loginctl terminate-session`.

Disposition clavier : variables XKB_DEFAULT_* si présentes, sinon /etc/vconsole.conf (XKBLAYOUT, XKBVARIANT,
XKBMODEL, XKBOPTIONS, écrits par localectl), sinon "us". IMPORTANT : le jeu remappe unicode '<'/'>' vers la
touche ISO (KEY_LESS) ; avec un keymap Godot en "us" au lieu de "fr", Shift+';' et Shift+':' (AZERTY) donnent
'<'/'>' et la touche reste coincée côté client. Le keymap du driver doit donc suivre celui du système.

## Watchdog et changement de VT (opt-in)

- `kms_watchdog` : thread dédié qui surveille le battement de `process_events()`. S'il s'arrête plus de
  5 s (CYBERREALM_KMS_WATCHDOG_TIMEOUT) dans les 30 s qui suivent un retour de VT, il journalise
  (stderr + `~/.local/state/cyberrealm/kms-session.log`) puis `_exit(70)` : le noyau ferme les fds
  DRM et rend l'écran. `CYBERREALM_KMS_WATCHDOG=always` l'arme en permanence (10 s), `off` le désactive.
- Ctrl+Alt+F1..F12 : ignoré par défaut ; `CYBERREALM_KMS_VT_SWITCH=1` déclenche `libseat_switch_session`.
  Jamais transmis au jeu. À tester avec un accès ssh de secours : la libération effective de l'écran par
  `_exit` n'est PAS encore vérifiée sur matériel.
