// Informations de processus pour la reprise de session (window_layouts.gd) :
// comment relancer l'application qui possède une fenêtre.

#include "wlr_compositor.h"

#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <climits>
#include <dirent.h>
#include <algorithm>
#include <vector>

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

// Champs de /proc/<pid>/stat après le nom (entre parenthèses, peut contenir
// des espaces) : on lit ppid (4e champ) et tpgid (8e, groupe au premier plan
// du terminal de contrôle).
static bool read_stat(pid_t pid, long &ppid, long &tpgid) {
    std::ifstream f("/proc/" + std::to_string((long)pid) + "/stat");
    if (!f.is_open()) {
        return false;
    }
    std::string line;
    std::getline(f, line);
    size_t rp = line.rfind(')');
    if (rp == std::string::npos) {
        return false;
    }
    std::istringstream rest(line.substr(rp + 1));
    std::string state;
    long pgrp = 0, session = 0, tty = 0;
    if (!(rest >> state >> ppid >> pgrp >> session >> tty >> tpgid)) {
        return false;
    }
    return true;
}

static PackedStringArray read_argv(pid_t pid) {
    PackedStringArray argv;
    std::ifstream f("/proc/" + std::to_string((long)pid) + "/cmdline", std::ios::binary);
    if (!f.is_open()) {
        return argv;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    std::string raw = ss.str();
    size_t start = 0;
    while (start < raw.size()) {
        size_t end = raw.find('\0', start);
        if (end == std::string::npos) {
            end = raw.size();
        }
        argv.push_back(String::utf8(raw.substr(start, end - start).c_str()));
        start = end + 1;
    }
    return argv;
}

static std::string read_comm(pid_t pid) {
    std::ifstream f("/proc/" + std::to_string((long)pid) + "/comm");
    std::string comm;
    if (f.is_open()) {
        std::getline(f, comm);
    }
    return comm;
}

Array WlrCompositor::get_terminal_jobs(int pid) {
    static const char *SHELLS[] = {"bash", "zsh", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "elvish", "xonsh", "oil", "osh"};
    Array jobs;
    if (pid <= 0) {
        return jobs;
    }
    DIR *dir = opendir("/proc");
    if (!dir) {
        return jobs;
    }
    std::vector<pid_t> shells;
    dirent *ent;
    while ((ent = readdir(dir)) != nullptr) {
        if (ent->d_name[0] < '0' || ent->d_name[0] > '9') {
            continue;
        }
        pid_t child = (pid_t)atol(ent->d_name);
        long ppid = 0, tpgid = 0;
        if (!read_stat(child, ppid, tpgid) || ppid != pid) {
            continue;
        }
        std::string comm = read_comm(child);
        for (const char *sh : SHELLS) {
            if (comm == sh) {
                shells.push_back(child);
                break;
            }
        }
    }
    closedir(dir);
    std::sort(shells.begin(), shells.end()); // ordre de création ≈ ordre des onglets
    for (pid_t sh : shells) {
        long ppid = 0, tpgid = 0;
        read_stat(sh, ppid, tpgid);
        Dictionary job;
        job["shell_pid"] = (int)sh;
        job["cwd"] = String::utf8(read_link("/proc/" + std::to_string((long)sh) + "/cwd").c_str());
        // Programme au premier plan (cava, vim…) : chef du groupe tpgid, s'il
        // n'est pas le shell lui-même.
        PackedStringArray fg;
        String fg_cwd;
        if (tpgid > 0 && tpgid != sh) {
            fg = read_argv((pid_t)tpgid);
            fg_cwd = String::utf8(read_link("/proc/" + std::to_string(tpgid) + "/cwd").c_str());
        }
        job["fg_argv"] = fg;
        job["fg_cwd"] = fg_cwd;
        jobs.push_back(job);
    }
    return jobs;
}
