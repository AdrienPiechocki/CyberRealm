#include "x11_pid_resolver.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>

#include <cerrno>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

// Aide au débogage : la résolution X11 est périphérique, on ne veut pas
// dépendre de Godot ici (le thread worker tourne hors de la boucle du jeu).
namespace {

// Extrait le numéro de display d'un nom du type ":1", ":1.0", "unix:1".
int display_number_from_name(const std::string &name) {
	size_t pos = name.rfind(':');
	if (pos == std::string::npos) {
		return -1;
	}
	int num = 0;
	bool any = false;
	for (size_t i = pos + 1; i < name.size(); i++) {
		if (name[i] >= '0' && name[i] <= '9') {
			num = num * 10 + (name[i] - '0');
			any = true;
		} else {
			break;
		}
	}
	return any ? num : -1;
}

// Vérifie rapidement (avec timeout) que le socket X11 du satellite est prêt.
// Évite que XOpenDisplay bloque des secondes quand le satellite n'est pas
// encore lancé (ou est déjà arrêté).
bool x11_socket_ready(int display_num) {
	if (display_num < 0) {
		return false;
	}
	const std::string path = "/tmp/.X11-unix/X" + std::to_string(display_num);
	// Socket fichier classique.
	struct stat st;
	if (stat(path.c_str(), &st) == 0 && S_ISSOCK(st.st_mode)) {
		return true;
	}
	// Socket abstrait (@/tmp/.X11-unix/X<n>) : tentative de connexion
	// non-bloquante avec timeout court.
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		return false;
	}
	struct sockaddr_un addr;
	std::memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	addr.sun_path[0] = '\0';
	std::memcpy(addr.sun_path + 1, path.c_str(), path.size());
	int flags = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, flags | O_NONBLOCK);
	int rc = connect(fd, reinterpret_cast<struct sockaddr *>(&addr),
			offsetof(struct sockaddr_un, sun_path) + 1 + path.size());
	if (rc == 0) {
		close(fd);
		return true;
	}
	bool ok = false;
	if (errno == EINPROGRESS) {
		struct pollfd pfd = { fd, POLLOUT, 0 };
		int pr = poll(&pfd, 1, 200);
		ok = pr > 0;
	}
	close(fd);
	return ok;
}

std::string lowercase(std::string s) {
	for (char &c : s) {
		c = (char)std::tolower((unsigned char)c);
	}
	return s;
}

// Lit une propriété texte (STRINGS/UTF8_STRING). Retourne vide si absente.
std::string read_string_prop(::Display *dpy, Window win, ::Atom prop_atom) {
	::Atom actual_type = None;
	int actual_format = 0;
	unsigned long nitems = 0;
	unsigned long bytes_after = 0;
	unsigned char *prop = nullptr;
	if (XGetWindowProperty(dpy, win, prop_atom, 0, ~0L, False, AnyPropertyType,
			&actual_type, &actual_format, &nitems, &bytes_after, &prop) == Success
			&& prop && nitems > 0) {
		std::string s(reinterpret_cast<const char *>(prop), nitems);
		XFree(prop);
		// Tronque au premier NUL (WM_CLASS contient deux chaînes séparées).
		size_t nul = s.find('\0');
		return nul == std::string::npos ? s : s.substr(0, nul);
	}
	if (prop) {
		XFree(prop);
	}
	return "";
}

int read_pid_prop(::Display *dpy, Window win, ::Atom pid_atom) {
	if (pid_atom == None) {
		return -1;
	}
	::Atom actual_type = None;
	int actual_format = 0;
	unsigned long nitems = 0;
	unsigned long bytes_after = 0;
	unsigned char *prop = nullptr;
	if (XGetWindowProperty(dpy, win, pid_atom, 0, 1, False, AnyPropertyType,
			&actual_type, &actual_format, &nitems, &bytes_after, &prop) != Success
			|| !prop || nitems < 1) {
		if (prop) {
			XFree(prop);
		}
		return -1;
	}
	int pid = -1;
	// _NET_WM_PID est CARDINAL (32 bits), mais on accepte les autres formats.
	if (actual_format == 32) {
		pid = (int)static_cast<long>(*reinterpret_cast<long *>(prop));
	} else if (actual_format == 16) {
		pid = *reinterpret_cast<short *>(prop);
	} else if (actual_format == 8) {
		pid = *prop;
	}
	XFree(prop);
	return pid;
}

