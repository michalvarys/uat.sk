#!/usr/bin/env bash
#
# Záloha databáze a uploadů.
#
# Použití:
#   ./scripts/backup.sh --prod              # záloha produkce
#   ./scripts/backup.sh --staging           # záloha stagingu
#   ./scripts/backup.sh --prod --with-files # včetně uploadů (pomalé, 9+ GB)
#   ./scripts/backup.sh --prod --keep 30    # ponechat posledních 30 záloh
#
# Uploady se ve výchozím stavu NEZÁLOHUJÍ při každém běhu — je jich
# 9+ GB a mění se pomalu. Použijte --with-files před rizikovou operací
# nebo si na ně nasaďte samostatný zálohovací plán.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WITH_FILES=false
KEEP=14

parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-files) WITH_FILES=true; shift ;;
        --keep)       KEEP="$2"; shift 2 ;;
        -h|--help)    sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            log_error "Neznámý přepínač: $1"; exit 1 ;;
    esac
done

check_environment
require_docker
load_env

BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups/$ENVIRONMENT}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DB_FILE="$BACKUP_DIR/db-$STAMP.sql.gz"

main() {
    log_step "Záloha prostředí: $ENVIRONMENT"

    run mkdir -p "$BACKUP_DIR"

    if ! docker ps --format '{{.Names}}' | grep -qx "$(db_container)"; then
        log_error "Databázový kontejner $(db_container) neběží."
        exit 1
    fi

    log_info "Databáze → $DB_FILE"
    if $DRY_RUN; then
        echo -e "   ${YELLOW}[dry-run]${NC} pg_dump $POSTGRESQL_DB | gzip > $DB_FILE"
    else
        pg_dump_to "$DB_FILE"
        verify_dump "$DB_FILE" || exit 1
    fi

    if $WITH_FILES; then
        local files_archive="$BACKUP_DIR/uploads-$STAMP.tar.gz"
        log_info "Uploady → $files_archive (může trvat, je jich několik GB)"
        run tar -czf "$files_archive" -C "$DATA_DIR" uploads
    else
        log_info "Uploady přeskočeny (--with-files je zapne)."
    fi

    prune

    log_step "Hotovo"
    $DRY_RUN || log_info "Nejnovější: $(ls -1t "$BACKUP_DIR"/db-*.sql.gz 2>/dev/null | head -1)"
    echo "$DB_FILE"
}

# Maže jen automatické zálohy databáze a nechává poslední KEEP kusů.
# Uploady se nemažou nikdy — jejich obnova je drahá.
prune() {
    local count
    count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'db-*.sql.gz' 2>/dev/null | wc -l | tr -d ' ')"
    count="${count:-0}"

    if [[ "$count" -le "$KEEP" ]]; then
        return
    fi

    log_info "Úklid starších záloh (ponechávám $KEEP z $count)"
    find "$BACKUP_DIR" -maxdepth 1 -name 'db-*.sql.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2- \
        | while read -r old; do
            log_info "  mažu $(basename "$old")"
            run rm -f "$old"
        done
}

main
