#!/usr/bin/env bash
#
# Sdílené funkce pro skripty v tomto repozitáři.
# Načítá se přes `source "$(dirname "$0")/lib.sh"`.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "\n${BLUE}==>${NC} ${1}"; }

# Kořen repozitáře — skripty se dají volat odkudkoli.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Prostředí se volí proměnnou ENV nebo přepínačem --env.
# Výchozí je staging: nasazení na produkci má být vědomé rozhodnutí.
ENVIRONMENT="${ENV:-staging}"

DRY_RUN=false

run() {
    if $DRY_RUN; then
        echo -e "   ${YELLOW}[dry-run]${NC} $*"
    else
        "$@"
    fi
}

# Zeptá se na potvrzení. V neinteraktivním běhu (CI) selže, aby
# nebezpečná operace neproběhla omylem.
confirm() {
    local prompt="$1"

    if $DRY_RUN; then
        echo -e "   ${YELLOW}[dry-run]${NC} potvrzení: $prompt"
        return 0
    fi

    # Návratové kódy se rozlišují schválně: 1 = nešlo se zeptat (chyba
    # prostředí, v CI má selhat), 2 = uživatel operaci vědomě zrušil.
    if [[ ! -t 0 ]]; then
        log_error "Tato operace vyžaduje potvrzení, ale vstup není interaktivní."
        return 1
    fi

    read -r -p "$(echo -e "${YELLOW}?${NC} $prompt [napište ANO]: ")" answer
    [[ "$answer" == "ANO" ]] || { log_warn "Zrušeno."; return 2; }
}

# --- prostředí --------------------------------------------------------------

env_file() { echo "$REPO_ROOT/env/$ENVIRONMENT.env"; }

compose_files() {
    # Základ je společný, prostředí ho jen doplňuje o domény, porty
    # a případné rozdíly v chování.
    echo "-f $REPO_ROOT/compose/base.yml -f $REPO_ROOT/compose/$ENVIRONMENT.yml"
}

# Jméno projektu odděluje sítě a kontejnery jednotlivých prostředí,
# takže staging a produkce mohou běžet na jednom stroji vedle sebe.
project_name() { echo "uat-$ENVIRONMENT"; }

load_env() {
    local file; file="$(env_file)"

    if [[ ! -f "$file" ]]; then
        log_error "Chybí konfigurace prostředí: $file"
        log_warn  "Vytvořte ji podle env/example.env"
        exit 1
    fi

    # shellcheck disable=SC1090
    set -a; source "$file"; set +a
}

dc() {
    # shellcheck disable=SC2046
    docker compose -p "$(project_name)" $(compose_files) --env-file "$(env_file)" "$@"
}

check_environment() {
    case "$ENVIRONMENT" in
        production|staging|dev) ;;
        *) log_error "Neznámé prostředí: $ENVIRONMENT (povolené: production, staging, dev)"; exit 1 ;;
    esac

    [[ -f "$REPO_ROOT/compose/$ENVIRONMENT.yml" ]] \
        || { log_error "Chybí compose/$ENVIRONMENT.yml"; exit 1; }
}

require_docker() {
    command -v docker >/dev/null || { log_error "Docker není dostupný."; exit 1; }
    docker compose version >/dev/null 2>&1 || { log_error "Chybí 'docker compose'."; exit 1; }
}

# Zpracuje přepínače společné všem skriptům. Vrací zbylé argumenty
# v poli REMAINING_ARGS, aby si je skript mohl dozpracovat sám.
REMAINING_ARGS=()
parse_common_args() {
    REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env)     ENVIRONMENT="$2"; shift 2 ;;
            --prod|--production) ENVIRONMENT="production"; shift ;;
            --staging) ENVIRONMENT="staging"; shift ;;
            --dev)     ENVIRONMENT="dev"; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            *)         REMAINING_ARGS+=("$1"); shift ;;
        esac
    done
}

# --- databáze ---------------------------------------------------------------

db_container() { echo "uat-$ENVIRONMENT-db"; }

