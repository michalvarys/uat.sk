#!/usr/bin/env bash
#
# Logy služeb ve zvoleném prostředí.
#
# Použití:
#   ./scripts/logs.sh --staging            # všechny služby
#   ./scripts/logs.sh --prod strapi        # jen backend
#   ./scripts/logs.sh --prod --tail 200

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TAIL=100
parse_common_args "$@"
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

SERVICES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tail)    TAIL="$2"; shift 2 ;;
        -h|--help) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         SERVICES+=("$1"); shift ;;
    esac
done

check_environment; require_docker; load_env
dc logs -f --tail "$TAIL" "${SERVICES[@]+"${SERVICES[@]}"}"
