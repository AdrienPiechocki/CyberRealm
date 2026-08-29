/*
 * CyberRealm — extension GNOME Shell
 *
 * Sur KDE, l'intégration KWin (cyberrealm.kwinscript) gère le plein écran, le
 * focus ET le blocage des raccourcis globaux via kglobalaccel. Sur GNOME, le
 * blocage des raccourcis est IMPOSSIBLE depuis une extension (pas d'équivalent
 * à kglobalaccel) : c'est le JEU lui-même qui lie zwp_keyboard_shortcuts_inhibit_v1
 * (driver Godot patché) pour bloquer les raccourcis quand SA fenêtre a le focus.
 *
 * Cette extension ne s'occupe donc que de :
 *   - détecter la fenêtre du jeu (palier wm_class OU wm_class_instance) ;
 *   - la passer en plein écran dès son apparition (configurable) et la focaliser ;
 *   - re-synchroniser de manière idempotente (balayage sécurité + signaux
 *     d'événements) pour que l'état du plein écran reste cohérent.
 *
 * Robustesse type-KWin : aucun état mémorisé qui cacherait un échec. À chaque
 * événement et au balayage, on RE-APPLIQUE (plein écran idempotent) l'état
 * calculé depuis le terrain (fenêtre du jeu présente). Chaque handler est
 * enveloppé de try/catch pour qu'une absence de signal sur une version donnée
 * ne casse pas l'extension. Le balayage 2 s est le filet : même si un signal
 * manque, la détection finit par se faire.
 *
 * NB : sur GNOME, quand la fenêtre du jeu se ferme, le focus passe
 * automatiquement à une autre fenêtre — l'extension ne fait rien à ce moment-là
 * (le protocole Wayland du jeu désinhibe automatiquement quand sa surface perd
 * le focus).
 */

import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// Détection du jeu : on matche UNIQUEMENT sur wm_class / wm_class_instance, pas
// sur le titre (un titre peut contenir "CyberRealm" sans être le jeu).
const CYBERREALM_RE = /cyberrealm/i;