// Parcours d'arbre : collectionne les fenêtres possédant WM_STATE (les
// toplevels, selon ICCCM). Fallback quand _NET_CLIENT_LIST est absent.
void walk_tree(::Display *dpy, Window w, ::Atom wm_state, std::vector<Window> &out) {
	Window root = None;
	Window parent = None;
	Window *children = nullptr;
	unsigned int nchildren = 0;
	if (!XQueryTree(dpy, w, &root, &parent, &children, &nchildren)) {
		if (children) {
			XFree(children);
		}
		return;
	}
	for (unsigned int i = 0; i < nchildren; i++) {
		Window c = children[i];
		::Atom actual_type = None;
		int actual_format = 0;
		unsigned long nitems = 0;
		unsigned long bytes_after = 0;
		unsigned char *prop = nullptr;
		bool has_state = XGetWindowProperty(dpy, c, wm_state, 0, 1, False,
				AnyPropertyType, &actual_type, &actual_format, &nitems,
				&bytes_after, &prop) == Success && nitems > 0;
		if (prop) {
			XFree(prop);
		}
		if (has_state) {
			out.push_back(c);
		}
		walk_tree(dpy, c, wm_state, out);
	}
	if (children) {
		XFree(children);
	}
}

} // namespace

namespace godot {

X11PidResolver::X11PidResolver() {}

X11PidResolver::~X11PidResolver() {
	stop();
}

void X11PidResolver::set_display(const std::string &display_name) {
	this->display_name = display_name;
	display_num = display_number_from_name(display_name);
}

bool X11PidResolver::is_running() const {
	return worker.joinable();
}

void X11PidResolver::start() {
	if (worker.joinable()) {
		return;
	}
	stop_requested = false;
	refresh_requested = false;
	worker = std::thread(&X11PidResolver::worker_loop, this);
	request_refresh();
}

void X11PidResolver::stop() {
	{
		std::lock_guard<std::mutex> lk(wake_mutex);
		stop_requested = true;
		refresh_requested = true;
	}
	wake_cv.notify_one();
	if (worker.joinable()) {
		worker.join();
	}
	std::lock_guard<std::mutex> lk(snapshot_mutex);
	windows.clear();
}

void X11PidResolver::request_refresh() {
	{
		std::lock_guard<std::mutex> lk(wake_mutex);
		refresh_requested = true;
	}
	wake_cv.notify_one();
}

uint64_t X11PidResolver::current_time_ms() {
	return (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
		std::chrono::steady_clock::now().time_since_epoch()).count();
}

void X11PidResolver::worker_loop() {
	std::unique_lock<std::mutex> lk(wake_mutex);
	while (!stop_requested) {
		wake_cv.wait(lk, [this] {
			return stop_requested || refresh_requested;
		});
		refresh_requested = false;
		if (stop_requested) {
			break;
		}
		lk.unlock();
		rebuild();
		lk.lock();
	}
}

void X11PidResolver::rebuild() {
	if (display_name.empty()) {
		return;
	}
	// Vérifie le socket AVANT XOpenDisplay : évite de bloquer des secondes
	// quand le satellite n'est pas (encore) là.
	if (!x11_socket_ready(display_num)) {
		return;
	}
	::Display *dpy = XOpenDisplay(display_name.empty() ? nullptr : display_name.c_str());
	if (!dpy) {
		fprintf(stderr, "waylandgodot: x11: XOpenDisplay(%s) failed\n",
				display_name.c_str());
		return;
	}

	::Atom net_client_list = XInternAtom(dpy, "_NET_CLIENT_LIST", True);
	::Atom net_wm_pid = XInternAtom(dpy, "_NET_WM_PID", True);
	::Atom net_wm_name = XInternAtom(dpy, "_NET_WM_NAME", True);
	::Atom wm_name = XInternAtom(dpy, "WM_NAME", True);
	::Atom wm_class = XInternAtom(dpy, "WM_CLASS", True);
	::Atom wm_state = XInternAtom(dpy, "WM_STATE", True);

	// 1. Énumération des toplevels (EWMH puis fallback arbre).
	std::vector<Window> wins;
	if (net_client_list != None) {
		::Atom actual_type = None;
		int actual_format = 0;
		unsigned long nitems = 0;
		unsigned long bytes_after = 0;
		unsigned char *prop = nullptr;
		if (XGetWindowProperty(dpy, DefaultRootWindow(dpy), net_client_list, 0,
				~0L, False, XA_WINDOW, &actual_type, &actual_format, &nitems,
				&bytes_after, &prop) == Success && actual_format == 32 && prop) {
			Window *list = reinterpret_cast<Window *>(prop);
			for (unsigned long i = 0; i < nitems; i++) {
				wins.push_back(list[i]);
			}
		}
		if (prop) {
			XFree(prop);
		}
	}
	if (wins.empty()) {
		walk_tree(dpy, DefaultRootWindow(dpy), wm_state, wins);
	}

	// 2. Lecture des propriétés par fenêtre.
	std::vector<X11WindowInfo> fresh;
	fresh.reserve(wins.size());
	for (Window win : wins) {
		X11WindowInfo info;
		info.pid = read_pid_prop(dpy, win, net_wm_pid);
		std::string t = read_string_prop(dpy, win, net_wm_name);
		if (t.empty()) {
			t = read_string_prop(dpy, win, wm_name);
		}
		info.title = lowercase(t);
		if (wm_class != None) {
			::Atom actual_type = None;
			int actual_format = 0;
			unsigned long nitems = 0;
			unsigned long bytes_after = 0;
			unsigned char *prop = nullptr;
			if (XGetWindowProperty(dpy, win, wm_class, 0, ~0L, False,
					AnyPropertyType, &actual_type, &actual_format, &nitems,
					&bytes_after, &prop) == Success && prop && nitems > 0) {
				std::string s(reinterpret_cast<const char *>(prop), nitems);
				XFree(prop);
				size_t nul = s.find('\0');
				if (nul != std::string::npos) {
					info.class_instance = lowercase(s.substr(0, nul));
					info.class_class = lowercase(s.substr(nul + 1));
				} else {
					info.class_instance = lowercase(s);
				}
			} else if (prop) {
				XFree(prop);
			}
		}
		// Sans PID ni titre il n'y a rien de matchable.
		if (info.pid > 0 && !info.title.empty()) {
			fresh.push_back(std::move(info));
		}
	}

	{
		std::lock_guard<std::mutex> lk(snapshot_mutex);
		windows = std::move(fresh);
	}
	XCloseDisplay(dpy);
}

int X11PidResolver::resolve(const std::string &app_id, const std::string &title) {
	// Refresh périodique : suit les ouvertures/fermetures de fenêtres et les
	// changements de titre sans blocage (le travail X11 tourne sur le worker).
	uint64_t now = current_time_ms();
	if (now >= next_refresh_ms.load(std::memory_order_relaxed)) {
		next_refresh_ms.store(now + REFRESH_INTERVAL_MS, std::memory_order_relaxed);
		request_refresh();
	}
	std::lock_guard<std::mutex> lk(snapshot_mutex);
	return match_locked(app_id, title);
}

int X11PidResolver::match_locked(const std::string &app_id, const std::string &title) const {
	const std::string app = lowercase(app_id);
	const std::string t = lowercase(title);
	int fallback_title = -1;
	int fallback_app = -1;
	for (const X11WindowInfo &w : windows) {
		bool app_match = !app.empty()
				&& (w.class_instance == app || w.class_class == app);
		bool title_match = !t.empty() && w.title == t;
		if (title_match) {
			if (app_match) {
				// (titre, classe) : correspondance la plus fiable.
				return w.pid;
			}
			if (fallback_title < 0) {
				fallback_title = w.pid;
			}
		}
		if (app_match && fallback_app < 0) {
			fallback_app = w.pid;
		}
	}
	if (fallback_title >= 0) {
		return fallback_title;
	}
	return fallback_app;
}

} // namespace godot
