#!/usr/bin/env bash
# init-replica-set.sh - Wait for MongoDB and initialize replica set for Overleaf Community Edition
set -euo pipefail

CONTAINER_NAME="${1:-overleaf-mongo}"
REPL_SET_NAME="${2:-overleaf}"
TARGET_HOST="${3:-127.0.0.1:27017}"
MAX_RETRIES="${4:-30}"

# Detect container engine: podman prioritized over docker
detect_engine() {
  if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
    ENGINE="$CONTAINER_ENGINE"
  elif [[ -n "${CONTAINER_CLI:-}" ]]; then
    ENGINE="$CONTAINER_CLI"
  elif command -v podman >/dev/null 2>&1; then
    ENGINE="podman"
  elif command -v docker >/dev/null 2>&1; then
    ENGINE="docker"
  else
    echo "Error: Neither podman nor docker found." >&2
    exit 1
  fi
}
detect_engine

container_exists() {
  local name="$1"
  if [[ "$ENGINE" == "podman" ]]; then
    podman container exists "$name" 2>/dev/null
  else
    docker container inspect "$name" >/dev/null 2>&1
  fi
}

echo "==> Checking MongoDB status in container '${CONTAINER_NAME}' (Engine: ${ENGINE})..."

# Verify container is running
if ! container_exists "${CONTAINER_NAME}"; then
  echo "Error: Container '${CONTAINER_NAME}' does not exist." >&2
  exit 1
fi

# Detect whether container has mongosh or mongo
MONGO_CMD=""
if "${ENGINE}" exec "${CONTAINER_NAME}" which mongosh >/dev/null 2>&1; then
  MONGO_CMD="mongosh --quiet"
elif "${ENGINE}" exec "${CONTAINER_NAME}" which mongo >/dev/null 2>&1; then
  MONGO_CMD="mongo --quiet"
else
  echo "Error: Neither mongosh nor mongo CLI found inside container '${CONTAINER_NAME}'." >&2
  exit 1
fi

echo "==> Waiting for MongoDB daemon to accept connections (using ${MONGO_CMD%% *})..."
retries=0
until "${ENGINE}" exec "${CONTAINER_NAME}" ${MONGO_CMD} --eval "db.adminCommand('ping')" >/dev/null 2>&1; do
  retries=$((retries + 1))
  if [ "$retries" -ge "$MAX_RETRIES" ]; then
    echo "Error: Timed out waiting for MongoDB in container '${CONTAINER_NAME}' after ${MAX_RETRIES} attempts." >&2
    exit 1
  fi
  sleep 1
done

echo "==> MongoDB is ready. Checking replica set '${REPL_SET_NAME}'..."

# Check if replica set is already initiated
IS_INITIATED=$("${ENGINE}" exec "${CONTAINER_NAME}" ${MONGO_CMD} --eval "
  try {
    var status = rs.status();
    print(status.ok == 1 ? 'true' : 'false');
  } catch(e) {
    print('false');
  }
" 2>/dev/null | tr -d '\r' | tail -n 1)

if [ "${IS_INITIATED}" = "true" ]; then
  echo "==> Replica set '${REPL_SET_NAME}' is already initiated and active."
else
  echo "==> Initiating replica set '${REPL_SET_NAME}' with member '${TARGET_HOST}'..."
  INIT_OUTPUT=$("${ENGINE}" exec "${CONTAINER_NAME}" ${MONGO_CMD} --eval "
    rs.initiate({
      _id: '${REPL_SET_NAME}',
      members: [
        { _id: 0, host: '${TARGET_HOST}' }
      ]
    })
  " 2>&1)
  echo "${INIT_OUTPUT}"
  
  # Wait for node to become primary
  echo "==> Waiting for replica set member to transition to PRIMARY..."
  retries=0
  until "${ENGINE}" exec "${CONTAINER_NAME}" ${MONGO_CMD} --eval "
    try {
      var state = rs.isMaster() || db.isMaster();
      print((state.ismaster || state.isWritablePrimary) ? 'ready' : 'waiting');
    } catch(e) {
      print('waiting');
    }
  " 2>/dev/null | grep -q "ready"; do
    retries=$((retries + 1))
    if [ "$retries" -ge 20 ]; then
      echo "Warning: Node did not report PRIMARY state within 20s, but proceeding..." >&2
      break
    fi
    sleep 1
  done
  echo "==> Replica set initialization complete!"
fi
