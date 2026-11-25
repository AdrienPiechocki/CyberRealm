#!/usr/bin/env bash
# CyberRealm — installateur du serveur dédié (headless) pour Raspberry Pi 5 / tout Linux arm64 ou x86_64.
#
# Installe Godot, une copie MINIMALE du projet (scripts + scène serveur : ni compositeur Wayland, ni assets du
# jeu), le niveau exporté (blob), une configuration et un service systemd. Voir docs/dedicated-server.md.
#
#   sudo ./server/install-server.sh install --blob level.crblob [--pin 4242] [--name "Mon serveur"]
#   sudo ./server/install-server.sh update  [--blob nouveau.crblob]
#   sudo ./server/install-server.sh blob    nouveau.crblob
#        ./server/install-server.sh status
#   sudo ./server/install-server.sh uninstall [--purge]
#
# Le blob se produit sur une machine de jeu :
#   godot --headless --path Game/source --script scripts/tools/export_level_blob.gd -- res://user/level.tscn level.crblob
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GODOT_TAG="4.7.2-stable"
PREFIX="/opt/cyberrealm-server"
DATA_DIR=""                         # défaut : $PREFIX/data
SERVICE_USER="cyberrealm"
SERVICE_NAME="cyberrealm-server"
SOURCE_DIR="$REPO_DIR/Game/source"
GODOT_BIN=""                        # défaut : téléchargé dans $PREFIX/godot
BLOB_SRC=""
PIN=""
NAME=""
MAX_PLAYERS=""
DTLS=""                             # 1 = chiffré (défaut), 0 = --no-dtls
ONLINE=""                           # 1 = serveur exposé sur Internet (mode online durci)
DOMAIN=""                           # nom DNS du serveur (certificat Let's Encrypt)
EMAIL=""                            # e-mail Let's Encrypt (alertes d'expiration)
HTTP_PORT=80                        # port LOCAL de la validation Let's Encrypt (la box redirige 80 -> ce port)
TLS_CERT_SRC=""                     # certificat fourni (au lieu de Let's Encrypt)
TLS_KEY_SRC=""
ADMIN_PW=""                         # mot de passe admin (joueur qui règle les options du niveau)
ADMIN_PW_SET=0
NO_SERVICE=0
OPEN_FIREWALL=0
PURGE=0

PORT_GAME=7777        # UDP : session
PORT_DISCOVERY=9999   # UDP : découverte LAN
PORT_LEVEL=7778       # TCP : transfert du niveau

log()  { printf '\033[1;36m[serveur]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[serveur] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[serveur] %s\033[0m\n' "$*" >&2; exit 1; }

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; cat <<'EOF'

Options :
  --blob FICHIER        niveau exporté (.crblob) à servir
  --pin NNNN            PIN de la session (défaut : conservé, sinon tiré au sort)
  --name TEXTE          nom affiché par la découverte LAN
  --max-players N       nombre de joueurs maximum (défaut : 8)
  --no-dtls             désactive le chiffrement DTLS (débogage)
  --dtls                (ré)active le chiffrement DTLS
  --online              serveur sur INTERNET : TLS réel, mot de passe long, découverte coupée, partages coupés.
                        Exige --domain + --email (certificat Let's Encrypt) ou --tls-cert/--tls-key. Voir docs.
  --domain NOM          nom DNS public du serveur (ex. play.exemple.org) ; les joueurs rejoignent PAR CE NOM
  --email ADRESSE       e-mail Let's Encrypt
  --http-port N         port LOCAL de validation Let's Encrypt (défaut 80). Si le port 80 est pris (conteneur, proxy),
                        choisis 8080 et redirige TCP 80 -> N sur ta box. Mémorisé par certbot pour les renouvellements.
  --tls-cert FICHIER    certificat (chaîne complète PEM) fourni par toi, avec --tls-key FICHIER
  --admin-password MDP  mot de passe « admin » : le joueur qui le saisit (menu pause > Level) peut régler les options
                        du niveau (heure, météo…). Vide ("") = aucun admin. Conservé d'une mise à jour à l'autre.
  --source DIR          dossier Game/source à installer (défaut : celui de ce dépôt)
  --prefix DIR          dossier d'installation (défaut : /opt/cyberrealm-server)
  --user NOM            utilisateur du service (défaut : cyberrealm)
  --godot-bin CHEMIN    utilise ce Godot 4.7.2 au lieu d'en télécharger un
  --godot-tag TAG       version à télécharger (défaut : 4.7.2-stable)
  --open-firewall       ouvre les ports dans ufw (si ufw est actif)
  --no-service          pas de systemd ni d'utilisateur dédié (installation locale, sans root)
  --purge               (uninstall) supprime aussi données, niveau et utilisateur
EOF
}

