#!/usr/bin/env bash
#
# Sjednotí verzi obou aplikací přeznačením existujícího image.
#
# Když se jedna aplikace nezměnila, nemá v registru image s novou verzí
# a nasazení skončí na "manifest unknown". Skript vezme poslední dostupnou
# verzi a přeznačí ji — vznikne bitově shodný image pod novým tagem,
# bez nového buildu.
#
# Přeznačuje se jen lokálně — do registru se nic neodesílá. Kontejner
# běží z lokálního image, takže push není potřeba a odpadá i požadavek
# na zapisovací oprávnění k balíčkům.
#
# Použití:
#   ./scripts/sync-tag.sh 2.0.1              # doplní chybějící image
#   ./scripts/sync-tag.sh 2.0.1 --from 2.0.0 # přeznačí z konkrétní verze
#   ./scripts/sync-tag.sh 2.0.1 --push       # navíc odešle do registru
#   ./scripts/sync-tag.sh --check 2.0.1      # jen ověří, co chybí
#
# Pozor: git tag v repozitáři pak na tuto verzi ukazovat nebude —
# image nese kód z verze, ze které se přeznačilo.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/michalvarys/uat-frontend}"
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/michalvarys/uat-admin}"

TARGET_TAG=""
FROM_TAG=""
CHECK_ONLY=false
DO_PUSH=false

parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)    FROM_TAG="$2"; shift 2 ;;
        --check)   CHECK_ONLY=true; shift ;;
        --push)    DO_PUSH=true; shift ;;
        -h|--help) sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        log_error "Neznámý přepínač: $1"; exit 1 ;;
        *)         TARGET_TAG="$1"; shift ;;
    esac
done

require_docker

[[ -n "$TARGET_TAG" ]] || { log_error "Chybí cílová verze, například: ./scripts/sync-tag.sh 2.0.1"; exit 1; }

# Lokální image stačí — kontejner se z něj spustí i bez registru.
tag_exists_locally() {
    docker image inspect "$1:$2" >/dev/null 2>&1
}

# V registru se ověřuje manifestem, aby se nemusel stahovat celý image.
tag_exists_remotely() {
    docker manifest inspect "$1:$2" >/dev/null 2>&1
}

tag_exists() {
    tag_exists_locally "$1" "$2" || tag_exists_remotely "$1" "$2"
}

# Nejnovější dostupná verze jako výchozí zdroj přeznačení. Bere se
# z lokálně stažených image — do registru bez read:packages nevidíme.
latest_local_tag() {
    docker images "$1" --format '{{.Tag}}' 2>/dev/null \
        | grep -vE '^(latest|<none>)$' | sort -Vr | head -1
}

retag() {
    local image="$1" label="$2"

    if tag_exists "$image" "$TARGET_TAG"; then
        log_info "$label už verzi $TARGET_TAG má — nechávám být."
        return 0
    fi

    local source_tag="$FROM_TAG"
    if [[ -z "$source_tag" ]]; then
        source_tag="$(latest_local_tag "$image")"
        [[ -n "$source_tag" ]] || {
            log_error "$label: nevím, z čeho přeznačit. Doplňte --from <verze>."
            return 1
        }
        log_info "$label: zdroj neurčen, beru poslední známou verzi $source_tag"
    fi

    if ! tag_exists "$image" "$source_tag"; then
        log_error "$label: zdrojová verze $source_tag v registru neexistuje."
        return 1
    fi

    log_info "$label: $source_tag → $TARGET_TAG"

    tag_exists_locally "$image" "$source_tag" || run docker pull "$image:$source_tag"
    run docker tag "$image:$source_tag" "$image:$TARGET_TAG"

    if $DO_PUSH; then
        run docker push "$image:$TARGET_TAG"
    else
        log_info "  (jen lokálně; --push odešle i do registru)"
    fi
}

check() {
    log_step "Kontrola verze $TARGET_TAG"

    local missing=()
    for pair in "$FRONTEND_IMAGE:frontend" "$BACKEND_IMAGE:backend"; do
        local image="${pair%:*}" label="${pair##*:}"
        if tag_exists_locally "$image" "$TARGET_TAG"; then
            printf "  ${GREEN}●${NC} %-10s %s (lokálně)\n" "$label" "$image:$TARGET_TAG"
        elif tag_exists_remotely "$image" "$TARGET_TAG"; then
            printf "  ${GREEN}●${NC} %-10s %s (registr)\n" "$label" "$image:$TARGET_TAG"
        else
            printf "  ${RED}○${NC} %-10s chybí\n" "$label"
            missing+=("$label")
        fi
    done

    echo
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Obě aplikace verzi $TARGET_TAG mají."
        return 0
    fi

    log_warn "Chybí: ${missing[*]}"
    return 1
}

main() {
    if $CHECK_ONLY; then
        check
        exit $?
    fi

    log_step "Sjednocení verze na $TARGET_TAG"

    retag "$FRONTEND_IMAGE" "frontend" || exit 1
    retag "$BACKEND_IMAGE"  "backend"  || exit 1

    echo
    check || true

    log_step "Hotovo"
    log_info "Nasazení: ./scripts/deploy.sh --staging --tag $TARGET_TAG"
    log_warn "Přeznačený image nese kód ze zdrojové verze — git tag na něj neukazuje."
}

main
