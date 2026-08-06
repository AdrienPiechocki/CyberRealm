/*
 * CyberRealm KWin script
 *
 * Quand la fenêtre du jeu (CyberRealm) est présente :
 *  - elle est passée en plein écran sans décoration et focalisée ;
 *  - tant qu'elle détient le focus, TOUS les raccourcis globaux KDE sont
 *    bloqués (kglobalaccel -> blockGlobalShortcuts) pour qu'aucun combo
 *    Plasma (Super, Alt+Tab, capture d'écran...) n'interfère pendant la
 *    partie.
 * Dès que le jeu perd le focus ou se ferme, les raccourcis sont restaurés.
 *
 * Robustesse : l'état du blocage n'est jamais mémorisé pour éviter les appels
 * D-Bus. À chaque événement (ouverture/fermeture de fenêtre, changement de
 * focus, et périodiquement toutes les 2 s si setTimeout est dispo), on
 * re-envoie l'état voulu calculé depuis le terrain (fenêtre du jeu présente
 * ET active). Un appel échoué ne peut donc pas laisser les raccourcis
 * bloqués définitivement : le prochain événement ou la boucle de sécurité
 * le corrige.
 *
 * Le lancement d'applications se fait depuis le jeu lui-même (binds custom) :
 * plus aucun transfert de fenêtres Plasma vers le compositeur du jeu.
 */

var CYBERREALM_RE = /cyberrealm/i;
var FULLSCREEN_ON_LAUNCH = readConfig("fullscreenOnLaunch", true);

var gameInternalId = null; // internalId de la fenêtre du jeu tant qu'elle tourne
var shortcutsBlocked = false; // dernier état effectivement appliqué (log seul)

function isGameWindow(win) {
    if (!win || win.deleted) {
        return false;
    }
    // Match UNIQUEMENT sur resourceClass/resourceName (pas le caption : un
    // titre peut contenir "CyberRealm" sans être le jeu, ex. un terminal
    // opencode nommé "CyberRealm : opencode").
    return CYBERREALM_RE.test(String(win.resourceClass || "")) ||
           CYBERREALM_RE.test(String(win.resourceName || ""));
}

function allWindows() {
    var list = null;
    try {
        if (typeof workspace.stackingOrder === "function") {
            list = workspace.stackingOrder();
        } else if (Array.isArray(workspace.stackingOrder)) {
            list = workspace.stackingOrder;
        }
    } catch (e) { list = null; }
    if (list) return list;
    try {
        if (typeof workspace.windowList === "function") {
            list = workspace.windowList();
        } else if (Array.isArray(workspace.windowList)) {
            list = workspace.windowList;
        }
    } catch (e) { list = null; }
    if (list) return list;
    try {
        if (typeof workspace.clientList === "function") {
            list = workspace.clientList();
        } else if (Array.isArray(workspace.clientList)) {
            list = workspace.clientList;
        }
    } catch (e) { list = null; }
    if (list) return list;
    return [];
}

// L'état voulu découle UNIQUEMENT du terrain : jeu présent ET actif.
function shouldBlockShortcuts() {
    if (gameInternalId === null) {
        return false;
    }
    var active = workspace.activeWindow;
    return !!active && active.internalId === gameInternalId;
}

// PAS de garde de cache : on re-envoie toujours, c'est le filet qui empêche
// un état bloqué de survivre à un appel D-Bus qui aurait échoué.
function applyShortcutsBlocked(block) {
    try {
        callDBus("org.kde.kglobalaccel", "/kglobalaccel",
                 "org.kde.KGlobalAccel", "blockGlobalShortcuts", block);
        if (block !== shortcutsBlocked) {
            shortcutsBlocked = block;
            print("[cyberrealm] blockGlobalShortcuts -> " + block);
        }
    } catch (e) {
        print("[cyberrealm] blockGlobalShortcuts(" + block + ") FAILED: " + e);
    }
}

function syncShortcuts() {
    applyShortcutsBlocked(shouldBlockShortcuts());
}

function focusGameWindow(win) {
    if (FULLSCREEN_ON_LAUNCH) {
        win.fullScreen = true;
        win.noBorder = true;
    }
    workspace.activeWindow = win;
}

function onGameStart(win) {
    if (gameInternalId !== null && gameInternalId !== win.internalId) {
        focusGameWindow(win); // deuxième fenêtre du jeu (inattendu)
        return;
    }
    gameInternalId = win.internalId;
    focusGameWindow(win);
    syncShortcuts();
}

function onGameStop() {
    gameInternalId = null;
    syncShortcuts();
}

function onWindowAdded(win) {
    if (isGameWindow(win)) {
        onGameStart(win);
        return;
    }
    syncShortcuts();
}

function onWindowRemoved(win) {
    // isGameWindow() échoue sur une fenêtre déjà supprimée (win.deleted=true) :
    // on compare directement l'identifiant de la fenêtre du jeu.
    if (win && win.internalId === gameInternalId) {
        onGameStop();
        return;
    }
    syncShortcuts();
}

function onActiveWindowChanged() {
    syncShortcuts();
}

// KWin 6 : windowAdded/windowRemoved ; KWin 5 : clientAdded/clientRemoved.
if (workspace.windowAdded) {
    workspace.windowAdded.connect(onWindowAdded);
} else if (workspace.clientAdded) {
    workspace.clientAdded.connect(onWindowAdded);
}
if (workspace.windowRemoved) {
    workspace.windowRemoved.connect(onWindowRemoved);
} else if (workspace.clientRemoved) {
    workspace.clientRemoved.connect(onWindowRemoved);
}
if (workspace.activeWindowChanged) {
    workspace.activeWindowChanged.connect(onActiveWindowChanged);
}
if (workspace.windowActivated) {
    workspace.windowActivated.connect(onActiveWindowChanged);
}
if (workspace.currentDesktopChanged) {
    workspace.currentDesktopChanged.connect(syncShortcuts);
}

// État déjà présent au chargement (reconfigure du script) : on reprend le jeu
// en cours ; sinon on force le déblocage (corrige un blocage résiduel).
var existing = allWindows();
var gameRunning = false;
for (var i = 0; i < existing.length; i++) {
    if (existing[i] && isGameWindow(existing[i])) {
        onGameStart(existing[i]);
        gameRunning = true;
        break;
    }
}
if (!gameRunning) {
    syncShortcuts();
}

print("[cyberrealm] script loaded, setTimeout=" + (typeof setTimeout === "function"));

// Filet de sécurité : re-synchronise toutes les 2 s.
if (typeof setTimeout === "function") {
    function sweep() {
        syncShortcuts();
        setTimeout(sweep, 2000);
    }
    setTimeout(sweep, 2000);
}