# ── Arguments ────────────────────────────────────────────────────────

CMD="${1:-install}"
case "$CMD" in
    install|update|blob|status|uninstall) shift || true ;;
    -h|--help|help) usage; exit 0 ;;
    -*) CMD="install" ;;
    *) die "commande inconnue : $CMD (voir --help)" ;;
esac

if [[ "$CMD" == "blob" ]]; then
    [[ $# -ge 1 ]] || die "usage : $0 blob FICHIER.crblob"
    BLOB_SRC="$1"; shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --blob)         BLOB_SRC="${2:?}"; shift 2 ;;
        --pin)          PIN="${2:?}"; shift 2 ;;
        --name)         NAME="${2:?}"; shift 2 ;;
        --max-players)  MAX_PLAYERS="${2:?}"; shift 2 ;;
        --no-dtls)      DTLS=0; shift ;;
        --dtls)         DTLS=1; shift ;;
        --admin-password) ADMIN_PW="${2-}"; ADMIN_PW_SET=1; shift 2 ;;
        --online)       ONLINE=1; shift ;;
        --domain)       DOMAIN="${2:?}"; shift 2 ;;
        --email)        EMAIL="${2:?}"; shift 2 ;;
        --http-port)    HTTP_PORT="${2:?}"; shift 2 ;;
        --tls-cert)     TLS_CERT_SRC="$(readlink -f "${2:?}")"; shift 2 ;;
        --tls-key)      TLS_KEY_SRC="$(readlink -f "${2:?}")"; shift 2 ;;
        --source)       SOURCE_DIR="$(cd "${2:?}" && pwd)"; shift 2 ;;
        --prefix)       PREFIX="${2:?}"; shift 2 ;;
        --user)         SERVICE_USER="${2:?}"; shift 2 ;;
        --godot-bin)    GODOT_BIN="$(readlink -f "${2:?}")"; shift 2 ;;
        --godot-tag)    GODOT_TAG="${2:?}"; shift 2 ;;
        --open-firewall) OPEN_FIREWALL=1; shift ;;
        --no-service)   NO_SERVICE=1; shift ;;
        --purge)        PURGE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) die "option inconnue : $1 (voir --help)" ;;
    esac
done

PREFIX="$(readlink -m "$PREFIX")"
DATA_DIR="${DATA_DIR:-$PREFIX/data}"
APP_DIR="$PREFIX/app"
CONF="$PREFIX/server.conf"
GODOT_DIR="$PREFIX/godot"
RUNNER="$PREFIX/run-server.sh"
UNIT="/etc/systemd/system/$SERVICE_NAME.service"
BLOB_DST="$DATA_DIR/level.crblob"
TLS_DIR="$PREFIX/tls"
GENERATED_PASSWORD=""

if [[ -n "$MAX_PLAYERS" && ! "$MAX_PLAYERS" =~ ^[0-9]+$ ]]; then die "--max-players : nombre attendu"; fi

# ── Utilitaires ──────────────────────────────────────────────────────

need_root() {
    if [[ $NO_SERVICE -eq 0 && $EUID -ne 0 ]]; then
        die "root requis (sudo) — ou ajoute --no-service pour une installation locale sans systemd."
    fi
}

as_service_user() {   # as_service_user CMD... : exécute en tant qu'utilisateur du service (ou soi-même)
    if [[ $NO_SERVICE -eq 0 ]]; then
        runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" "$@"
    else
        env HOME="$DATA_DIR" "$@"
    fi
}

conf_get() { [[ -f "$CONF" ]] && (set +u; . "$CONF"; printf '%s' "${!1:-}") || true; }

