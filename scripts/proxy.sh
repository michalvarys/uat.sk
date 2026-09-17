#!/usr/bin/env bash
#
# Sdílený reverzní proxy (Traefik).
#
# Porty 80 a 443 může držet jen jeden proces, takže všechna prostředí
# sdílejí jeden Traefik a liší se doménami.
#
# Použití:
#   ./scripts/proxy.sh up       # spustit (jednou při přípravě serveru)
#   ./scripts/proxy.sh down
#   ./scripts/proxy.sh logs

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_docker

ACTION="${1:-up}"
ENV_FILE="$REPO_ROOT/env/production.env"
[[ -f "$ENV_FILE" ]] || { log_error "Chybí $ENV_FILE (kvůli e-mailu pro Let's Encrypt)."; exit 1; }

COMPOSE=(docker compose -p uat-proxy -f "$REPO_ROOT/compose/proxy.yml" --env-file "$ENV_FILE")

case "$ACTION" in
    up)   log_step "Startuji proxy"; "${COMPOSE[@]}" up -d; log_info "Běží." ;;
    down) log_step "Zastavuji proxy"; "${COMPOSE[@]}" down ;;
    logs) "${COMPOSE[@]}" logs -f --tail 100 ;;
    *)    log_error "Neznámá akce: $ACTION (up | down | logs)"; exit 1 ;;
esac
