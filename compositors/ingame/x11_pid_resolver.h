#ifndef X11_PID_RESOLVER_H
#define X11_PID_RESOLVER_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Résolution du vrai PID d'une application X11 pour le partage audio LAN.
//
// Contexte : les fenêtres X11 d'une session du jeu sont exposées au
// compositeur via UN SEUL client Wayland (xwayland-satellite). Le PID que le
// compositeur lit sur ce client (wl_client_get_credentials) est donc le PID
// du satellite, pas celui de l'application. Or le partage audio capture par
// PID (matching contre application.process.id des nodes PipeWire), et chaque
// app X11 est elle-même un client PipeWire (client natif ou via
// pipewire-pulse) avec son propre PID → aucun node ne matche → pas d'audio.
//
// Ce module retrouve le vrai PID d'une fenêtre X11 en interrogeant le serveur
// X du satellite (display configuré via set_display, ex. ":1") :
//   1. énumération des fenêtres de premier niveau (_NET_CLIENT_LIST EWMH,
//      fallback parcours d'arbre + filtre WM_STATE) ;
//   2. lecture de _NET_WM_PID (EWMH/ICCCM), _NET_WM_NAME/WM_NAME (titre) et
//      WM_CLASS (instance + classe) par fenêtre.
// La correspondance fenêtre-compositeur → app se fait sur (titre, classe),
// le snapshot étant publié sous mutex pour les consommateurs du thread du jeu.
//
// Le travail X11 (XOpenDisplay + requêtes, qui peuvent prendre quelques ms)
// tourne sur un thread dédié : la boucle wlroots n'est jamais bloquée. Le
// thread dort sur une condition variable et se réveille à la demande
// (request_refresh) ou périodiquement via le throttling interne de resolve().
//
// Note Xauth : xwayland-satellite lance Xwayland sans -auth (accès local
// +SI:localuser:$USER), un client X11 du même utilisateur peut donc se
// connecter sans cookie. Si un jour le satellite est lancé avec -auth,
// XOpenDisplay héritera de l'environnement XAUTHORITY du jeu.

// Forward declaration opaque du type Xlib (évite d'exposer les headers X11).
struct _XDisplay;

namespace godot {

// Une fenêtre X11 énumérée, avec les propriétés utiles au matching.
struct X11WindowInfo {
	std::string title;          // _NET_WM_NAME / WM_NAME, en minuscules
	std::string class_instance; // WM_CLASS partie instance, en minuscules
	std::string class_class;    // WM_CLASS partie classe, en minuscules
	int pid = -1;               // _NET_WM_PID (CARDINAL)
};

class X11PidResolver {
public:
	X11PidResolver();
	~X11PidResolver();

	// Nom du display X11 à interroger (ex. ":1"). À appeler avant start().
	void set_display(const std::string &display_name);

	// Démarre le thread de résolution et déclenche un premier refresh.
	void start();
	void stop();
	bool is_running() const;

	// Demande un refresh asynchrone (nouvelle fenêtre mappée, titre changé,
	// fenêtre fermée...). Ne bloque jamais l'appelant.
	void request_refresh();

	// PID de l'application X11 correspondant à (app_id, titre) vus côté
	// compositeur (xwayland-satellite expose l'app_id=WM_CLASS et le titre X11
	// via xdg-toplevel). Retourne -1 si inconnu. Rafraîchit périodiquement
	// (au plus toutes les 2 s) pour suivre les ouvertures/fermetures sans
	// que l'appelant ait à s'en soucier.
	int resolve(const std::string &app_id, const std::string &title);

private:
	void worker_loop();
	void rebuild();

	// Matching du snapshot (à appeler snapshot_mutex détenu).
	int match_locked(const std::string &app_id, const std::string &title) const;

	static uint64_t current_time_ms();

	// Display configuré (lu au start / au premier rebuild).
	std::string display_name;
	int display_num = -1;

	// Thread de résolution X11.
	std::thread worker;
	std::mutex wake_mutex;
	std::condition_variable wake_cv;
	bool refresh_requested = false;
	bool stop_requested = false;

	// Snapshot publié (écrit par le thread worker, lu par le thread du jeu).
	mutable std::mutex snapshot_mutex;
	std::vector<X11WindowInfo> windows;

	// Throttling du refresh déclenché depuis resolve() (thread-safe via
	// atomic : un éventuel double déclenchement est bénin).
	static constexpr uint64_t REFRESH_INTERVAL_MS = 2000;
	std::atomic<uint64_t> next_refresh_ms{0};
};

} // namespace godot

#endif
