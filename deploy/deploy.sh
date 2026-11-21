#!/usr/bin/env bash
# Deploy or update the pdfsync server on a VM with Docker Compose.
#
# Copy this one file to the VM and run it:
#
#   ./deploy.sh                              # HTTP on port 8080
#   ./deploy.sh --domain sync.example.com    # HTTPS via Caddy (automatic certificate)
#   ./deploy.sh                              # later: update to the newest image, same settings
#
# Options (remembered in <dir>/.env, so later runs need none):
#   --domain NAME        serve HTTPS for NAME with Caddy; ports 80 and 443 must be
#                        open and NAME must point at this VM. "--domain none" turns it off.
#   --tag TAG            image tag (default: latest; e.g. 1.0.0)
#   --max-upload-mb N    largest PDF the server accepts (default: 512)
#   --dir PATH           install directory (default: ~/pdfsync)
#
# The image is private: the first run asks for a GitHub token with the
# read:packages scope (or set GHCR_TOKEN=... in the environment).
# Data lives in the Docker volume "pdfsync-data" and survives updates.
set -euo pipefail

IMAGE=ghcr.io/abhijeetadarsh/pdfsync-server
GHCR_USER=abhijeetadarsh
DIR="$HOME/pdfsync"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

# --- arguments --------------------------------------------------------------
ARG_DOMAIN= ARG_TAG= ARG_MAX=
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) ARG_DOMAIN=${2:?--domain needs a value}; shift 2 ;;
    --tag) ARG_TAG=${2:?--tag needs a value}; shift 2 ;;
    --max-upload-mb) ARG_MAX=${2:?--max-upload-mb needs a value}; shift 2 ;;
    --dir) DIR=${2:?--dir needs a value}; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- prerequisites ----------------------------------------------------------
command -v docker >/dev/null || die "Docker is not installed. Install it: https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "the Docker Compose plugin is missing ('docker compose'). Install docker-compose-plugin."
DOCKER=docker
if ! docker info >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null || [ -t 0 ]; then
    DOCKER="sudo docker"
    $DOCKER info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running?)"
  else
    die "cannot talk to the Docker daemon (add your user to the docker group or run with sudo)"
  fi
fi
command -v curl >/dev/null || die "curl is not installed"

# --- settings (remembered between runs) -------------------------------------
mkdir -p "$DIR"
cd "$DIR"
PDFSYNC_DOMAIN= PDFSYNC_TAG=latest PDFSYNC_MAX_UPLOAD_MB=512
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
[ -n "$ARG_DOMAIN" ] && PDFSYNC_DOMAIN=$ARG_DOMAIN
[ "$PDFSYNC_DOMAIN" = none ] && PDFSYNC_DOMAIN=
[ -n "$ARG_TAG" ] && PDFSYNC_TAG=$ARG_TAG
[ -n "$ARG_MAX" ] && PDFSYNC_MAX_UPLOAD_MB=$ARG_MAX
case "$PDFSYNC_MAX_UPLOAD_MB" in ''|*[!0-9]*) die "--max-upload-mb must be a number" ;; esac

# With HTTPS, port 8080 is only reachable from the VM itself (Caddy is the way in).
if [ -n "$PDFSYNC_DOMAIN" ]; then PDFSYNC_BIND=127.0.0.1; else PDFSYNC_BIND=0.0.0.0; fi

cat > .env <<EOF
# Written by deploy.sh – edit, or re-run deploy.sh with options.
PDFSYNC_DOMAIN=$PDFSYNC_DOMAIN
PDFSYNC_TAG=$PDFSYNC_TAG
PDFSYNC_MAX_UPLOAD_MB=$PDFSYNC_MAX_UPLOAD_MB
PDFSYNC_BIND=$PDFSYNC_BIND
COMPOSE_PROFILES=${PDFSYNC_DOMAIN:+https}
EOF

