#!/usr/bin/env bash
# Boot backend + desktop in a detached tmux session with hot reload and
# per-process log files. Replaces the foreground `make dev` for cases where
# you want to keep the terminal free, tail logs separately, and have the
# Go server auto-restart on source change.
#
#   make dev-detach    # spin up the session
#   make dev-logs      # tail combined logs
#   make dev-attach    # attach tmux to inspect any pane
#   make dev-stop      # kill the session and processes
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SESSION="${MULTICA_DEV_SESSION:-multica-dev}"
LOG_DIR="$REPO_ROOT/.dev-logs"
mkdir -p "$LOG_DIR"

# ---------- Prerequisites ----------
missing=()
command -v node    >/dev/null 2>&1 || missing+=("node")
command -v pnpm    >/dev/null 2>&1 || missing+=("pnpm")
command -v go      >/dev/null 2>&1 || missing+=("go")
command -v docker  >/dev/null 2>&1 || missing+=("docker")
command -v tmux    >/dev/null 2>&1 || missing+=("tmux")
if [ ${#missing[@]} -gt 0 ]; then
  echo "✗ Missing prerequisites: ${missing[*]}"
  echo "  brew install ${missing[*]}"
  exit 1
fi

# ---------- Env file (same logic as scripts/dev.sh) ----------
if [ -f .git ]; then
  ENV_FILE=".env.worktree"
  [ -f "$ENV_FILE" ] || bash scripts/init-worktree-env.sh "$ENV_FILE"
else
  ENV_FILE=".env"
  [ -f "$ENV_FILE" ] || cp .env.example "$ENV_FILE"
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# ---------- Deps ----------
[ -d node_modules ] || pnpm install

# ---------- Air (Go hot reload) ----------
if ! command -v air >/dev/null 2>&1; then
  echo "==> Installing air (Go hot reload)..."
  GOBIN="$HOME/go/bin" go install github.com/air-verse/air@latest
fi
AIR_BIN="$(command -v air || echo "$HOME/go/bin/air")"
export PATH="$HOME/go/bin:$PATH"

# Air config — kept minimal, drops state into ./tmp/ to stay out of git.
AIR_TOML="$REPO_ROOT/server/.air.toml"
if [ ! -f "$AIR_TOML" ]; then
  cat > "$AIR_TOML" <<'EOF'
root = "."
tmp_dir = "tmp"

[build]
  cmd = "go build -o tmp/server ./cmd/server"
  bin = "tmp/server"
  include_ext = ["go", "sql"]
  exclude_dir = ["tmp", "bin", "internal/.cache"]
  delay = 400

[log]
  time = true
EOF
fi

# ---------- Postgres + migrations ----------
bash scripts/ensure-postgres.sh "$ENV_FILE"
echo "==> Running migrations..."
(cd server && go run ./cmd/migrate up)

# ---------- Kill stale session ----------
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "==> Killing previous session '$SESSION'..."
  tmux kill-session -t "$SESSION"
fi

# ---------- Spin up tmux session ----------
echo "==> Starting tmux session '$SESSION'..."

# Window 1: backend (air)
tmux new-session -d -s "$SESSION" -n backend \
  "cd '$REPO_ROOT/server' && '$AIR_BIN' -c .air.toml 2>&1"
tmux pipe-pane -t "$SESSION:backend" "cat >> '$LOG_DIR/backend.log'"

# Window 2: desktop (electron-vite — HMR for renderer + main reload)
tmux new-window -t "$SESSION" -n desktop \
  "cd '$REPO_ROOT' && pnpm dev:desktop 2>&1"
tmux pipe-pane -t "$SESSION:desktop" "cat >> '$LOG_DIR/desktop.log'"

# ---------- Friendly summary ----------
cat <<EOF

✓ Detached dev stack running.

  Backend:   http://localhost:${PORT:-8080}      (hot reload: air)
  Desktop:   Electron window auto-launches       (hot reload: electron-vite)

  make dev-logs     # tail -F .dev-logs/*.log
  make dev-attach   # attach the tmux session
  make dev-stop     # stop everything

  Logs:
    $LOG_DIR/backend.log
    $LOG_DIR/desktop.log
EOF
