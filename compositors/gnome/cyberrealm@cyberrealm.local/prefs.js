/*
 * CyberRealm — préférences de l'extension GNOME Shell
 *
 * Fenêtre de préférences compatible GNOME 45-50. Adw (libadwaita) est présent
 * sur toute la plage visée (libadwaita est obligatoire depuis GNOME 42), donc
 * un simple Adw.PreferencesGroup + Adw.SwitchRow suffit et est la voie la plus
 * robuste entre 45 et 50.
 */

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import {ExtensionPreferences} from 'resource:///org/gnome/shell/extensions/prefs.js';

export default class CyberRealmPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();

        const group = new Adw.PreferencesGroup({
            title: 'Launch',
            description: 'Behavior when the CyberRealm game window appears.',
        });

        const fullscreenRow = new Adw.SwitchRow({
            title: 'Fullscreen on launch',
            subtitle: 'Show the game window fullscreen and focused when it appears.',
        });
        group.add(fullscreenRow);

        window.add(group);

        // Liaison bidirectionnelle settings <-> switch.
        settings.bind('fullscreen-on-launch', fullscreenRow, 'active',
            Gio.SettingsBindFlags.DEFAULT);

        // Empêche la ligne d'être garbage collectée avant la fin de la fenêtre.
        window._cyberrealmSettings = settings;
        window._cyberrealmGroup = group;
        window._cyberrealmFullscreenRow = fullscreenRow;
    }
}
