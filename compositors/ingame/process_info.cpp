// Informations de processus pour la reprise de session (window_layouts.gd) :
// comment relancer l'application qui possède une fenêtre.

#include "wlr_compositor.h"

#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <climits>

using namespace godot;

static std::string read_link(const std::string &path) {
    char buf[PATH_MAX];
    ssize_t n = readlink(path.c_str(), buf, sizeof(buf) - 1);
    if (n <= 0) {
        return std::string();
    }
    buf[n] = '\0';
    return std::string(buf);
}

// Nom de l'application Flatpak (clé « name » de la section [Application] de
// /.flatpak-info, vu depuis la racine du processus), "" hors Flatpak.
static std::string flatpak_app_id(pid_t pid) {
    std::ifstream f("/proc/" + std::to_string((long)pid) + "/root/.flatpak-info");
    if (!f.is_open()) {
        return std::string();
    }
    std::string line;
    bool in_app = false;
    while (std::getline(f, line)) {
        if (!line.empty() && line[0] == '[') {
            in_app = (line == "[Application]");
            continue;
        }
        if (in_app && line.rfind("name=", 0) == 0) {
            return line.substr(5);
        }
    }
    return std::string();
}

Dictionary WlrCompositor::get_process_info(int pid) {
    Dictionary info;
    if (pid <= 0) {
        return info;
    }
    std::string base = "/proc/" + std::to_string(pid);
    std::ifstream f(base + "/cmdline", std::ios::binary);
    if (!f.is_open()) {
        return info;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    std::string raw = ss.str();
    PackedStringArray argv;
    size_t start = 0;
    while (start < raw.size()) {
        size_t end = raw.find('\0', start);
        if (end == std::string::npos) {
            end = raw.size();
        }
        argv.push_back(String::utf8(raw.substr(start, end - start).c_str()));
        start = end + 1;
    }
    if (argv.is_empty()) {
        return info; // processus noyau ou zombie
    }
    std::string comm;
    std::ifstream fc(base + "/comm");
    if (fc.is_open()) {
        std::getline(fc, comm);
    }
    info["argv"] = argv;
    info["cwd"] = String::utf8(read_link(base + "/cwd").c_str());
    info["exe"] = String::utf8(read_link(base + "/exe").c_str());
    info["comm"] = String::utf8(comm.c_str());
    info["flatpak_id"] = String::utf8(flatpak_app_id((pid_t)pid).c_str());
    return info;
}
