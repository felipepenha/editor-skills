#!/usr/bin/env bash
# overleaf-ctl.sh - Management CLI for building and running Overleaf Community Edition via Podman or Docker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_PORT=8080
DEFAULT_IMAGE="docker.io/sharelatex/sharelatex:latest"
DEFAULT_MONGO_IMAGE="docker.io/library/mongo:8.0"
DEFAULT_REDIS_IMAGE="docker.io/library/redis:7-alpine"
DEFAULT_STACK_NAME="overleaf"
DEFAULT_MODE="pod"

usage() {
  cat <<'EOF'
overleaf-ctl.sh - Build and manage Overleaf Community Edition on Podman or Docker

USAGE:
  overleaf-ctl.sh <command> [options]

COMMANDS:
  build             Build a custom Overleaf image with extended TeX Live / tools
  up                Start the Overleaf stack (Overleaf, MongoDB, Redis)
  down              Stop and remove the Overleaf stack (preserves volumes)
  status            Show stack status, container health, and endpoint reachability
  logs [service]    View logs (services: server, mongo, redis, or all; default: server)
  create-admin      Create an initial administrator user and generate password link
  install-pkg       Install TeX Live package(s) inside the running Overleaf container
  shell             Open an interactive bash shell inside the Overleaf container
  clean             Remove containers, pods, and optionally delete volumes

OPTIONS FOR 'build':
  --full                Install complete TeX Live distribution (scheme-full)
  --recommended         Install recommended collections (default)
  --tag <tag>           Tag for the built image (default: overleaf-custom:latest)
  --file <path>         Path to Containerfile/Dockerfile (default: resources/Containerfile)
  --platform <platform> Target platform architecture (e.g. linux/amd64, linux/arm64)

OPTIONS FOR 'up':
  --port <port>         Host port to expose Overleaf on (default: 8080)
  --image <image>       Overleaf container image to use (default: sharelatex/sharelatex:latest)
  --mode <mode>         Deployment mode: 'pod' (Podman only) or 'network' (default: pod for Podman, network for Docker)
  --name <name>         Base name for pod/containers (default: overleaf)
  --mongo <image>       MongoDB image (default: mongo:8.0)
  --redis <image>       Redis image (default: redis:7-alpine)
  --platform <platform> Container platform override (optional, e.g. linux/amd64)

OPTIONS FOR 'create-admin':
  --email <email>   Administrator email address (required)

OPTIONS FOR 'clean':
  --volumes         Also delete named data volumes (DATA WILL BE LOST)

RUNTIME DETECTION:
  Automatically detects and prefers 'podman' when available. If 'podman' is not
  present or its daemon is unresponsive, falls back to 'docker'. You can explicitly
  override the container engine by setting CONTAINER_CLI=podman or CONTAINER_CLI=docker.

EXAMPLES:
  # 1. Start Overleaf on port 8080
  overleaf-ctl.sh up --port 8080

  # 2. Build custom image with full TeX Live packages
  overleaf-ctl.sh build --full --tag overleaf-full:latest

  # 3. Start stack using the custom built image
  overleaf-ctl.sh up --port 8080 --image overleaf-full:latest

  # 4. Create first admin user
  overleaf-ctl.sh create-admin --email admin@example.com

  # 5. Check stack health and endpoint
  overleaf-ctl.sh status

  # 6. Install extra TeX package on the fly
  overleaf-ctl.sh install-pkg minted latexmk
EOF
}

