#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
[[ -f "${ROOT_DIR}/inventory.env" ]] || fail "缺少 ${ROOT_DIR}/inventory.env"
# shellcheck source=../inventory.env
source "${ROOT_DIR}/inventory.env"

require_local_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少本地命令: $1"
}

remote_target() {
  local host="$1"
  printf '%s@%s' "${SSH_USER}" "${host}"
}

ssh_opts() {
  printf '%s' "-p ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
}

bundle_paths() {
  local item

  for item in \
    compose \
    scripts \
    README.md \
    inventory.env \
    inventory.env.example; do
    [[ -e "${ROOT_DIR}/${item}" ]] && printf '%s\n' "${item}"
  done
}

sync_bundle() {
  local host="$1"
  local target
  local bundle_items=()

  target="$(remote_target "${host}")"
  log "同步部署目录到 ${host}"

  mapfile -t bundle_items < <(bundle_paths)
  (( ${#bundle_items[@]} > 0 )) || fail "没有可同步的部署文件"

  tar \
    -czf - \
    -C "${ROOT_DIR}" \
    "${bundle_items[@]}" \
    | ssh $(ssh_opts) "${target}" "sudo mkdir -p '${REMOTE_BASE_DIR}' && sudo tar xzf - -C '${REMOTE_BASE_DIR}'"

  log "部署目录同步完成: ${host}"
}

run_remote() {
  local host="$1"
  shift
  ssh $(ssh_opts) "$(remote_target "${host}")" "$*"
}

initialize_remote_node() {
  local host="$1"
  local node_name="$2"

  sync_bundle "${host}"
  log "初始化节点 ${node_name} (${host})"
  run_remote "${host}" "cd '${REMOTE_BASE_DIR}' && sudo bash scripts/init-node.sh ${node_name}"
}

deploy_remote_node() {
  local host="$1"
  local node_name="$2"

  log "准备节点 ${node_name} (${host})"
  run_remote "${host}" "cd '${REMOTE_BASE_DIR}' && sudo bash scripts/prepare-host.sh ${node_name}"
  log "启动节点 ${node_name} (${host})"
  run_remote "${host}" "cd '${REMOTE_BASE_DIR}' && sudo bash scripts/deploy-node.sh ${node_name}"
}

main() {
  require_local_bin ssh
  require_local_bin tar
  require_env \
    SSH_USER SSH_PORT REMOTE_BASE_DIR \
    DB_NODE GITLAB_NODE_1 GITLAB_NODE_2

  initialize_remote_node "${DB_NODE}" node29
  initialize_remote_node "${GITLAB_NODE_1}" node25
  initialize_remote_node "${GITLAB_NODE_2}" node26

  deploy_remote_node "${DB_NODE}" node29
  deploy_remote_node "${GITLAB_NODE_1}" node25

  log "等待 node25 生成公共密钥与密文"
  run_remote "${GITLAB_NODE_1}" "cd '${REMOTE_BASE_DIR}' && sudo bash scripts/bootstrap-primary.sh node25"

  deploy_remote_node "${GITLAB_NODE_2}" node26
  log "部署完成"
}

main "$@"
