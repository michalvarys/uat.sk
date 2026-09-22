#!/usr/bin/env bash
#
# Nasazení do zvoleného prostředí.
#
# Použití:
#   ./scripts/deploy.sh --staging                    # staging, tag latest
#   ./scripts/deploy.sh --staging --tag v2.0.0
#   ./scripts/deploy.sh --prod --tag v2.0.0          # produkce (ptá se)
#   ./scripts/deploy.sh --staging --tag-frontend 2.0.1   # jen frontend jinak
#   ./scripts/deploy.sh --staging --frontend         # jen frontend
#   ./scripts/deploy.sh --prod --rollback            # předchozí verze
#   ./scripts/deploy.sh --staging --dry-run
#
# Před nasazením na produkci se vždy pořídí záloha databáze.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DO_FRONTEND=true
DO_BACKEND=true
DO_BACKUP=true
ROLLBACK=false
TAG=""
TAG_FRONTEND=""
TAG_BACKEND=""

parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --frontend)    DO_BACKEND=false; shift ;;
        --backend)     DO_FRONTEND=false; shift ;;
        --tag)         TAG="$2"; shift 2 ;;
        --tag-frontend) TAG_FRONTEND="$2"; shift 2 ;;
        --tag-backend)  TAG_BACKEND="$2"; shift 2 ;;
        --skip-backup) DO_BACKUP=false; shift ;;
        --rollback)    ROLLBACK=true; shift ;;
        -h|--help)     sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             log_error "Neznámý přepínač: $1"; exit 1 ;;
    esac
done

check_environment
require_docker
load_env

STATE_FILE="$REPO_ROOT/.deploy-state-$ENVIRONMENT"

main() {
    $ROLLBACK && { rollback; exit 0; }

    echo -e "${BLUE}Nasazení${NC}"
    echo    "  prostředí: $ENVIRONMENT"
    echo    "  verze:     ${TAG:-podle env souboru}"
    echo    "  backend:   $($DO_BACKEND && echo ano || echo ne)"
    echo    "  frontend:  $($DO_FRONTEND && echo ano || echo ne)"
    $DRY_RUN && echo -e "  ${YELLOW}režim:     dry-run${NC}"

    if [[ "$ENVIRONMENT" == "production" ]]; then
        confirm "Nasazujete na PRODUKCI. Pokračovat?" || {
            rc=$?
            # 2 = vědomé zrušení uživatelem, cokoli jiného je chyba.
            [[ $rc -eq 2 ]] && exit 0 || exit $rc
        }
    fi

    # Složky musí existovat a patřit správnému uživateli dřív, než
    # se kontejnery spustí — jinak databáze skončí na permission denied.
    prepare_data_dirs || exit 1

    backup_first
    remember_current
    pull_and_up
    verify

    log_step "Hotovo"
    log_info "Logy: ./scripts/logs.sh --$ENVIRONMENT"
    [[ "$ENVIRONMENT" == "production" ]] && log_info "Rollback: ./scripts/deploy.sh --prod --rollback"
    true
}

backup_first() {
    # Na produkci se zálohuje vždy: přepsat běžící verzi bez zálohy
    # je riziko, které se nevyplatí.
    if [[ "$ENVIRONMENT" != "production" ]]; then
        return
    fi

    if ! $DO_BACKUP; then
        log_warn "Záloha přeskočena (--skip-backup)."
        return
    fi

    log_step "Záloha před nasazením"
    if $DRY_RUN; then
        echo -e "   ${YELLOW}[dry-run]${NC} ./scripts/backup.sh --prod"
    else
        ENV=production "$REPO_ROOT/scripts/backup.sh" --prod >/dev/null
        log_info "Záloha pořízena."
    fi
}

remember_current() {
    local fe be
    fe="$(docker inspect --format '{{.Config.Image}}' "uat-$ENVIRONMENT-frontend" 2>/dev/null || echo '')"
    be="$(docker inspect --format '{{.Config.Image}}' "uat-$ENVIRONMENT-backend" 2>/dev/null || echo '')"

    if $DRY_RUN; then
        echo -e "   ${YELLOW}[dry-run]${NC} uložit stav: frontend=$fe backend=$be"
        return
    fi

    {
        echo "FRONTEND_PREV=$fe"
        echo "BACKEND_PREV=$be"
        echo "SAVED_AT=$(date -Iseconds)"
    } > "$STATE_FILE"
}