check_container_engine() {
  if [[ -n "${CONTAINER_CLI:-}" ]]; then
    CONTAINER_ENGINE="${CONTAINER_CLI}"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
  else
    echo "Error: Neither 'podman' nor 'docker' command found on PATH." >&2
    echo "Please install Podman (prioritized) or Docker first." >&2
    exit 1
  fi

  # Validate that the selected container engine is responsive
  if ! "${CONTAINER_ENGINE}" info >/dev/null 2>&1; then
    # If podman was chosen because both are present, but podman daemon/machine is down while docker is up, fallback to docker
    if [[ "${CONTAINER_ENGINE}" == "podman" && -z "${CONTAINER_CLI:-}" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      echo "Notice: 'podman' found but engine/machine is unresponsive. Falling back to active 'docker' daemon..." >&2
      CONTAINER_ENGINE="docker"
    else
      echo "Error: Container engine '${CONTAINER_ENGINE}' is not responding or daemon is stopped." >&2
      if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
        echo "Hint: Ensure your Podman machine or service is started (e.g., 'podman machine start')." >&2
      else
        echo "Hint: Ensure Docker Desktop or dockerd daemon is running." >&2
      fi
      exit 1
    fi
  fi
  export CONTAINER_ENGINE
}

container_exists() {
  local name="$1"
  if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    podman container exists "$name" 2>/dev/null
  else
    docker container inspect "$name" >/dev/null 2>&1
  fi
}

volume_exists() {
  local name="$1"
  if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    podman volume exists "$name" 2>/dev/null
  else
    docker volume inspect "$name" >/dev/null 2>&1
  fi
}

image_exists() {
  local name="$1"
  if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    podman image exists "$name" 2>/dev/null
  else
    docker image inspect "$name" >/dev/null 2>&1
  fi
}

network_exists() {
  local name="$1"
  if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    podman network exists "$name" 2>/dev/null
  else
    docker network inspect "$name" >/dev/null 2>&1
  fi
}

pod_exists() {
  local name="$1"
  if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    podman pod exists "$name" 2>/dev/null
  else
    return 1
  fi
}

cmd_build() {
  check_container_engine
  local profile="recommended"
  local tag="overleaf-custom:latest"
  local containerfile="${SKILL_ROOT}/resources/Containerfile"
  local platform=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full)
        profile="full"
        shift
        ;;
      --recommended)
        profile="recommended"
        shift
        ;;
      --tag)
        tag="$2"
        shift 2
        ;;
      --file)
        containerfile="$2"
        shift 2
        ;;
      --platform)
        platform="$2"
        shift 2
        ;;
      *)
        echo "Unknown option for build: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ ! -f "$containerfile" ]]; then
    echo "Error: Containerfile not found at: $containerfile" >&2
    exit 1
  fi

  echo "============================================================"
  echo " Building Overleaf Community Edition Image (${CONTAINER_ENGINE})"
  echo " Tag:              ${tag}"
  echo " TeX Live Profile: ${profile}"
  echo " Containerfile:    ${containerfile}"
  [[ -n "$platform" ]] && echo " Platform:         ${platform}"
  echo "============================================================"

  local build_cmd=("${CONTAINER_ENGINE}" build)
  if [[ -n "$platform" ]]; then
    build_cmd+=("--platform" "$platform")
  fi

  "${build_cmd[@]}" \
    --build-arg "TEXLIVE_PROFILE=${profile}" \
    -t "${tag}" \
    -f "${containerfile}" \
    "${SKILL_ROOT}/resources"

  echo "==> Build successful! Image tagged as: ${tag}"
}

