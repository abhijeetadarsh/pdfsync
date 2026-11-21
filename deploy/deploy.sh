#!/usr/bin/env bash
# Deploy or update the pdfsync server on a VM with Docker Compose.
#
# Copy this one file to the VM and run it:
#
#   ./deploy.sh --port 9000          # first run: server on 127.0.0.1:9000
#   ./deploy.sh                      # later: update to the newest image, same settings
#
# Put your own reverse proxy (e.g. Caddy) in front for HTTPS – the release APK
# only talks HTTPS. See the end of this header for Caddy examples.
#
# Options (remembered in <dir>/.env, so later runs need none):
#   --port N             host port to expose the server on (default: 8080)
#   --listen ADDR        host address to bind: 127.0.0.1 (default; only the VM
#                        itself, e.g. Caddy on the host) or 0.0.0.0 (all interfaces)
#   --network NAME       also join this existing Docker network, so a Caddy
#                        *container* on it reaches the server as pdfsync:8080
#                        ("--network none" to leave it again)
#   --tag TAG            image tag (default: latest; e.g. 1.0.0)
#   --max-upload-mb N    largest PDF the server accepts (default: 512)
#   --dir PATH           install directory (default: ~/pdfsync)
#
# The image is private: the first run asks for a GitHub token with the
# read:packages scope (or set GHCR_TOKEN=... in the environment). It is built
# for linux/amd64 and linux/arm64; Docker pulls the one matching this VM.
# Data lives in the Docker volume "pdfsync-data" and survives updates.
#
# Caddy on the host (Caddyfile):      Caddy in a container on network NAME:
#   sync.example.com {                  sync.example.com {
#     reverse_proxy 127.0.0.1:9000        reverse_proxy pdfsync:8080
#   }                                   }
set -euo pipefail

IMAGE=ghcr.io/abhijeetadarsh/pdfsync-server
GHCR_USER=abhijeetadarsh
DIR="$HOME/pdfsync"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

# --- arguments --------------------------------------------------------------
ARG_PORT= ARG_LISTEN= ARG_NETWORK= ARG_TAG= ARG_MAX=
while [ $# -gt 0 ]; do
  case "$1" in
    --port) ARG_PORT=${2:?--port needs a value}; shift 2 ;;
    --listen) ARG_LISTEN=${2:?--listen needs a value}; shift 2 ;;
    --network) ARG_NETWORK=${2:?--network needs a value}; shift 2 ;;
    --tag) ARG_TAG=${2:?--tag needs a value}; shift 2 ;;
    --max-upload-mb) ARG_MAX=${2:?--max-upload-mb needs a value}; shift 2 ;;
    --dir) DIR=${2:?--dir needs a value}; shift 2 ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# --- prerequisites ----------------------------------------------------------
command -v docker >/dev/null || die "Docker is not installed. Install it: https://docs.docker.com/engine/install/"
DOCKER=docker
if ! docker info >/dev/null 2>&1; then
  [ -t 0 ] || sudo -n true 2>/dev/null || die "cannot talk to the Docker daemon (add your user to the docker group or run with sudo)"
  DOCKER="sudo docker"
  $DOCKER info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running?)"
fi
$DOCKER compose version >/dev/null 2>&1 || die "the Docker Compose plugin is missing ('docker compose'). Install docker-compose-plugin."
command -v curl >/dev/null || die "curl is not installed"

# --- settings (remembered between runs) -------------------------------------
mkdir -p "$DIR"
cd "$DIR"
PDFSYNC_PORT=8080 PDFSYNC_LISTEN=127.0.0.1 PDFSYNC_NETWORK= PDFSYNC_TAG=latest PDFSYNC_MAX_UPLOAD_MB=512
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
[ -n "$ARG_PORT" ] && PDFSYNC_PORT=$ARG_PORT
[ -n "$ARG_LISTEN" ] && PDFSYNC_LISTEN=$ARG_LISTEN
[ -n "$ARG_NETWORK" ] && PDFSYNC_NETWORK=$ARG_NETWORK
[ "$PDFSYNC_NETWORK" = none ] && PDFSYNC_NETWORK=
[ -n "$ARG_TAG" ] && PDFSYNC_TAG=$ARG_TAG
[ -n "$ARG_MAX" ] && PDFSYNC_MAX_UPLOAD_MB=$ARG_MAX
case "$PDFSYNC_PORT" in ''|*[!0-9]*) die "--port must be a number" ;; esac
{ [ "$PDFSYNC_PORT" -ge 1 ] && [ "$PDFSYNC_PORT" -le 65535 ]; } || die "--port must be 1-65535"
case "$PDFSYNC_MAX_UPLOAD_MB" in ''|*[!0-9]*) die "--max-upload-mb must be a number" ;; esac
if [ -n "$PDFSYNC_NETWORK" ]; then
  $DOCKER network inspect "$PDFSYNC_NETWORK" >/dev/null 2>&1 \
    || die "Docker network '$PDFSYNC_NETWORK' does not exist (docker network ls)"
