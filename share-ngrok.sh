#!/usr/bin/env bash
set -euo pipefail

HTML_FILE="${1:-}"
START_PORT="${2:-8090}"
MIN_NGROK_MAJOR=3
MIN_NGROK_MINOR=20
ALLOW_TEMP_NGROK="${ALLOW_TEMP_NGROK:-ask}"

choose_html_file() {
  local choice idx
  local -a html_options=()

  while IFS= read -r file; do
    html_options+=("${file#./}")
  done < <(find . -maxdepth 1 -type f -name '*.html' | sort)

  if (( ${#html_options[@]} == 0 )); then
    echo "No .html files found in this folder." >&2
    exit 1
  fi

  echo "Available HTML presentations:"
  for idx in "${!html_options[@]}"; do
    printf "  %d) %s\n" "$((idx + 1))" "${html_options[$idx]}"
  done

  while true; do
    printf "Select a file to host by number: "
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#html_options[@]} )); then
      HTML_FILE="${html_options[$((choice - 1))]}"
      break
    fi
    echo "Please enter a number between 1 and ${#html_options[@]}."
  done
}

if [[ -z "$HTML_FILE" ]]; then
  choose_html_file
fi

if [[ ! -f "$HTML_FILE" ]]; then
  echo "Could not find HTML file: $HTML_FILE" >&2
  echo "Usage: bash share-ngrok.sh [deck.html] [port]" >&2
  echo "Or run without arguments to select from .html files in this folder." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to serve the deck locally." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$HTML_FILE")" && pwd)"
HTML_BASENAME="$(basename "$HTML_FILE")"
SHARE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slides-ngrok-share.XXXXXX")"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slides-ngrok-logs.XXXXXX")"
SERVER_PID=""
NGROK_PID=""

cleanup() {
  if [[ -n "${NGROK_PID:-}" ]] && kill -0 "$NGROK_PID" >/dev/null 2>&1; then
    kill "$NGROK_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$SHARE_DIR" "$LOG_DIR"
}
trap cleanup EXIT INT TERM

echo "Preparing isolated share folder..."
cp "$ROOT_DIR/$HTML_BASENAME" "$SHARE_DIR/index.html"

if [[ -d "$ROOT_DIR/images" ]]; then
  cp -R "$ROOT_DIR/images" "$SHARE_DIR/images"
fi

is_supported_ngrok() {
  local cmd="$1"
  local version major minor rest
  version="$("$cmd" version 2>/dev/null | awk '{print $3}' || true)"
  [[ -n "$version" ]] || return 1
  major="${version%%.*}"
  rest="${version#*.}"
  minor="${rest%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [[ "$minor" =~ ^[0-9]+$ ]] || return 1
  if (( major > MIN_NGROK_MAJOR )); then
    return 0
  fi
  if (( major == MIN_NGROK_MAJOR && minor >= MIN_NGROK_MINOR )); then
    return 0
  fi
  return 1
}

ngrok_version() {
  local cmd="$1"
  "$cmd" version 2>/dev/null | awk '{print $3}' || true
}

find_ngrok_candidates() {
  local temp_ngrok="${TMPDIR:-/tmp}/ngrok-v3-temp/ngrok"
  local candidate

  if [[ -x "$temp_ngrok" ]]; then
    printf "%s\n" "$temp_ngrok"
  fi

  if command -v ngrok >/dev/null 2>&1; then
    command -v ngrok
  fi

  for candidate in \
    /usr/local/bin/ngrok \
    /opt/homebrew/bin/ngrok \
    /usr/local/Caskroom/ngrok/*/ngrok \
    /opt/homebrew/Caskroom/ngrok/*/ngrok
  do
    if [[ -x "$candidate" ]]; then
      printf "%s\n" "$candidate"
    fi
  done | awk '!seen[$0]++'
}

download_temp_ngrok() {
  local arch url zip_path temp_dir
  arch="$(uname -m)"
  temp_dir="${TMPDIR:-/tmp}/ngrok-v3-temp"
  mkdir -p "$temp_dir"

  case "$arch" in
    arm64|aarch64)
      url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-arm64.zip"
      ;;
    x86_64|amd64)
      url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-amd64.zip"
      ;;
    *)
      echo "Unsupported macOS architecture for automatic ngrok download: $arch" >&2
      exit 1
      ;;
  esac

  zip_path="$temp_dir/ngrok.zip"
  echo "Downloading current ngrok binary into $temp_dir..." >&2
  curl -L -o "$zip_path" "$url"
  unzip -oq "$zip_path" -d "$temp_dir"
  chmod +x "$temp_dir/ngrok"
  echo "$temp_dir/ngrok"
}