cmd_up() {
  check_container_engine
  local port="${DEFAULT_PORT}"
  local image="${DEFAULT_IMAGE}"
  local mongo_image="${DEFAULT_MONGO_IMAGE}"
  local redis_image="${DEFAULT_REDIS_IMAGE}"
  local name="${DEFAULT_STACK_NAME}"
  local mode="${DEFAULT_MODE}"
  local platform=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        port="$2"
        shift 2
        ;;
      --image)
        image="$2"
        shift 2
        ;;
      --mongo)
        mongo_image="$2"
        shift 2
        ;;
      --redis)
        redis_image="$2"
        shift 2
        ;;
      --name)
        name="$2"
        shift 2
        ;;
      --mode)
        mode="$2"
        shift 2
        ;;
      --platform)
        platform="$2"
        shift 2
        ;;
      *)
        echo "Unknown option for up: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  # Docker engine does not have native pods, fallback to network mode
  if [[ "${CONTAINER_ENGINE}" == "docker" && "$mode" == "pod" ]]; then
    echo "==> Notice: Docker engine does not support native pods. Using network mode."
    mode="network"
  fi

  # Create named persistent volumes if they do not exist
  echo "==> Ensuring persistent named volumes exist..."
  for vol in "${name}_data" "${name}_mongo_data" "${name}_redis_data"; do
    if ! volume_exists "$vol"; then
      echo "  Creating volume: $vol"
      "${CONTAINER_ENGINE}" volume create "$vol" >/dev/null
    fi
  done

  # Ensure the image is available locally with architecture fallback
  if ! image_exists "${image}"; then
    echo "==> Ensuring image '${image}' is available..."
    if [[ -n "$platform" ]]; then
      "${CONTAINER_ENGINE}" pull --platform "$platform" "${image}"
    else
      if ! "${CONTAINER_ENGINE}" pull "${image}" 2>/dev/null; then
        echo "==> Native architecture image not found upstream. Retrying with --platform linux/amd64..."
        platform="linux/amd64"
        "${CONTAINER_ENGINE}" pull --platform linux/amd64 "${image}"
      fi
    fi
  fi

  local run_server_cmd=("${CONTAINER_ENGINE}" run -d)
  if [[ -n "$platform" ]]; then
    run_server_cmd+=("--platform" "$platform")
  fi

  # Ensure persistent secret for OVERLEAF_INVITE_TOKEN_SECRET
  local secret_file="${SKILL_ROOT}/.secret_invite_token"
  if [[ -z "${OVERLEAF_INVITE_TOKEN_SECRET:-}" ]]; then
    if [[ ! -f "$secret_file" ]]; then
      if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32 > "$secret_file"
      else
        cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1 > "$secret_file"
      fi
      chmod 600 "$secret_file"
    fi
    OVERLEAF_INVITE_TOKEN_SECRET="$(cat "$secret_file")"
  fi

  if [[ "$mode" == "pod" ]]; then
    local pod_name="${name}-pod"
    local mongo_name="${name}-mongo"
    local redis_name="${name}-redis"
    local server_name="${name}-server"

    echo "============================================================"
    echo " Starting Overleaf in Pod Mode (Podman, Pod: ${pod_name})"
    echo " Port Endpoint: http://localhost:${port}"
    echo " Image:         ${image}"
    echo "============================================================"

    # 1. Create Pod if not exists
    if pod_exists "${pod_name}"; then
      echo "==> Pod '${pod_name}' already exists. Stopping and recreating to ensure fresh port config..."
      podman pod rm -f "${pod_name}" >/dev/null 2>&1 || true
    fi

    echo "==> Creating pod '${pod_name}' with port mapping 0.0.0.0:${port}->80..."
    podman pod create --name "${pod_name}" -p "${port}:80" >/dev/null

    # 2. Start Redis in Pod
    echo "==> Starting Redis container '${redis_name}' in pod..."
    podman run -d --pod "${pod_name}" \
      --name "${redis_name}" \
      -v "${name}_redis_data:/data:Z" \
      "${redis_image}" \
      redis-server --appendonly yes >/dev/null

    # 3. Start MongoDB in Pod with replica set enabled
    echo "==> Starting MongoDB container '${mongo_name}' in pod..."
    podman run -d --pod "${pod_name}" \
      --name "${mongo_name}" \
      -v "${name}_mongo_data:/data/db:Z" \
      "${mongo_image}" \
      mongod --bind_ip_all --replSet overleaf >/dev/null

    # 4. Initialize MongoDB Replica Set
    "${SCRIPT_DIR}/init-replica-set.sh" "${mongo_name}" "overleaf" "127.0.0.1:27017"

    # 5. Start Overleaf Community Edition container in Pod
    echo "==> Starting Overleaf container '${server_name}' in pod..."
    "${run_server_cmd[@]}" --pod "${pod_name}" \
      --name "${server_name}" \
      -v "${name}_data:/var/lib/overleaf:Z" \
      -e "OVERLEAF_SITE_URL=http://localhost:${port}" \
      -e "OVERLEAF_NAV_TITLE=Overleaf Community Edition" \
      -e "OVERLEAF_APP_NAME=Overleaf Community Edition" \
      -e "OVERLEAF_MONGO_URL=mongodb://127.0.0.1:27017/sharelatex" \
      -e "OVERLEAF_REDIS_HOST=127.0.0.1" \
      -e "OVERLEAF_REDIS_PORT=6379" \
      -e "OVERLEAF_INVITE_TOKEN_SECRET=${OVERLEAF_INVITE_TOKEN_SECRET}" \
      -e "EMAIL_CONFIRMATION_DISABLED=true" \
      -e "ENABLE_CONVERSIONS=true" \
      -e "ENABLED_LINKED_FILE_TYPES=project_file,project_output_file" \
      "${image}" >/dev/null

  else
    # Network Mode (Works with both Docker and Podman)
    local net_name="${name}-net"
    local mongo_name="${name}-mongo"
    local redis_name="${name}-redis"
    local server_name="${name}-server"

    echo "============================================================"
    echo " Starting Overleaf in Network Mode (${CONTAINER_ENGINE}, Network: ${net_name})"
    echo " Port Endpoint: http://localhost:${port}"
    echo " Image:         ${image}"
    echo "============================================================"

    if ! network_exists "${net_name}"; then
      echo "==> Creating network: ${net_name}"
      "${CONTAINER_ENGINE}" network create "${net_name}" >/dev/null
    fi

    # Remove existing containers if any
    for c in "${server_name}" "${mongo_name}" "${redis_name}"; do
      if container_exists "$c"; then
        "${CONTAINER_ENGINE}" rm -f "$c" >/dev/null 2>&1 || true
      fi
    done

    local vol_flag=":Z"
    if [[ "${CONTAINER_ENGINE}" == "docker" ]]; then
      vol_flag=""
    fi

    # 1. Start Redis
    echo "==> Starting Redis container '${redis_name}'..."
    "${CONTAINER_ENGINE}" run -d --network "${net_name}" \
      --name "${redis_name}" \
      -v "${name}_redis_data:/data${vol_flag}" \
      "${redis_image}" \
      redis-server --appendonly yes >/dev/null

    # 2. Start Mongo
    echo "==> Starting MongoDB container '${mongo_name}'..."
    "${CONTAINER_ENGINE}" run -d --network "${net_name}" \
      --name "${mongo_name}" \
      -v "${name}_mongo_data:/data/db${vol_flag}" \
      "${mongo_image}" \
      mongod --bind_ip_all --replSet overleaf >/dev/null

    # 3. Initialize Replica Set
    "${SCRIPT_DIR}/init-replica-set.sh" "${mongo_name}" "overleaf" "${mongo_name}:27017"

    # 4. Start Overleaf
    echo "==> Starting Overleaf container '${server_name}'..."
    "${run_server_cmd[@]}" --network "${net_name}" \
      --name "${server_name}" \
      -p "${port}:80" \
      -v "${name}_data:/var/lib/overleaf${vol_flag}" \
      -e "OVERLEAF_SITE_URL=http://localhost:${port}" \
      -e "OVERLEAF_NAV_TITLE=Overleaf Community Edition" \
      -e "OVERLEAF_APP_NAME=Overleaf Community Edition" \
      -e "OVERLEAF_MONGO_URL=mongodb://${mongo_name}:27017/sharelatex" \
      -e "OVERLEAF_REDIS_HOST=${redis_name}" \
      -e "OVERLEAF_REDIS_PORT=6379" \
      -e "OVERLEAF_INVITE_TOKEN_SECRET=${OVERLEAF_INVITE_TOKEN_SECRET}" \
      -e "EMAIL_CONFIRMATION_DISABLED=true" \
      -e "ENABLE_CONVERSIONS=true" \
      -e "ENABLED_LINKED_FILE_TYPES=project_file,project_output_file" \
      "${image}" >/dev/null
  fi

  echo "==> Waiting for Overleaf service to initialize on http://localhost:${port}..."
  local endpoint_ready=false
  for i in $(seq 1 60); do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/" 2>/dev/null | grep -E "200|302|301" >/dev/null; then
      endpoint_ready=true
      break
    fi
    sleep 2
    printf "."
  done
  echo ""

  if [[ "$endpoint_ready" == "true" ]]; then
    # Automatically provision agent user for programmatic access
    local agent_email="${OVERLEAF_AGENT_EMAIL:-agent@local.overleaf}"
    local agent_password="${OVERLEAF_AGENT_PASSWORD:-0123}"
    local creds_file="${SKILL_ROOT}/.agent_credentials.json"

    echo "==> Automatically provisioning agent user '${agent_email}'..."
    "${CONTAINER_ENGINE}" exec -i -w /overleaf/services/web "${server_name}" node --input-type=module - <<EOF >/dev/null 2>&1 || true