cat > docker-compose.yml <<'EOF'
# Written by deploy.sh – changes here are overwritten on the next run.
name: pdfsync
services:
  server:
    image: ghcr.io/abhijeetadarsh/pdfsync-server:${PDFSYNC_TAG:-latest}
    restart: unless-stopped
    # Appended to the image's entrypoint (-addr :8080 -data /data).
    command: ["-max-upload-mb", "${PDFSYNC_MAX_UPLOAD_MB:-512}"]
    ports:
      - "${PDFSYNC_BIND:-0.0.0.0}:8080:8080"
    volumes:
      - data:/data

  # HTTPS in front of the server (only with --domain). Also proxies the
  # live-sync websocket.
  caddy:
    image: caddy:2
    profiles: [https]
    restart: unless-stopped
    command: ["caddy", "reverse-proxy", "--from", "${PDFSYNC_DOMAIN:-localhost}", "--to", "server:8080"]
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - caddy-data:/data
      - caddy-config:/config
    depends_on: [server]

volumes:
  data:
    name: pdfsync-data   # same volume as a manual `docker run -v pdfsync-data:/data`
  caddy-data:
  caddy-config:
EOF

# --- a container from a manual `docker run --name pdfsync` holds port 8080 ----
if $DOCKER ps -a --format '{{.Names}}' | grep -qx pdfsync; then
  if [ -z "$($DOCKER inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' pdfsync)" ]; then
    say "Removing the manually started container 'pdfsync' (its data volume is kept)"
    $DOCKER rm -f pdfsync >/dev/null
  fi
fi
if [ -n "$PDFSYNC_DOMAIN" ] && $DOCKER ps -a --format '{{.Names}}' | grep -qx caddy; then
  if [ -z "$($DOCKER inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' caddy)" ]; then
    say "Removing the manually started container 'caddy' (it holds ports 80/443)"
    $DOCKER rm -f caddy >/dev/null
  fi
fi

# --- pull (logging in to ghcr.io if needed) ---------------------------------
if ! $DOCKER pull -q "$IMAGE:$PDFSYNC_TAG" >/dev/null 2>&1; then
  say "Logging in to ghcr.io (the image is private)"
  TOKEN=${GHCR_TOKEN:-}
  if [ -z "$TOKEN" ]; then
    [ -t 0 ] || die "set GHCR_TOKEN to a GitHub token with the read:packages scope"
    read -rsp "GitHub token with read:packages: " TOKEN; echo
  fi
  printf '%s' "$TOKEN" | $DOCKER login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null \
    || die "login to ghcr.io failed (check the token and its read:packages scope)"
  $DOCKER pull -q "$IMAGE:$PDFSYNC_TAG" >/dev/null || die "cannot pull $IMAGE:$PDFSYNC_TAG (does the tag exist?)"
fi

say "Starting pdfsync ($IMAGE:$PDFSYNC_TAG${PDFSYNC_DOMAIN:+, HTTPS for $PDFSYNC_DOMAIN})"
$DOCKER compose pull -q
$DOCKER compose up -d --remove-orphans
# HTTPS turned off (--domain none): stop the Caddy container it left behind.
if [ -z "$PDFSYNC_DOMAIN" ]; then
  $DOCKER compose --profile https rm -sf caddy >/dev/null 2>&1 || true
fi

# --- health check -----------------------------------------------------------
for _ in $(seq 1 30); do
  if [ "$(curl -fsS --max-time 2 http://127.0.0.1:8080/healthz 2>/dev/null)" = ok ]; then
    say "pdfsync is running."
    if [ -n "$PDFSYNC_DOMAIN" ]; then
      echo "    Server URL for the apps: https://$PDFSYNC_DOMAIN"
      echo "    (the certificate is issued on the first request; check with: curl https://$PDFSYNC_DOMAIN/healthz)"
    else
      # hostname -I is Debian/Ubuntu-only; fall back to the default route's source address.
      ip=$( { hostname -I 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'; } | awk '{print $1}' ) || true
      echo "    Server URL for the apps: http://${ip:-<vm-ip>}:8080"
      echo "    Plain HTTP works for desktop and debug/profile builds; the release APK needs --domain (HTTPS)."
    fi
    echo "    Logs: cd $DIR && docker compose logs -f"
    exit 0
  fi
  sleep 1
done
$DOCKER compose ps
$DOCKER compose logs --tail 50 server
die "the server did not become healthy within 30 s (logs above)"