fi

cat > .env <<EOF
# Written by deploy.sh – edit, or re-run deploy.sh with options.
PDFSYNC_PORT=$PDFSYNC_PORT
PDFSYNC_LISTEN=$PDFSYNC_LISTEN
PDFSYNC_NETWORK=$PDFSYNC_NETWORK
PDFSYNC_TAG=$PDFSYNC_TAG
PDFSYNC_MAX_UPLOAD_MB=$PDFSYNC_MAX_UPLOAD_MB
EOF

# The compose file; joining an external network needs extra lines.
{
  cat <<'EOF'
# Written by deploy.sh – changes here are overwritten on the next run.
name: pdfsync
services:
  server:
    image: ghcr.io/abhijeetadarsh/pdfsync-server:${PDFSYNC_TAG:-latest}
    restart: unless-stopped
    # Appended to the image's entrypoint (-addr :8080 -data /data).
    command: ["-max-upload-mb", "${PDFSYNC_MAX_UPLOAD_MB:-512}"]
    ports:
      - "${PDFSYNC_LISTEN:-127.0.0.1}:${PDFSYNC_PORT:-8080}:8080"
    volumes:
      - data:/data
EOF
  if [ -n "$PDFSYNC_NETWORK" ]; then
    cat <<'EOF'
    networks:
      default: {}
      proxy:
        aliases: [pdfsync]   # reverse proxy target: pdfsync:8080
EOF
  fi
  cat <<'EOF'

volumes:
  data:
    name: pdfsync-data   # same volume as a manual `docker run -v pdfsync-data:/data`
EOF
  if [ -n "$PDFSYNC_NETWORK" ]; then
    cat <<'EOF'

networks:
  proxy:
    name: ${PDFSYNC_NETWORK}
    external: true
EOF
  fi
} > docker-compose.yml

# --- a container from a manual `docker run --name pdfsync` holds the port ---
if $DOCKER ps -a --format '{{.Names}}' | grep -qx pdfsync; then
  if [ -z "$($DOCKER inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' pdfsync)" ]; then
    say "Removing the manually started container 'pdfsync' (its data volume is kept)"
    $DOCKER rm -f pdfsync >/dev/null
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
  $DOCKER pull -q "$IMAGE:$PDFSYNC_TAG" >/dev/null \
    || die "cannot pull $IMAGE:$PDFSYNC_TAG (does the tag exist? the image is for amd64 and arm64 only)"
fi

say "Starting pdfsync ($IMAGE:$PDFSYNC_TAG on $PDFSYNC_LISTEN:$PDFSYNC_PORT${PDFSYNC_NETWORK:+, network $PDFSYNC_NETWORK})"
# The server runs as the distroless "nonroot" user (uid 65532). A volume
# created before the image shipped a nonroot-owned /data (or by a manual
# `docker run`) is owned by root, and the server then fails with
# "mkdir /data/blobs: permission denied". Create the container and volume
# without starting them, then fix the owner if needed.
$DOCKER compose up --no-start --remove-orphans
$DOCKER run --rm -v pdfsync-data:/data busybox:1.37 \
  sh -c '[ "$(stat -c %u /data)" = 65532 ] || { echo "==> Fixing data volume owner"; chown -R 65532:65532 /data; }'
$DOCKER compose up -d --remove-orphans
# A container that was crash-looping sits in Docker's restart back-off (up to
# a minute between tries) and `up -d` leaves it there; restart it so it starts
# now, with the fixed volume and the current settings.
$DOCKER compose restart server >/dev/null

# --- health check -----------------------------------------------------------
HOST=$PDFSYNC_LISTEN
[ "$HOST" = 0.0.0.0 ] && HOST=127.0.0.1
for _ in $(seq 1 60); do
  if [ "$(curl -fsS --max-time 2 "http://$HOST:$PDFSYNC_PORT/healthz" 2>/dev/null)" = ok ]; then
    say "pdfsync is running on $PDFSYNC_LISTEN:$PDFSYNC_PORT."
    if [ -n "$PDFSYNC_NETWORK" ]; then
      echo "    Caddy container on '$PDFSYNC_NETWORK':  reverse_proxy pdfsync:8080"
    fi
    echo "    Caddy on the host:  reverse_proxy 127.0.0.1:$PDFSYNC_PORT"
    if [ "$PDFSYNC_LISTEN" = 0.0.0.0 ]; then
      # hostname -I is Debian/Ubuntu-only; fall back to the default route's source address.
      ip=$( { hostname -I 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'; } | awk '{print $1}' ) || true
      echo "    Direct (plain HTTP): http://${ip:-<vm-ip>}:$PDFSYNC_PORT"
    fi
    echo "    Logs: cd $DIR && docker compose logs -f"
    exit 0
  fi
  sleep 1
done
$DOCKER compose ps
$DOCKER compose logs --tail 50 server
die "the server did not become healthy within 60 s (logs above)"