import crypto from 'node:crypto';
import UserRegistrationHandler from './app/src/Features/User/UserRegistrationHandler.mjs';
import { User } from './app/src/models/User.mjs';

const email = '${agent_email}';
const password = '${agent_password}';

const existing = await User.findOne({ email }).exec();
if (!existing) {
  const userDetails = {
    email,
    password,
    first_name: 'Agent',
    last_name: 'AI',
    analyticsId: crypto.randomUUID()
  };
  const user = await UserRegistrationHandler.promises.registerNewUser(userDetails);
  const reversedHostname = user.email.split('@')[1].split('').reverse().join('');
  await User.updateOne(
    { _id: user._id },
    {
      \$set: {
        isAdmin: true,
        emails: [{ email, reversedHostname, confirmedAt: new Date() }]
      }
    }
  ).exec();
}
process.exit(0);
EOF

    # Persist credentials
    cat <<EOF > "$creds_file"
{
  "email": "${agent_email}",
  "password": "${agent_password}",
  "url": "http://localhost:${port}"
}
EOF
    chmod 600 "$creds_file"

    # Pre-authenticate agent session
    "${SCRIPT_DIR}/overleaf-api.sh" login --url "http://localhost:${port}" >/dev/null 2>&1 || true

    echo "============================================================"
    echo " Overleaf Community Edition is READY for Programmatic Access"
    echo "============================================================"
    echo " Container Engine:   ${CONTAINER_ENGINE}"
    echo " Web & API Endpoint: http://localhost:${port}"
    echo " Agent Account:      ${agent_email}"
    echo " Agent Credentials:  ${creds_file}"
    echo " Session Cookie:     ${SKILL_ROOT}/.session_cookie"
    echo ""
    echo " Programmatic Commands (scripts/overleaf-api.sh):"
    echo "  - List Projects:    ./scripts/overleaf-api.sh list-projects"
    echo "  - Create Project:   ./scripts/overleaf-api.sh create-project --name \"Title\""
    echo "  - Compile & PDF:    ./scripts/overleaf-api.sh compile --project-id <ID> --output paper.pdf"
    echo "  - Stack Management: ./scripts/overleaf-ctl.sh [status|logs|down]"
    echo "============================================================"
  else
    echo "==> Overleaf container is still starting up in the background."
    echo "    Check logs with: ${CONTAINER_ENGINE} logs -f ${name}-server"
  fi
}