host_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo arm64 ;;
        x86_64|amd64)  echo x86_64 ;;
        *) die "architecture non prise en charge : $(uname -m) (arm64 ou x86_64)" ;;
    esac
}

ensure_deps() {
    local missing=() c
    for c in curl unzip rsync; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    if [[ $EUID -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        log "installation des paquets manquants : ${missing[*]}"
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates
    else
        die "commandes manquantes : ${missing[*]} — installe-les puis relance."
    fi
}

# ── Étapes ───────────────────────────────────────────────────────────

create_user_and_dirs() {
    mkdir -p "$PREFIX" "$DATA_DIR"
    if [[ $NO_SERVICE -eq 0 ]]; then
        if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
            log "création de l'utilisateur système « $SERVICE_USER »"
            useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
        fi
        chown "$SERVICE_USER": "$DATA_DIR"
    fi
}

install_godot() {
    if [[ -n "$GODOT_BIN" ]]; then
        [[ -x "$GODOT_BIN" ]] || die "Godot introuvable ou non exécutable : $GODOT_BIN"
        return
    fi
    local arch zip url want="${GODOT_TAG%%-*}"
    arch="$(host_arch)"
    GODOT_BIN="$GODOT_DIR/godot"
    if [[ -x "$GODOT_BIN" ]] && "$GODOT_BIN" --version 2>/dev/null | grep -q "^$want"; then
        log "Godot $want déjà installé"
        return
    fi
    zip="Godot_v${GODOT_TAG}_linux.${arch}.zip"
    url="https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/${zip}"
    log "téléchargement de Godot $GODOT_TAG ($arch) — ~75 Mo"
    mkdir -p "$GODOT_DIR"
    local tmp; tmp="$(mktemp -d)"
    curl -fL --retry 3 -o "$tmp/$zip" "$url" || die "téléchargement impossible : $url"
    unzip -qo "$tmp/$zip" -d "$tmp"
    local extracted; extracted="$(find "$tmp" -maxdepth 1 -type f -name 'Godot_v*' ! -name '*.zip' | head -1)"
    [[ -n "$extracted" ]] || die "binaire Godot introuvable dans l'archive"
    install -m 0755 "$extracted" "$GODOT_BIN"
    rm -rf "$tmp"
    "$GODOT_BIN" --version | grep -q "^$want" || die "version inattendue : $("$GODOT_BIN" --version)"
}

sync_project() {
    [[ -f "$SOURCE_DIR/project.godot" ]] || die "projet introuvable : $SOURCE_DIR (utilise --source)"
    [[ -f "$SOURCE_DIR/scenes/dedicated_server.tscn" ]] \
        || die "$SOURCE_DIR n'a pas de scenes/dedicated_server.tscn — version du projet trop ancienne ?"
    log "copie du projet minimal -> $APP_DIR"
    mkdir -p "$APP_DIR"
    # Seulement ce qu'exécute le serveur : projet, scripts, thème, scène serveur et avatar par défaut. Ni assets, ni
    # tests, ni bin/ (extension Wayland), ni user/ (le niveau voyage dans le blob).
    rsync -a --delete --prune-empty-dirs \
        --include='/project.godot' \
        --include='/scripts/***' --include='/ui/***' \
        --include='/scenes/' --include='/scenes/dedicated_server.tscn' --include='/scenes/avatar.tscn' \
        --exclude='*' \
        "$SOURCE_DIR/" "$APP_DIR/"
    if [[ $NO_SERVICE -eq 0 ]]; then chown -R "$SERVICE_USER": "$APP_DIR"; fi
    log "import du projet (première fois : quelques secondes)"
    as_service_user "$GODOT_BIN" --headless --path "$APP_DIR" --import >/dev/null 2>&1 || true
    [[ -d "$APP_DIR/.godot" ]] || die "l'import Godot a échoué (relance avec : $GODOT_BIN --headless --path $APP_DIR --import)"
}

install_blob() {
    [[ -n "$BLOB_SRC" ]] || return 0
    [[ -f "$BLOB_SRC" ]] || die "niveau introuvable : $BLOB_SRC"
    log "installation du niveau ($(du -h "$BLOB_SRC" | cut -f1))"
    install -m 0644 "$BLOB_SRC" "$BLOB_DST.new"
    mv -f "$BLOB_DST.new" "$BLOB_DST"
    if [[ $NO_SERVICE -eq 0 ]]; then chown "$SERVICE_USER": "$BLOB_DST"; fi
}

write_config() {
    local pin name maxp dtls online domain
    online="${ONLINE:-$(conf_get ONLINE)}"; online="${online:-0}"
    domain="${DOMAIN:-$(conf_get DOMAIN)}"
    pin="${PIN:-$(conf_get PIN)}"
    if [[ "$online" == 1 ]]; then
        # Online : mot de passe long (12+). Généré (aléatoire, 20 caractères) s'il n'est pas fourni ou trop court.
        if [[ ${#pin} -lt 12 ]]; then
            [[ -z "$PIN" ]] || die "mot de passe trop court : 12 caractères minimum en mode --online"
            pin="$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 20 || true)"
            GENERATED_PASSWORD="$pin"
        fi
    else
        if [[ -z "$pin" ]]; then pin="$(printf '%04d' $((RANDOM % 10000)))"; fi
        if [[ ! "$pin" =~ ^[0-9]{4}$ ]]; then
            [[ -z "$PIN" ]] || die "le PIN doit faire 4 chiffres (mot de passe long : mode --online)"
            pin="$(printf '%04d' $((RANDOM % 10000)))"
        fi
    fi
    name="${NAME:-$(conf_get NAME)}"; name="${name:-CyberRealm Server}"
    maxp="${MAX_PLAYERS:-$(conf_get MAX_PLAYERS)}"; maxp="${maxp:-8}"
    dtls="${DTLS:-$(conf_get DTLS)}"; dtls="${dtls:-1}"
    PIN="$pin"
    local admin_pw
    if [[ $ADMIN_PW_SET -eq 1 ]]; then admin_pw="$ADMIN_PW"; else admin_pw="$(conf_get ADMIN_PASSWORD)"; fi
    {
        echo "# Configuration du serveur CyberRealm — relance le service après modification."
        printf 'GODOT=%q\n' "$GODOT_BIN"
        printf 'APP=%q\n' "$APP_DIR"
        printf 'BLOB=%q\n' "$BLOB_DST"
        printf 'PIN=%q\n' "$pin"
        printf 'NAME=%q\n' "$name"
        printf 'MAX_PLAYERS=%q\n' "$maxp"
        printf 'DTLS=%q\n' "$dtls"
        printf 'ADMIN_PASSWORD=%q\n' "$admin_pw"
        printf 'ONLINE=%q\n' "$online"
        printf 'DOMAIN=%q\n' "$domain"
        printf 'TLS_CERT=%q\n' "$TLS_DIR/fullchain.pem"
        printf 'TLS_KEY=%q\n' "$TLS_DIR/privkey.pem"
        printf 'EXTRA_ARGS=%q\n' "$(conf_get EXTRA_ARGS)"
        printf 'HOME=%q\n' "$DATA_DIR"
    } > "$CONF"
    chmod 0640 "$CONF"
    if [[ $NO_SERVICE -eq 0 ]]; then chown "root:$SERVICE_USER" "$CONF"; fi
    cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
# Lance le serveur au premier plan avec la configuration de server.conf (utilisé par systemd).
set -euo pipefail
CONF="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/server.conf"
# shellcheck disable=SC1090
. "$CONF"
export HOME
# Par l'environnement (pas en argument : visible dans `ps`).
export CYBERREALM_ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
[[ -f "$BLOB" ]] || { echo "niveau introuvable : $BLOB (installe-le : install-server.sh blob FICHIER)" >&2; exit 2; }
args=("--blob=$BLOB" "--name=$NAME" "--max-players=$MAX_PLAYERS")
if [[ "${ONLINE:-0}" == "1" ]]; then
    # Mode Internet : TLS réel, mot de passe par l'environnement (jamais en argument), chiffrement toujours actif.
    export CYBERREALM_PASSWORD="$PIN"
    args+=("--online" "--tls-cert=$TLS_CERT" "--tls-key=$TLS_KEY")
else
    args+=("--pin=$PIN")
    [[ "${DTLS:-1}" == "0" ]] && args+=("--no-dtls")
fi
# shellcheck disable=SC2086
exec "$GODOT" --headless --path "$APP" scenes/dedicated_server.tscn -- "${args[@]}" ${EXTRA_ARGS:-}
EOF
    chmod 0755 "$RUNNER"
}

write_service() {
    [[ $NO_SERVICE -eq 1 ]] && return 0
    command -v systemctl >/dev/null 2>&1 || { warn "systemd absent : lance $RUNNER à la main."; return 0; }
    log "service systemd : $UNIT"
    cat > "$UNIT" <<EOF
[Unit]
Description=CyberRealm dedicated server
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$DATA_DIR
ExecStart=$RUNNER
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
# Durcissement : le serveur n'a besoin que de son dossier et du réseau.
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$PREFIX
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=yes
LockPersonality=yes
CapabilityBoundingSet=
# Le niveau complet (Morrowind) occupe ~1,5 Go : marge large sur un Pi 5 16 Go, plafond de sécurité.
MemoryMax=8G

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

# Mode online : certificat TLS. Let's Encrypt (certbot standalone, port 80 joignable depuis Internet) ou fichiers fournis.
setup_tls() {
    local online="${ONLINE:-$(conf_get ONLINE)}"
    [[ "$online" == 1 ]] || return 0
    [[ "${DTLS:-1}" != 0 ]] || die "--online est incompatible avec --no-dtls"
    local domain="${DOMAIN:-$(conf_get DOMAIN)}"
    mkdir -p "$TLS_DIR"
    if [[ -n "$TLS_CERT_SRC" || -n "$TLS_KEY_SRC" ]]; then
        [[ -f "$TLS_CERT_SRC" && -f "$TLS_KEY_SRC" ]] || die "--tls-cert et --tls-key doivent désigner deux fichiers existants"
        log "certificat fourni : installation dans $TLS_DIR"
        install -m 0644 "$TLS_CERT_SRC" "$TLS_DIR/fullchain.pem"
        install -m 0600 "$TLS_KEY_SRC" "$TLS_DIR/privkey.pem"
    elif [[ -n "$domain" ]]; then
        [[ -n "$EMAIL" || -f "$TLS_DIR/fullchain.pem" ]] || die "--email requis pour obtenir le certificat Let's Encrypt"
        if [[ ! -f "$TLS_DIR/fullchain.pem" ]]; then
            command -v certbot >/dev/null 2>&1 || {
                if [[ $EUID -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
                    log "installation de certbot"; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot
                else die "certbot est requis (apt install certbot)"; fi
            }
            warn "Let's Encrypt va contacter http://$domain/ sur le PORT 80 public : il doit être redirigé vers le port $HTTP_PORT de ce serveur."
            if [[ "$HTTP_PORT" != 80 ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
                ufw allow "$HTTP_PORT/tcp" >/dev/null        # (validation et renouvellements)
            fi
            certbot certonly --standalone --http-01-port "$HTTP_PORT" --non-interactive --agree-tos -m "$EMAIL" -d "$domain" \
                || die "certbot a échoué (nom DNS correct ? port 80 ouvert/redirigé ?)"
        fi
        install_cert_hook "$domain"
        copy_letsencrypt "$domain"
    else
        [[ -f "$TLS_DIR/fullchain.pem" && -f "$TLS_DIR/privkey.pem" ]] \
            || die "mode online : fournis --domain NOM --email ADRESSE (Let's Encrypt) ou --tls-cert/--tls-key"
    fi
    if [[ $NO_SERVICE -eq 0 ]]; then
        chown -R "root:$SERVICE_USER" "$TLS_DIR"; chmod 0750 "$TLS_DIR"
        chmod 0640 "$TLS_DIR/privkey.pem"; chmod 0644 "$TLS_DIR/fullchain.pem"
    fi
}

copy_letsencrypt() {
    local domain="$1" live="/etc/letsencrypt/live/$1"
    [[ -f "$live/fullchain.pem" ]] || return 0
    install -m 0644 "$live/fullchain.pem" "$TLS_DIR/fullchain.pem"
    install -m 0640 "$live/privkey.pem" "$TLS_DIR/privkey.pem"
}

# Renouvellement automatique (certbot.timer) : recopie le certificat et redémarre le serveur pour le recharger.
install_cert_hook() {
    local domain="$1" hook="/etc/letsencrypt/renewal-hooks/deploy/cyberrealm-server.sh"
    [[ $EUID -eq 0 && -d /etc/letsencrypt ]] || return 0
    mkdir -p "$(dirname "$hook")"
    cat > "$hook" <<EOF
#!/usr/bin/env bash
# CyberRealm : après renouvellement, installer le nouveau certificat et redémarrer le serveur.
set -e
[[ "\$RENEWED_LINEAGE" == "/etc/letsencrypt/live/$domain" ]] || exit 0
install -m 0644 "\$RENEWED_LINEAGE/fullchain.pem" "$TLS_DIR/fullchain.pem"
install -m 0640 "\$RENEWED_LINEAGE/privkey.pem" "$TLS_DIR/privkey.pem"
chown root:$SERVICE_USER "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem"
systemctl restart $SERVICE_NAME
EOF
    chmod 0755 "$hook"
}

open_firewall() {
    [[ $OPEN_FIREWALL -eq 1 ]] || return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        log "ouverture des ports dans ufw"
        ufw allow "$PORT_GAME/udp" >/dev/null
        ufw allow "$PORT_LEVEL/tcp" >/dev/null
        # La découverte UDP (9999) n'existe pas en mode online : port à ne PAS ouvrir.
        if [[ "${ONLINE:-$(conf_get ONLINE)}" != 1 ]]; then ufw allow "$PORT_DISCOVERY/udp" >/dev/null; fi
    else
        warn "ufw absent ou inactif : ouvre toi-même UDP $PORT_GAME et $PORT_DISCOVERY, TCP $PORT_LEVEL si besoin."
    fi
}

start_service() {
    [[ $NO_SERVICE -eq 1 ]] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    if [[ ! -f "$BLOB_DST" ]]; then
        warn "aucun niveau installé : le service n'est PAS démarré. Installe-en un : $0 blob FICHIER.crblob"
        return 0
    fi
    log "(re)démarrage du service"
    systemctl restart "$SERVICE_NAME"
}

# Adresse(s) à donner aux joueurs : d'abord celle de la route par défaut (le vrai réseau), puis les autres, sans les
# ponts Docker/virtuels (172.17.x…), injoignables depuis l'extérieur.
lan_ips() {
    local primary others
    primary="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
    others="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -vE '^172\.(1[7-9]|2[0-9]|3[01])\.0\.1$' \
        | grep -vxF "${primary:-none}" | paste -sd' ' - || true)"
    printf '%s' "${primary:+$primary }$others"
}

summary() {
    echo
    log "installation terminée"
    printf '  Adresse(s) : %s\n' "$(lan_ips)"
    if [[ "$(conf_get ONLINE)" == 1 ]]; then
        printf '  MODE       : ONLINE (Internet) — les joueurs rejoignent par le NOM : %s\n' "$(conf_get DOMAIN)"
        if [[ -n "$GENERATED_PASSWORD" ]]; then
            printf '  Mot de passe généré (à donner aux joueurs, noté dans %s) : %s\n' "$CONF" "$GENERATED_PASSWORD"
        else
            printf '  Mot de passe : défini (voir %s)\n' "$CONF"
        fi
        printf '  Redirige sur ta box : UDP %s et TCP %s vers ce serveur (+ TCP 80 pour Let'"'"'s Encrypt)\n' "$PORT_GAME" "$PORT_LEVEL"
    else
        printf '  PIN        : %s\n' "$(conf_get PIN)"
    fi
    if [[ "$(conf_get ONLINE)" == 1 ]]; then
        printf '  Ports      : UDP %s (jeu), TCP %s (niveau) — pas de découverte\n' "$PORT_GAME" "$PORT_LEVEL"
    else
        printf '  Ports      : UDP %s (jeu), UDP %s (découverte), TCP %s (niveau)\n' "$PORT_GAME" "$PORT_DISCOVERY" "$PORT_LEVEL"
    fi
    printf '  Niveau     : %s\n' "$([[ -f "$BLOB_DST" ]] && echo "$BLOB_DST" || echo "AUCUN (voir : $0 blob FICHIER)")"
    if [[ $NO_SERVICE -eq 0 ]]; then
        printf '  Journal    : journalctl -u %s -f\n' "$SERVICE_NAME"
        printf '  Contrôle   : systemctl {status|restart|stop} %s\n' "$SERVICE_NAME"
    else
        printf '  Lancer     : %s\n' "$RUNNER"
    fi
    printf '  Admin      : %s\n' "$([[ -n "$(conf_get ADMIN_PASSWORD)" ]] && echo "mot de passe défini (voir $CONF)" || echo "désactivé — ajoute --admin-password MDP")"
    printf '  Config     : %s (PIN, nom, joueurs max, DTLS, admin)\n' "$CONF"
}

# ── Commandes ────────────────────────────────────────────────────────

do_install() {
    need_root
    ensure_deps
    create_user_and_dirs
    install_godot
    sync_project
    install_blob
    setup_tls_early
    write_config
    setup_tls
    write_service
    open_firewall
    start_service
    summary
}

# DOMAIN/ONLINE doivent être connus de write_config avant setup_tls (qui lit la config) : rien à faire ici sauf
# refuser les combinaisons incohérentes tôt.
setup_tls_early() {
    if [[ "$ONLINE" == 1 && "$DTLS" == 0 ]]; then die "--online est incompatible avec --no-dtls"; fi
}

do_update() {
    need_root
    [[ -f "$CONF" ]] || die "pas d'installation trouvée dans $PREFIX — lance d'abord « install »."
    GODOT_BIN="${GODOT_BIN:-$(conf_get GODOT)}"
    ensure_deps
    install_godot
    sync_project
    install_blob
    setup_tls_early
    write_config
    setup_tls
    write_service
    open_firewall
    start_service
    summary
}

do_blob() {
    need_root
    [[ -f "$CONF" ]] || die "pas d'installation trouvée dans $PREFIX — lance d'abord « install »."
    install_blob
    start_service
    log "niveau remplacé"
}

do_status() {
    [[ -f "$CONF" ]] || die "pas d'installation trouvée dans $PREFIX."
    printf 'PIN : %s   nom : %s   joueurs max : %s   DTLS : %s\n' "$(conf_get PIN)" "$(conf_get NAME)" \
        "$(conf_get MAX_PLAYERS)" "$([[ "$(conf_get DTLS)" == 0 ]] && echo non || echo oui)"
    printf 'Niveau : %s   admin : %s\n' "$([[ -f "$BLOB_DST" ]] && du -h "$BLOB_DST" | cut -f1 || echo absent)" \
        "$([[ -n "$(conf_get ADMIN_PASSWORD)" ]] && echo "mot de passe défini" || echo "désactivé")"
    if command -v systemctl >/dev/null 2>&1 && [[ -f "$UNIT" ]]; then
        systemctl --no-pager --lines=8 status "$SERVICE_NAME" || true
    fi
    if command -v ss >/dev/null 2>&1; then
        echo "Ports en écoute :"; ss -lun 2>/dev/null | grep -E ":($PORT_GAME|$PORT_DISCOVERY)\b" || true
        ss -ltn 2>/dev/null | grep -E ":$PORT_LEVEL\b" || true
    fi
}

do_uninstall() {
    need_root
    if [[ $NO_SERVICE -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$UNIT"; systemctl daemon-reload
    fi
    log "suppression de l'application et de Godot"
    rm -rf "$APP_DIR" "$GODOT_DIR" "$RUNNER"
    if [[ $PURGE -eq 1 ]]; then
        log "purge : données, configuration et utilisateur"
        rm -rf "$DATA_DIR" "$CONF"
        rmdir "$PREFIX" 2>/dev/null || true
        if [[ $NO_SERVICE -eq 0 ]]; then userdel "$SERVICE_USER" 2>/dev/null || true; fi
    else
        log "niveau et configuration conservés dans $PREFIX (--purge pour tout supprimer)"
    fi
}

case "$CMD" in
    install)   do_install ;;
    update)    do_update ;;
    blob)      do_blob ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
esac