# Dump jde přes kontejner, takže na hostiteli není potřeba psql.
pg_dump_to() {
    local target="$1"
    docker exec -e PGPASSWORD="$POSTGRESQL_PASS" "$(db_container)" \
        pg_dump -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DB" --no-owner --no-acl \
        | gzip > "$target"
}

# Prázdný nebo useknutý dump je horší než žádný — tvářil by se jako
# platná záloha, na kterou se dá spolehnout.
verify_dump() {
    local file="$1" min_size="${2:-10000}"

    [[ -f "$file" ]] || { log_error "Záloha $file neexistuje."; return 1; }

    local size; size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
    if [[ "$size" -lt "$min_size" ]]; then
        log_error "Záloha má jen ${size} B, což je podezřele málo."
        return 1
    fi

    if ! gzip -t "$file" 2>/dev/null; then
        log_error "Záloha je poškozená (gzip -t selhal)."
        return 1
    fi

    # pg_dump končí tímto řádkem; jeho absence znamená useknutý přenos.
    if ! zcat "$file" | tail -5 | grep -q "PostgreSQL database dump complete"; then
        log_error "Záloha není kompletní — chybí závěrečný řádek pg_dump."
        return 1
    fi

    log_info "Záloha ověřena ($(du -h "$file" | cut -f1))."
}

# Bitnami obraz PostgreSQL běží pod neprivilegovaným uživatelem
# (UID 1000), ne pod rootem. Docker ale nově vytvořené složky zakládá
# jako root, takže kontejner do nich nesmí zapisovat a start skončí
# na "/bitnami/postgresql/data: permission denied".
#
# Uploady patří Strapi, který v obraze běží pod UID 1001.
DB_UID=1000
DB_GID=0
UPLOADS_UID=1001
UPLOADS_GID=0

prepare_data_dirs() {
    [[ -n "${DATA_DIR:-}" ]] || { log_error "Není nastaveno DATA_DIR."; return 1; }

    log_info "Připravuji datové složky v $DATA_DIR"

    run mkdir -p "$DATA_DIR/db" "$DATA_DIR/uploads"

    if $DRY_RUN; then
        echo -e "   ${YELLOW}[dry-run]${NC} chown $DB_UID:$DB_GID $DATA_DIR/db"
        echo -e "   ${YELLOW}[dry-run]${NC} chown $UPLOADS_UID:$UPLOADS_GID $DATA_DIR/uploads"
        return 0
    fi

    # Vlastníka lze měnit jen jako root. Bez oprávnění se jen upozorní,
    # aby skript nespadl tam, kde práva už sedí.
    if [[ "$(stat -c '%u' "$DATA_DIR/db")" != "$DB_UID" ]]; then
        if ! chown -R "$DB_UID:$DB_GID" "$DATA_DIR/db" 2>/dev/null; then
            log_warn "Nelze nastavit vlastníka $DATA_DIR/db — spusťte:"
            echo    "    sudo chown -R $DB_UID:$DB_GID $DATA_DIR/db"
            return 1
        fi
    fi

    if [[ "$(stat -c '%u' "$DATA_DIR/uploads")" != "$UPLOADS_UID" ]]; then
        if ! chown -R "$UPLOADS_UID:$UPLOADS_GID" "$DATA_DIR/uploads" 2>/dev/null; then
            log_warn "Nelze nastavit vlastníka $DATA_DIR/uploads — spusťte:"
            echo    "    sudo chown -R $UPLOADS_UID:$UPLOADS_GID $DATA_DIR/uploads"
            return 1
        fi
    fi

    log_info "Složky připraveny."
}

wait_for_http() {
    local name="$1" url="$2" tries="${3:-40}"

    log_info "Čekám na $name ($url)"
    if $DRY_RUN; then
        echo -e "   ${YELLOW}[dry-run]${NC} curl $url"
        return 0
    fi

    local code=000
    for ((i = 1; i <= tries; i++)); do
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url" 2>/dev/null || echo 000)"
        [[ "$code" == "200" ]] && { log_info "$name odpovídá (po $((i * 5)) s)."; return 0; }
        sleep 5
    done

    log_error "$name neodpovídá ani po $((tries * 5)) s (poslední stav: $code)."
    return 1
}
