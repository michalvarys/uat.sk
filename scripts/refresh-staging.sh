#!/usr/bin/env bash
#
# Obnoví staging z aktuálních produkčních dat.
#
# Použití:
#   ./scripts/refresh-staging.sh                  # čerstvá záloha produkce
#   ./scripts/refresh-staging.sh --from <soubor>  # z konkrétní zálohy
#   ./scripts/refresh-staging.sh --with-files     # i uploady (9+ GB, pomalé)
#   ./scripts/refresh-staging.sh --dry-run
#
# Přepíše staging databázi. Rozdělaná testovací data se ztratí, proto
# se skript ptá na potvrzení.
#
# Uploady se ve výchozím stavu nekopírují — je jich 9+ GB. Staging
# místo toho sahá na produkční soubory jen pro čtení (viz --with-files).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FROM_FILE=""
WITH_FILES=false

parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)       FROM_FILE="$2"; shift 2 ;;
        --with-files) WITH_FILES=true; shift ;;
        -h|--help)    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            log_error "Neznámý přepínač: $1"; exit 1 ;;
    esac
done

require_docker

PROD_ENV="$REPO_ROOT/env/production.env"
STAGING_ENV="$REPO_ROOT/env/staging.env"

[[ -f "$PROD_ENV" ]]    || { log_error "Chybí $PROD_ENV";    exit 1; }
[[ -f "$STAGING_ENV" ]] || { log_error "Chybí $STAGING_ENV"; exit 1; }

main() {
    log_step "Obnova stagingu z produkce"

    confirm "Staging databáze bude přepsána produkčními daty. Pokračovat?" || {
        rc=$?
        # 2 = vědomé zrušení uživatelem, cokoli jiného je chyba.
        [[ $rc -eq 2 ]] && exit 0 || exit $rc
    }

    local dump
    if [[ -n "$FROM_FILE" ]]; then
        [[ -f "$FROM_FILE" ]] || { log_error "Soubor $FROM_FILE neexistuje."; exit 1; }
        dump="$FROM_FILE"
        log_info "Používám zálohu: $dump"
        verify_dump "$dump" || exit 1
    else
        log_info "Pořizuji čerstvou zálohu produkce"
        dump="$(ENV=production "$REPO_ROOT/scripts/backup.sh" --prod | tail -1)"
        [[ -f "$dump" ]] || { log_error "Záloha se nevytvořila."; exit 1; }
    fi

    restore_db "$dump"
    $WITH_FILES && sync_files || log_info "Uploady přeskočeny (--with-files je zapne)."
    post_restore

    log_step "Hotovo"
    # shellcheck disable=SC1090
    source "$STAGING_ENV"
    log_info "Staging: https://${FE_DOMAIN}"
    log_info "Admin:   https://${BE_DOMAIN}/admin"
}

restore_db() {
    local dump="$1"

    log_step "Nahrávám data do stagingu"

    ENVIRONMENT="staging"
    load_env

    local container; container="$(db_container)"

    if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
        log_error "Staging databáze ($container) neběží. Spusťte: ./scripts/deploy.sh --staging"
        exit 1
    fi

    # Backend se zastaví, aby během obnovy nesahal na databázi.
    log_info "Zastavuji staging backend"
    run dc stop strapi frontend

    log_info "Mažu staging databázi a vytvářím prázdnou"
    if ! $DRY_RUN; then
        docker exec -e PGPASSWORD="$POSTGRESQL_PASS" "$container" \
            psql -U "$POSTGRESQL_USER" -d postgres \
            -c "DROP DATABASE IF EXISTS \"$POSTGRESQL_DB\";" >/dev/null
        docker exec -e PGPASSWORD="$POSTGRESQL_PASS" "$container" \
            psql -U "$POSTGRESQL_USER" -d postgres \
            -c "CREATE DATABASE \"$POSTGRESQL_DB\" OWNER \"$POSTGRESQL_USER\";" >/dev/null
    else
        echo -e "   ${YELLOW}[dry-run]${NC} DROP + CREATE DATABASE $POSTGRESQL_DB"
    fi

    log_info "Importuji zálohu (může trvat několik minut)"
    if ! $DRY_RUN; then
        zcat "$dump" | docker exec -i -e PGPASSWORD="$POSTGRESQL_PASS" "$container" \
            psql -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DB" -q >/dev/null
        log_info "Data nahrána."
    else
        echo -e "   ${YELLOW}[dry-run]${NC} zcat $dump | psql"
    fi
}

sync_files() {
    log_step "Kopíruji uploady"

    local prod_dir staging_dir
    prod_dir="$(grep -oP '^DATA_DIR=\K.*' "$PROD_ENV")/uploads"
    staging_dir="$DATA_DIR/uploads"

    [[ -d "$prod_dir" ]] || { log_warn "Produkční uploady ($prod_dir) nenalezeny, přeskakuji."; return; }

    log_info "$prod_dir → $staging_dir"
    # --delete drží staging přesnou kopií; bez něj by se hromadily
    # soubory smazané mezitím na produkci.
    run rsync -a --delete "$prod_dir/" "$staging_dir/"
}

post_restore() {
    log_step "Úpravy pro staging"

    # Produkční data obsahují administrátorské účty a API tokeny.
    # Na stagingu zůstávají funkční schválně, aby se dalo testovat
    # s reálným obsahem — proto je staging chráněný heslem v Traefiku.
    log_info "Administrátorské účty zůstávají z produkce (staging je za heslem)."

    log_info "Startuji staging služby"
    run dc up -d

    wait_for_http "Staging backend" "http://localhost:1337/admin" 40 || true
}

main
