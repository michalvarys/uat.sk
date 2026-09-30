#!/usr/bin/env bash
#
# Doplní chybějící vazby mezi jazykovými verzemi obsahu.
#
# Použití:
#   ./scripts/fix-localizations.sh --staging --dry-run   # jen ukáže, co by udělal
#   ./scripts/fix-localizations.sh --staging             # zapíše vazby
#   ./scripts/fix-localizations.sh --prod
#
# Proč: záznamy v angličtině nevznikly tlačítkem „Add new locale", ale
# ručně jako nové položky. Strapi vazbu zapisuje jen při vytvoření
# překladu, takže tabulky *_localizations_links zůstaly prázdné.
# Přepínač jazyka pak na detailu stránky nemá podle čeho najít
# protějšek a zůstane na původní jazykové verzi.
#
# Co se páruje a podle čeho:
#   obory       podle kódu oboru (code) — spolehlivé, kód je stejný
#   pedagogové  podle jména a příjmení — 28 dvojic, žádná víceznačná
#
# Stránky, novinky a akce se nepárují: slugy i názvy jsou přeložené
# a žádný společný klíč neexistuje. Ty je potřeba propojit ručně
# v administraci.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         log_error "Neznámý přepínač: $1"; exit 1 ;;
    esac
done

check_environment
require_docker
load_env

if ! db_is_running; then
    log_error "Databáze $(db_container) neběží."
    exit 1
fi

db() {
    docker exec -i "$(db_container)" \
        env PGPASSWORD="$POSTGRESQL_PASS" \
        psql -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DB" -v ON_ERROR_STOP=1 "$@"
}

# Vazba je obousměrná: Strapi čeká záznam v obou směrech, jinak se
# překlad zobrazí jen z jedné strany.
#
# U duplicitních anglických záznamů se bere ten novější: starší z roku
# 2022 jsou prázdné skořápky bez obsahu, novější z 2024 mají bloky.
SQL_STUDIES="
WITH parovani AS (
    SELECT sk.id AS sk_id,
           (SELECT en.id FROM field_of_studies en
             WHERE en.locale = 'en' AND en.code = sk.code
             ORDER BY en.published_at DESC NULLS LAST, en.id DESC
             LIMIT 1) AS en_id
    FROM field_of_studies sk
    WHERE sk.locale = 'sk' AND sk.code IS NOT NULL
)
INSERT INTO field_of_studies_localizations_links (field_of_study_id, inv_field_of_study_id)
SELECT sk_id, en_id FROM parovani WHERE en_id IS NOT NULL
UNION ALL
SELECT en_id, sk_id FROM parovani WHERE en_id IS NOT NULL
ON CONFLICT DO NOTHING;
"

SQL_TEACHERS="
WITH parovani AS (
    SELECT sk.id AS sk_id,
           (SELECT en.id FROM teachers en
             WHERE en.locale = 'en'
               AND lower(trim(en.firstname)) = lower(trim(sk.firstname))
               AND lower(trim(en.surname))   = lower(trim(sk.surname))
             ORDER BY en.id LIMIT 1) AS en_id
    FROM teachers sk
    WHERE sk.locale = 'sk'
)
INSERT INTO teachers_localizations_links (teacher_id, inv_teacher_id)
SELECT sk_id, en_id FROM parovani WHERE en_id IS NOT NULL
UNION ALL
SELECT en_id, sk_id FROM parovani WHERE en_id IS NOT NULL
ON CONFLICT DO NOTHING;
"

prehled() {
    log_step "Stav vazeb"
    db -c "
SELECT 'obory'      AS typ, count(*) AS vazeb FROM field_of_studies_localizations_links
UNION ALL
SELECT 'pedagogove', count(*) FROM teachers_localizations_links
UNION ALL
SELECT 'stranky',    count(*) FROM pages_localizations_links
UNION ALL
SELECT 'novinky',    count(*) FROM news_localizations_links;"
}

navrh() {
    log_step "Co se spáruje"

    log_info "Obory (podle kódu):"
    db -c "
SELECT sk.code,
       sk.id AS sk_id, left(sk.name, 24) AS sk_nazev,
       (SELECT en.id FROM field_of_studies en
         WHERE en.locale='en' AND en.code=sk.code
         ORDER BY en.published_at DESC NULLS LAST, en.id DESC LIMIT 1) AS en_id,
       (SELECT left(en.name,24) FROM field_of_studies en
         WHERE en.locale='en' AND en.code=sk.code
         ORDER BY en.published_at DESC NULLS LAST, en.id DESC LIMIT 1) AS en_nazev
FROM field_of_studies sk WHERE sk.locale='sk' ORDER BY sk.code;"

    log_info "Pedagogové (podle jména):"
    db -t -c "
SELECT count(*) || ' dvojic'
FROM teachers sk
WHERE sk.locale='sk' AND EXISTS (
    SELECT 1 FROM teachers en WHERE en.locale='en'
      AND lower(trim(en.firstname))=lower(trim(sk.firstname))
      AND lower(trim(en.surname))=lower(trim(sk.surname)));"
}

main() {
    prehled
    navrh

    if $DRY_RUN; then
        log_warn "Režim dry-run — nic se nezapsalo."
        return
    fi

    confirm "Zapsat vazby do databáze prostředí $ENVIRONMENT?" || {
        rc=$?
        [[ $rc -eq 2 ]] && exit 0 || exit $rc
    }

    log_step "Zápis vazeb"

    # Obojí v jedné transakci: buď projde všechno, nebo nic.
    printf 'BEGIN;\n%s\n%s\nCOMMIT;\n' "$SQL_STUDIES" "$SQL_TEACHERS" | db

    prehled

    log_step "Hotovo"
    log_warn "Stránky, novinky a akce se spárovat nedaly — přeložené slugy"
    log_warn "a názvy nemají společný klíč. Propojte je ručně v administraci."
    log_info "Restartujte backend, aby se změna projevila: ./scripts/deploy.sh --$ENVIRONMENT --backend"
}

main