cmd_down() {
  check_container_engine
  local name="${DEFAULT_STACK_NAME}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  echo "==> Stopping Overleaf stack '${name}' (${CONTAINER_ENGINE})..."
  local pod_name="${name}-pod"
  if pod_exists "${pod_name}"; then
    echo "  Removing pod '${pod_name}'..."
    podman pod rm -f "${pod_name}" >/dev/null 2>&1 || true
  fi

  for c in "${name}-server" "${name}-mongo" "${name}-redis"; do
    if container_exists "$c"; then
      echo "  Removing container '$c'..."
      "${CONTAINER_ENGINE}" rm -f "$c" >/dev/null 2>&1 || true
    fi
  done

  if network_exists "${name}-net"; then
    echo "  Removing network '${name}-net'..."
    "${CONTAINER_ENGINE}" network rm "${name}-net" >/dev/null 2>&1 || true
  fi

  echo "==> Stack '${name}' stopped. (Persistent volumes retained)."
}

cmd_status() {
  check_container_engine
  local name="${DEFAULT_STACK_NAME}"
  local pod_name="${name}-pod"

  echo "============================================================"
  echo " Overleaf Stack Status (Engine: ${CONTAINER_ENGINE})"
  echo "============================================================"

  if pod_exists "${pod_name}"; then
    echo "Pod: ${pod_name}"
    podman pod ps --filter "name=${pod_name}"
    echo ""
  fi

  echo "Containers:"
  "${CONTAINER_ENGINE}" ps -a --filter "name=${name}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}"
  echo ""

  # Test endpoint reachability if running
  local port="${DEFAULT_PORT}"
  if container_exists "${name}-server"; then
    echo "Checking endpoint status..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/launchpad" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^(200|302|301)$ ]]; then
      echo " [OK] Endpoint http://localhost:${port} is responding (HTTP ${http_code})."
    else
      echo " [INFO] Endpoint http://localhost:${port} returned HTTP ${http_code} (Service may still be booting)."
    fi
  fi
}