# Holé "manifest unknown" z Dockeru neřekne, který image chybí ani proč.
#
# Když aplikace nemá image v požadované verzi (typicky proto, že se
# nezměnila a netagovala se), přeznačí se poslední dostupná verze —
# obě služby pak běží pod jedním číslem a nemusí se hlídat zvlášť.
# Děje se to jen lokálně, do registru se nic neodesílá.
pull_checked() {
    local image="$1" label="$2"

    if $DRY_RUN; then
        echo -e "   ${YELLOW}[dry-run]${NC} docker pull $image"
        return 0
    fi

    if docker pull "$image" 2>/dev/null; then
        return 0
    fi

    # Image v registru není — zkusíme ho doplnit přeznačením.
    local repo="${image%:*}" want="${image##*:}"
    local fallback
    fallback="$(docker images "$repo" --format '{{.Tag}}' 2>/dev/null \
        | grep -vE '^(latest|<none>)$' | sort -Vr | head -1)"

    # Rovnost by znamenala, že image je lokálně a jen se nestáhl —
    # hlásit "přeznačuji z 2.0.2 na 2.0.2" by mátlo.
    if [[ -n "$fallback" && "$fallback" != "$want" ]]; then
        log_warn "$label nemá verzi $want — přeznačuji z $fallback."
        docker tag "$repo:$fallback" "$image" && {
            log_info "Hotovo: $image (kód z verze $fallback)"
            return 0
        }
    elif [[ "$fallback" == "$want" ]]; then
        log_info "$label: verze $want je už lokálně."
        return 0
    fi

    log_error "Image pro $label neexistuje: $image"
    log_warn  "Ověřte, že build pro tuto verzi proběhl:"
    echo     "    https://github.com/michalvarys/uat-${label/backend/admin-v4}/actions"
    log_warn  "Nebo doplňte verzi ručně:"
    echo     "    ./scripts/sync-tag.sh $want --from <existující verze>"
    exit 1
}

pull_and_up() {
    log_step "Stahuji image"

    # Tag z příkazové řádky přebíjí hodnotu v env souboru. --tag platí pro
    # obě služby, --tag-frontend/--tag-backend jen pro jednu — aplikace
    # se často vydávají zvlášť a ne každá verze existuje u obou.
    [[ -n "$TAG" ]] && { export FRONTEND_TAG="$TAG"; export BACKEND_TAG="$TAG"; }
    [[ -n "$TAG_FRONTEND" ]] && export FRONTEND_TAG="$TAG_FRONTEND"
    [[ -n "$TAG_BACKEND"  ]] && export BACKEND_TAG="$TAG_BACKEND"

    local be_image fe_image
    be_image="${BACKEND_IMAGE:-ghcr.io/michalvarys/uat-admin}:${BACKEND_TAG:-latest}"
    fe_image="${FRONTEND_IMAGE:-ghcr.io/michalvarys/uat-frontend}:${FRONTEND_TAG:-latest}"

    $DO_BACKEND  && pull_checked "$be_image" "backend"
    $DO_FRONTEND && pull_checked "$fe_image" "frontend"

    log_step "Startuji služby"

    # Backend jde první: frontend se ptá na jeho API a při startu
    # by zbytečně logoval chyby.
    if $DO_BACKEND; then
        run dc up -d --force-recreate strapi
        wait_for_http "Backend" "http://127.0.0.1:${BE_PORT}/admin" 40 || true
    fi

    $DO_FRONTEND && run dc up -d --force-recreate frontend
    true
}

verify() {
    log_step "Ověření"

    local failed=false

    if $DO_FRONTEND && ! $DRY_RUN; then
        # Ověřuje se přímo kontejner, ne veřejná doména: nasazení má
        # projít i dřív, než je v aaPanelu hotová reverse proxy.
        wait_for_http "Frontend" "http://127.0.0.1:${FE_PORT}/" 40 || failed=true

        # Kontrola, že se obsah renderuje na serveru. Prázdná slupka
        # vrací 200, ale pro vyhledávače je bezcenná.
        # grep -c na prázdném vstupu vrací nenulový kód a `|| echo 0`
        # pak přilepí druhý řádek — porovnání níž na tom padalo.
        local h1
        h1="$(curl -s -m 15 "http://127.0.0.1:${FE_PORT}/" 2>/dev/null | grep -c '<h1' | head -1 | tr -cd '0-9')"
        h1="${h1:-0}"
        if [[ "$h1" -ge 1 ]]; then
            log_info "Server-side rendering funguje."
        else
            log_warn "V HTML není <h1> — ověřte rendering."
        fi
    fi

    if $failed; then
        log_error "Ověření selhalo."
        log_warn  "Návrat: ./scripts/deploy.sh --env $ENVIRONMENT --rollback"
        return 1
    fi

    log_info "Vše odpovídá."
}

rollback() {
    log_step "Návrat na předchozí verzi ($ENVIRONMENT)"

    [[ -f "$STATE_FILE" ]] || { log_error "Chybí $STATE_FILE — není kam se vrátit."; exit 1; }

    # shellcheck disable=SC1090
    source "$STATE_FILE"
    log_info "Uložený stav z: ${SAVED_AT:-?}"

    [[ -n "${BACKEND_PREV:-}" ]] && {
        log_info "Backend → $BACKEND_PREV"
        export BACKEND_IMAGE="${BACKEND_PREV%:*}" BACKEND_TAG="${BACKEND_PREV##*:}"
        run dc up -d --force-recreate strapi
    }

    [[ -n "${FRONTEND_PREV:-}" ]] && {
        log_info "Frontend → $FRONTEND_PREV"
        export FRONTEND_IMAGE="${FRONTEND_PREV%:*}" FRONTEND_TAG="${FRONTEND_PREV##*:}"
        run dc up -d --force-recreate frontend
    }

    log_warn "Databáze se nevrací — obnovte ji ze zálohy, pokud je potřeba."
    log_info "Hotovo."
}

main
