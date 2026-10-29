#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${OH_CODESPACE_STATE_DIR:-${ROOT_DIR}/.openhands-dev/codespace}"
DATA_DIR="${STATE_DIR}/data"
PID_FILE="${STATE_DIR}/supervisor.pid"
KEY_FILE="${STATE_DIR}/api-key"
LOG_FILE="${STATE_DIR}/service.log"
PORT="${PORT:-8000}"

mkdir -p "$STATE_DIR"

ensure_uv() {
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v uvx >/dev/null 2>&1; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl is required to install uv." >&2
      exit 1
    fi
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  if ! command -v uvx >/dev/null 2>&1; then
    echo "uvx was not found after installing uv." >&2
    exit 1
  fi
}

ensure_api_key() {
  if [[ ! -s "$KEY_FILE" ]]; then
    if ! command -v openssl >/dev/null 2>&1; then
      echo "openssl is required to generate the local API key." >&2
      exit 1
    fi
    openssl rand -hex 32 > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
  fi
}

is_running() {
  [[ -s "$PID_FILE" ]] || return 1
  local pid
  pid="$(<"$PID_FILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= | grep -Fq "$ROOT_DIR/scripts/codespace-service.sh supervise"
}

start_service() {
  ensure_uv
  ensure_api_key

  if is_running; then
    echo "Agent Canvas supervisor is already running (PID $(<"$PID_FILE"))."
    return
  fi
  rm -f "$PID_FILE"

  nohup bash "$ROOT_DIR/scripts/codespace-service.sh" supervise >> "$LOG_FILE" 2>&1 </dev/null &
  echo "$!" > "$PID_FILE"
  echo "Agent Canvas is starting on port ${PORT}."
  echo "Codespaces will forward this port privately. Check status with: bash scripts/codespace-service.sh status"
  echo "Logs: ${LOG_FILE}"
  echo "API key: ${KEY_FILE} (read it only in this Codespace)."
}

supervise_service() {
  local child_pid=""
  stop_child() {
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
      kill -TERM "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    exit 0
  }
  trap stop_child TERM INT HUP

  export PATH="${HOME}/.local/bin:${PATH}"
  export OH_CANVAS_SAFE_STATE_DIR="$DATA_DIR"
  export LOCAL_BACKEND_API_KEY="$(<"$KEY_FILE")"
  export PORT

  while true; do
    printf '\n[%s] Starting Agent Canvas on port %s.\n' "$(date -Is)" "$PORT"
    npm --prefix "$ROOT_DIR" run dev -- --host 0.0.0.0 --public &
    child_pid=$!
    set +e
    wait "$child_pid"
    exit_code=$?
    set -e
    child_pid=""
    printf '[%s] Agent Canvas exited with status %s; restarting in 5 seconds.\n' "$(date -Is)" "$exit_code"
    sleep 5
  done
}

stop_service() {
  if ! is_running; then
    rm -f "$PID_FILE"
    echo "Agent Canvas supervisor is not running."
    return
  fi
  local pid
  pid="$(<"$PID_FILE")"
  kill -TERM "$pid"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
  done
  rm -f "$PID_FILE"
  echo "Stopped Agent Canvas supervisor (PID ${pid})."
}

case "${1:-start}" in
  setup)
    ensure_uv
    echo "Codespaces runtime setup is complete."
    ;;
  start)
    start_service
    ;;
  supervise)
    supervise_service
    ;;
  status)
    if is_running; then
      echo "Agent Canvas supervisor is running (PID $(<"$PID_FILE"))."
      if command -v curl >/dev/null 2>&1 && curl --silent --fail --max-time 3 "http://127.0.0.1:${PORT}/" >/dev/null; then
        echo "App responds on http://127.0.0.1:${PORT}/."
      else
        echo "App is still starting or restarting. See ${LOG_FILE}."
      fi
    else
      echo "Agent Canvas supervisor is not running."
      exit 1
    fi
    ;;
  stop)
    stop_service
    ;;
  restart)
    stop_service
    start_service
    ;;
  logs)
    touch "$LOG_FILE"
    tail -n 100 -f "$LOG_FILE"
    ;;
  *)
    echo "Usage: $0 {setup|start|status|stop|restart|logs}" >&2
    exit 2
    ;;
esac