cmd_logs() {
  check_container_engine
  local service="${1:-server}"
  local name="${DEFAULT_STACK_NAME}"
  case "$service" in
    server|overleaf)
      "${CONTAINER_ENGINE}" logs -f "${name}-server"
      ;;
    mongo|mongodb)
      "${CONTAINER_ENGINE}" logs -f "${name}-mongo"
      ;;
    redis)
      "${CONTAINER_ENGINE}" logs -f "${name}-redis"
      ;;
    all)
      if pod_exists "${name}-pod"; then
        podman pod logs -f "${name}-pod"
      else
        "${CONTAINER_ENGINE}" logs -f "${name}-server"
      fi
      ;;
    *)
      echo "Unknown service '$service'. Choose: server, mongo, redis, or all." >&2
      exit 1
      ;;
  esac
}

cmd_create_user() {
  check_container_engine
  local email=""
  local password=""
  local is_admin=true
  local name="${DEFAULT_STACK_NAME}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --email) email="$2"; shift 2 ;;
      --password) password="$2"; shift 2 ;;
      --admin) is_admin=true; shift ;;
      --no-admin) is_admin=false; shift ;;
      --name) name="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$email" ]]; then
    echo "Error: --email <email> is required." >&2
    usage
    exit 1
  fi

  if [[ -z "$password" ]]; then
    password=$(openssl rand -base64 16)
    echo "Notice: No password provided; generated random password."
  fi

  local server_name="${name}-server"
  if ! container_exists "${server_name}"; then
    echo "Error: Container '${server_name}' is not running." >&2
    exit 1
  fi

  echo "==> Programmatically provisioning user '${email}' with direct password..."
  "${CONTAINER_ENGINE}" exec -i -w /overleaf/services/web "${server_name}" node --input-type=module - <<EOF
