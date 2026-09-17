#!/usr/bin/env bash
#
# Povýší otestovanou verzi ze stagingu na produkci.
#
# Použití:
#   ./scripts/promote.sh --as v2.0.0        # co běží na stagingu → produkce
#   ./scripts/promote.sh --as v2.0.0 --dry-run
#   ./scripts/promote.sh --check            # jen ukáže, co kde běží
#
# Na produkci jde BITOVĚ SHODNÝ image, jaký prošel testem na stagingu —
# jen se přeznačí a odešle pod novým tagem. Znovu stavět z tagu by
# znamenalo, že produkce běží jiný build než ten otestovaný.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

NEW_TAG=""
CHECK_ONLY=false

parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --as)      NEW_TAG="$2"; shift 2 ;;
        --check)   CHECK_ONLY=true; shift ;;
        -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         log_error "Neznámý přepínač: $1"; exit 1 ;;
    esac
done

require_docker

running_image() {
    docker inspect --format '{{.Config.Image}}' "uat-$1-$2" 2>/dev/null || echo ""
}

# Digest jednoznačně identifikuje obsah image — dvě různé verze mohou
# mít stejný tag, ale nikdy stejný digest.
image_digest() {
    docker inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null | cut -d@ -f2 || echo "?"
}

show_state() {
    log_step "Co kde běží"

    printf "  %-12s %-42s %s\n" "prostředí" "frontend" "backend"
    for e in staging production; do
        printf "  %-12s %-42s %s\n" "$e" \
            "$(running_image "$e" frontend || echo '-')" \
            "$(running_image "$e" backend  || echo '-')"
    done
}

main() {
    show_state

    $CHECK_ONLY && exit 0

    [[ -n "$NEW_TAG" ]] || { log_error "Chybí --as <verze>, například --as v2.0.0"; exit 1; }

    local stage_fe stage_be
    stage_fe="$(running_image staging frontend)"
    stage_be="$(running_image staging backend)"

    [[ -n "$stage_fe" && -n "$stage_be" ]] \
        || { log_error "Na stagingu neběží obě služby — není co povýšit."; exit 1; }

    log_step "Povýšení na produkci jako $NEW_TAG"
    echo "  frontend: $stage_fe"
    echo "  backend:  $stage_be"
    echo

    confirm "Odeslat tyto image jako $NEW_TAG a nasadit na produkci?" || {
        rc=$?
        # 2 = vědomé zrušení uživatelem, cokoli jiného je chyba.
        [[ $rc -eq 2 ]] && exit 0 || exit $rc
    }

    tag_and_push "$stage_fe" "varyshop/uat-frontend:$NEW_TAG"
    tag_and_push "$stage_be" "varyshop/uat-admin:$NEW_TAG"

    log_step "Nasazuji na produkci"
    run "$REPO_ROOT/scripts/deploy.sh" --prod --tag "$NEW_TAG"

    log_step "Hotovo"
    log_info "Produkce běží verzi $NEW_TAG."
    log_info "Zapište si ji do env/production.env, ať přežije restart serveru:"
    echo    "    FRONTEND_TAG=$NEW_TAG"
    echo    "    BACKEND_TAG=$NEW_TAG"
}

tag_and_push() {
    local source="$1" target="$2"

    log_info "$source → $target"
    log_info "  digest: $(image_digest "$source")"

    run docker tag "$source" "$target"
    run docker push "$target"
}

main