get_ngrok_cmd() {
  local candidate version reply
  local -a old_candidates=()

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    version="$(ngrok_version "$candidate")"
    if is_supported_ngrok "$candidate"; then
      echo "Using ngrok $version at $candidate" >&2
      echo "$candidate"
      return 0
    fi
    old_candidates+=("$candidate|${version:-unknown}")
  done < <(find_ngrok_candidates)

  if (( ${#old_candidates[@]} > 0 )); then
    echo "Found ngrok, but not a new enough version for your current ngrok account:" >&2
    for candidate in "${old_candidates[@]}"; do
      echo "  - ${candidate%%|*} version ${candidate##*|}" >&2
    done
    echo "ngrok previously required version ${MIN_NGROK_MAJOR}.${MIN_NGROK_MINOR}.0 or newer for this account." >&2
    echo "To update your Homebrew cask manually, try:" >&2
    echo "  brew update && brew upgrade --cask ngrok" >&2
  else
    echo "No ngrok binary was found in PATH or common Homebrew locations." >&2
  fi

  case "$ALLOW_TEMP_NGROK" in
    1|yes|true)
      download_temp_ngrok
      ;;
    0|no|false)
      echo "Temporary ngrok download is disabled. Exiting." >&2
      exit 1
      ;;
    *)
      printf "Download a temporary current ngrok binary for this run only? [y/N]: " >&2
      read -r reply
      case "$reply" in
        y|Y|yes|YES)
          download_temp_ngrok
          ;;
        *)
          echo "Stopped. Update ngrok with Homebrew, then run this script again." >&2
          exit 1
          ;;
      esac
      ;;
  esac
}

start_server() {
  local port="$1"
  local max_port=$((port + 20))
  local server_log="$LOG_DIR/server.log"

  while (( port <= max_port )); do
    (
      cd "$SHARE_DIR"
      python3 -m http.server "$port" --bind 127.0.0.1
    ) >"$server_log" 2>&1 &
    SERVER_PID=$!
    sleep 0.6
    if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
  done

  echo "Could not start a local server from port $1 to $max_port." >&2
  cat "$server_log" >&2 || true
  exit 1
}

PORT="$(start_server "$START_PORT")"
NGROK_CMD="$(get_ngrok_cmd)"
NGROK_LOG="$LOG_DIR/ngrok.log"

echo "Starting ngrok for http://127.0.0.1:$PORT ..."
"$NGROK_CMD" http "$PORT" --log=stdout >"$NGROK_LOG" 2>&1 &
NGROK_PID=$!

PUBLIC_URL=""
for _ in {1..45}; do
  if ! kill -0 "$NGROK_PID" >/dev/null 2>&1; then
    echo "ngrok stopped before creating a tunnel." >&2
    cat "$NGROK_LOG" >&2 || true
    exit 1
  fi
  PUBLIC_URL="$(grep -Eo 'https://[^[:space:]]+' "$NGROK_LOG" | grep -E 'ngrok' | head -n 1 || true)"
  if [[ -n "$PUBLIC_URL" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$PUBLIC_URL" ]]; then
  echo "Could not find the ngrok URL in time." >&2
  echo "ngrok log:" >&2
  cat "$NGROK_LOG" >&2 || true
  exit 1
fi

echo
echo "Shareable URL:"
echo "$PUBLIC_URL"
echo
echo "Serving: $HTML_FILE"
echo "Local:   http://127.0.0.1:$PORT"
echo
echo "Keep this terminal open. Press Ctrl+C to stop the public link."

wait "$NGROK_PID"
