#!/usr/bin/env bash
#
# Přehled všech prostředí na jednom místě.
#
# Použití: ./scripts/status.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_docker

echo -e "${BLUE}Stav prostředí${NC}\n"

for e in production staging dev; do
    [[ -f "$REPO_ROOT/env/$e.env" ]] || continue

    # shellcheck disable=SC1090
    ( set -a; source "$REPO_ROOT/env/$e.env"; set +a

      echo -e "${BLUE}$e${NC}  ${FE_DOMAIN:-?}"

      for svc in frontend backend db; do
          name="uat-$e-$svc"
          if docker ps --format '{{.Names}}' | grep -qx "$name"; then
              img="$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null)"
              up="$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)"
              printf "  ${GREEN}●${NC} %-10s %-38s %s\n" "$svc" "$img" "$up"
          else
              printf "  ${RED}○${NC} %-10s %s\n" "$svc" "neběží"
          fi
      done

      # Kontejner i veřejná adresa zvlášť: když kontejner odpovídá
      # a doména ne, chyba je v nginxu, ne v aplikaci.
      if [[ -n "${FE_PORT:-}" ]]; then
          local_code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:${FE_PORT}/" 2>/dev/null || echo '---')"
          printf "  kontejner: %s\n" "$local_code"
      fi
      if [[ -n "${FE_DOMAIN:-}" ]]; then
          code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "https://${FE_DOMAIN}/" 2>/dev/null || echo '---')"
          printf "  web:       %s\n" "$code"
      fi
      echo
    )
done

echo -e "${BLUE}Zálohy${NC}"
for e in production staging; do
    dir="$REPO_ROOT/backups/$e"
    [[ -d "$dir" ]] || continue
    last="$(ls -1t "$dir"/db-*.sql.gz 2>/dev/null | head -1)"
    if [[ -n "$last" ]]; then
        printf "  %-12s %s (%s)\n" "$e" "$(basename "$last")" "$(du -h "$last" | cut -f1)"
    else
        printf "  %-12s žádná\n" "$e"
    fi
done