export default class CyberRealmExtension extends Extension {
    enable() {
        // Réglage qui pilote la mise en plein écran au lancement.
        this._settings = this.getSettings();
        this._fullscreenOnLaunch = this._settings.get_boolean('fullscreen-on-launch');

        // Garde la fenêtre du jeu courante tant qu'elle tourne.
        this._gameWindow = null;
        // Identifiant de connexion ("unmanaged") posé sur la fenêtre du jeu.
        this._gameWindowUnmanagedId = 0;

        // Signaux de création/suppression de fenêtres.
        this._windowCreatedId = 0;

        // Balayage périodique de sécurité.
        this._sweepId = 0;

        const display = global.display;

        // Signal de création de fenêtre. En GNOME 45-50, global.display est un
        // Meta.Display qui émet 'window-created' (avec la MetaWindow en arg).
        // Les signaux GObject ne sont pas des propriétés JS : on ne peut pas
        // les détecter par `typeof display['window-created']`. On connecte en
        // try/catch : si le signal n'existe pas sur une version, connect()
        // lève et le balayage 2 s reste le filet.
        try {
            this._windowCreatedId = display.connect(
                'window-created',
                (_dsp, win) => this._onWindowCreated(win));
        } catch (e) {
            this._windowCreatedId = 0;
        }

        // Reprend une fenêtre du jeu déjà présente (reconfigure).
        this._sweep();

        // Filet de sécurité : re-synchronisation toutes les 2 s.
        this._sweepId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2,
            () => {
                this._sweep();
                return GLib.SOURCE_CONTINUE;
            });
    }

    disable() {
        if (this._sweepId) {
            GLib.source_remove(this._sweepId);
            this._sweepId = 0;
        }

        const display = global.display;
        if (this._windowCreatedId && display) {
            display.disconnect(this._windowCreatedId);
            this._windowCreatedId = 0;
        }

        // Détache le handler "unmanaged" de la fenêtre du jeu.
        if (this._gameWindow && this._gameWindowUnmanagedId) {
            try {
                this._gameWindow.disconnect(this._gameWindowUnmanagedId);
            } catch (e) {
                // La fenêtre peut déjà être détruite : on ignore.
            }
        }
        this._gameWindowUnmanagedId = 0;
        this._gameWindow = null;

        this._settings = null;
    }

    // Vrai si la fenêtre est (ou a été) une fenêtre du jeu.
    isGameWindow(w) {
        if (!w) {
            return false;
        }
        return CYBERREALM_RE.test(String(w.get_wm_class() || '')) ||
               CYBERREALM_RE.test(String(w.get_wm_class_instance() || ''));
    }

    // Applique l'état voulu au plein écran de la fenêtre du jeu (idempotent).
    _applyState(win) {
        try {
            if (this._fullscreenOnLaunch && typeof win.make_fullscreen === 'function') {
                win.make_fullscreen();
            }
            if (typeof win.activate === 'function') {
                win.activate(global.get_current_time());
            }
        } catch (e) {
            // Une méthode manquante ou une fenêtre en cours de destruction ne
            // doit pas casser l'extension : on ignore ici, le balayage repassera.
        }
    }

    // Fenêtre du jeu qui apparaît : on la met en plein écran et on la focalise.
    // Parité KWin : si une seconde fenêtre du jeu arrive pendant que la première
    // est suivie, on l'active/fullscreen aussi.
    _onWindowCreated(win) {
        try {
            if (!this.isGameWindow(win)) {
                return;
            }
            this._trackGameWindow(win);
        } catch (e) {
            // Handler protégé : une absence de signal ne doit rien casser.
        }
    }

    // Mémorise la fenêtre du jeu et lui applique le plein écran + focus.
    _trackGameWindow(win) {
        if (this._gameWindow !== win) {
            this._untrackGameWindow();
            this._gameWindow = win;

            console.log('cyberrealm: tracking game window, fullscreen =',
                this._fullscreenOnLaunch);

            // Quand la fenêtre du jeu disparaît, on cesse de la suivre et on
            // oublie tout (le jeu gère la suite via le protocole Wayland).
            if (typeof win.connect === 'function') {
                try {
                    this._gameWindowUnmanagedId = win.connect(
                        'unmanaged', () => this._untrackGameWindow());
                } catch (e) {
                    this._gameWindowUnmanagedId = 0;
                }
            }
        }
        this._applyState(win);
    }

    // Oublie la fenêtre du jeu courante (détache le handler si besoin).
    _untrackGameWindow() {
        if (this._gameWindow && this._gameWindowUnmanagedId) {
            try {
                this._gameWindow.disconnect(this._gameWindowUnmanagedId);
            } catch (e) {
                // Fenêtre déjà détruite : on ignore.
            }
        }
        this._gameWindowUnmanagedId = 0;
        this._gameWindow = null;
    }

    // Énumère les fenêtres visibles. Plusieurs sources sont essayées (selon les
    // versions du Shell, global.get_window_actors(), le workspace manager ou
    // global.get_windows() existent ou non). Chaque source est protégée : une
    // absence laisse simplement la liste vide, le balayage suivant réessaiera.
    _getWindows() {
        const out = [];
        try {
            const actors = global.get_window_actors();
            if (actors) {
                for (let i = 0; i < actors.length; i++) {
                    if (actors[i].meta_window) {
                        out.push(actors[i].meta_window);
                    }
                }
            }
        } catch (e) {
            // Autre source ci-dessous.
        }
        if (out.length === 0) {
            try {
                const workspaces = global.get_workspace_manager().get_workspaces();
                for (let i = 0; i < workspaces.length; i++) {
                    out.push(...workspaces[i].list_windows());
                }
            } catch (e) {
                out.length = 0;
                try {
                    out.push(...global.get_windows());
                } catch (e2) {
                    // Plus aucune source : balayage vide.
                }
            }
        }
        return out;
    }

    // Balayage de sécurité : cherche la fenêtre du jeu et re-applique l'état.
    // Ré-appliquer un plein écran déjà actif est sans effet (idempotent) et
    // corrige un état incohérent (crash/reconfigure).
    _sweep() {
        try {
            if (this._gameWindow && this.isGameWindow(this._gameWindow)) {
                // Reprise : on re-applique l'état à la fenêtre suivie.
                this._applyState(this._gameWindow);
                return;
            }

            // Sinon on cherche une fenêtre du jeu parmi les fenêtres existantes.
            const windows = this._getWindows();
            for (let i = 0; i < windows.length; i++) {
                if (windows[i] && this.isGameWindow(windows[i])) {
                    this._trackGameWindow(windows[i]);
                    break;
                }
            }
        } catch (e) {
            // Le balayage est un filet : ne remonte jamais une erreur.
        }
    }
}
