#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
[[ -f "${ROOT_DIR}/inventory.env" ]] || fail "缺少 ${ROOT_DIR}/inventory.env"
# shellcheck source=../inventory.env
source "${ROOT_DIR}/inventory.env"

NODE_NAME="${1:-}"

usage() {
  cat <<'EOF'
用法:
  sudo bash scripts/deploy-node.sh node29
  sudo bash scripts/deploy-node.sh node25
  sudo bash scripts/deploy-node.sh node26
EOF
}

wait_for_container_health() {
  local container="$1"
  local timeout_seconds="${2:-180}"
  local deadline=$((SECONDS + timeout_seconds))
  local state=""
  local health=""

  while (( SECONDS < deadline )); do
    state="$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}" 2>/dev/null || true)"

    if [[ "${state}" == "running" && ( "${health}" == "healthy" || "${health}" == "none" ) ]]; then
      return 0
    fi

    if [[ "${state}" == "exited" || "${state}" == "dead" ]]; then
      docker logs --tail 200 "${container}" >&2 || true
      fail "容器异常退出: ${container}"
    fi

    sleep 3
  done

  docker ps -a --filter "name=^/${container}$" >&2 || true
  docker logs --tail 200 "${container}" >&2 || true
  fail "容器在预期时间内未就绪: ${container}"
}

main() {
  local compose_file

  case "${NODE_NAME}" in
    node29|node25|node26) ;;
    *)
      usage
      fail "未知节点标识: ${NODE_NAME:-<empty>}"
      ;;
  esac

  require_root
  compose_file="${ROOT_DIR}/compose/${NODE_NAME}/docker-compose.yml"
  [[ -f "${compose_file}" ]] || fail "找不到 compose 文件: ${compose_file}"

  if [[ "${SKIP_DOCKER_PULL:-false}" == "true" ]]; then
    log "跳过镜像拉取（SKIP_DOCKER_PULL=true）"
  else
    docker compose --env-file "${ROOT_DIR}/inventory.env" -f "${compose_file}" pull
  fi
  docker compose --env-file "${ROOT_DIR}/inventory.env" -f "${compose_file}" up -d
  docker compose --env-file "${ROOT_DIR}/inventory.env" -f "${compose_file}" ps

  if [[ "${NODE_NAME}" == "node29" ]]; then
    wait_for_container_health postgres-node29 180
  fi
}

main "$@"