import crypto from 'node:crypto';
import UserRegistrationHandler from './app/src/Features/User/UserRegistrationHandler.mjs';
import AuthenticationManager from './app/src/Features/Authentication/AuthenticationManager.mjs';
import { User } from './app/src/models/User.mjs';

const email = '${email}';
const password = '${password}';
const isAdmin = ${is_admin};

const existing = await User.findOne({ email }).exec();
if (existing) {
  console.log('User exists. Updating password and permissions...');
  await AuthenticationManager.setUserPassword(existing, password);
  await User.updateOne({ _id: existing._id }, { \$set: { isAdmin } }).exec();
} else {
  const userDetails = {
    email,
    password,
    first_name: email.split('@')[0],
    last_name: 'User',
    analyticsId: crypto.randomUUID()
  };
  const user = await UserRegistrationHandler.promises.registerNewUser(userDetails);
  const reversedHostname = user.email.split('@')[1].split('').reverse().join('');
  await User.updateOne(
    { _id: user._id },
    {
      \$set: {
        isAdmin,
        emails: [{ email, reversedHostname, confirmedAt: new Date() }]
      }
    }
  ).exec();
}
console.log('SUCCESS: User provisioned.');
process.exit(0);
EOF

  echo "============================================================"
  echo " User Provisioned (Ready for Programmatic / API Access)"
  echo "============================================================"
  echo " Email:    ${email}"
  echo " Password: ${password}"
  echo " Admin:    ${is_admin}"
  echo "============================================================"
}

cmd_create_admin() {
  cmd_create_user --admin "$@"
}

cmd_install_pkg() {
  check_container_engine
  local name="${DEFAULT_STACK_NAME}"
  local server_name="${name}-server"

  if [[ $# -eq 0 ]]; then
    echo "Error: specify one or more packages to install." >&2
    echo "Example: overleaf-ctl.sh install-pkg minted latexmk" >&2
    exit 1
  fi

  if ! container_exists "${server_name}"; then
    echo "Error: Container '${server_name}' is not running." >&2
    exit 1
  fi

  echo "==> Installing package(s): $* via tlmgr..."
  "${CONTAINER_ENGINE}" exec -it "${server_name}" tlmgr install "$@"
  echo "==> Installation complete!"
}

cmd_shell() {
  check_container_engine
  local name="${DEFAULT_STACK_NAME}"
  local server_name="${name}-server"
  if ! container_exists "${server_name}"; then
    echo "Error: Container '${server_name}' is not running." >&2
    exit 1
  fi
  "${CONTAINER_ENGINE}" exec -it "${server_name}" /bin/bash
}

cmd_clean() {
  check_container_engine
  local delete_volumes=false
  local name="${DEFAULT_STACK_NAME}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --volumes)
        delete_volumes=true
        shift
        ;;
      --name)
        name="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  cmd_down --name "${name}"

  if [[ "$delete_volumes" == "true" ]]; then
    echo "==> WARNING: Deleting persistent data volumes..."
    for vol in "${name}_data" "${name}_mongo_data" "${name}_redis_data"; do
      if volume_exists "$vol"; then
        echo "  Deleting volume: $vol"
        "${CONTAINER_ENGINE}" volume rm "$vol" >/dev/null 2>&1 || true
      fi
    done
    echo "==> Volumes removed."
  else
    echo "==> Volumes preserved. To delete data volumes as well, rerun with --volumes"
  fi
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  local action="$1"
  shift

  case "$action" in
    build)
      cmd_build "$@"
      ;;
    up|start)
      cmd_up "$@"
      ;;
    down|stop)
      cmd_down "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    logs)
      cmd_logs "$@"
      ;;
    create-user|create-admin)
      cmd_create_user "$@"
      ;;
    install-pkg)
      cmd_install_pkg "$@"
      ;;
    shell)
      cmd_shell "$@"
      ;;
    clean)
      cmd_clean "$@"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      echo "Error: Unknown command '$action'" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
