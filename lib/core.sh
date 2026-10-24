#!/usr/bin/env bash
# ~/.productivity-suite/lib/core.sh
# Shared Core Library for Productivity Suite

# ==========================================
# 1. PATHS & CONFIGURATION
# ==========================================
export SUITE_ROOT="${SUITE_ROOT:-$HOME/.productivity-suite}"
export BIN_DIR="$SUITE_ROOT/bin"
export LIB_DIR="$SUITE_ROOT/lib"
export DATA_DIR="$SUITE_ROOT/data"
export STATE_DIR="$SUITE_ROOT/state"

export TERMINAL="${TERMINAL:-foot}"
export EDITOR="${EDITOR:-vim}"

# State & Log Files
export AUTOSYNC_FILE="$SUITE_ROOT/.autosync"
export LOG_FILE="$STATE_DIR/hub.log"
export SYNC_LOG="$STATE_DIR/sync.log"
export SYNC_LOCK="$STATE_DIR/sync.lock"

# Data Subdirectories
export NOTES_DIR="$DATA_DIR/notes"
export ROUTINE_DIR="$DATA_DIR/routine"
export TUXEDO_DIR="$DATA_DIR/Todo"
export TODO_DIR="$TUXEDO_DIR"
export TIMERS_DATA_DIR="$DATA_DIR/timers"

# Git Sync Defaults
export GIT_BRANCH="main"
export GIT_USER_NAME="Productivity Hub"
export GIT_USER_EMAIL="hub@local"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$DATA_DIR" "$STATE_DIR"

# ==========================================
# 2. LOGGING & NOTIFICATIONS
# ==========================================
log_event() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

play_sound() {
    local sound="/usr/share/sounds/freedesktop/stereo/complete.oga"
    if command -v paplay >/dev/null 2>&1 && [[ -f "$sound" ]]; then
        paplay "$sound" >/dev/null 2>&1 &
    elif command -v pw-play >/dev/null 2>&1 && [[ -f "$sound" ]]; then
        pw-play "$sound" >/dev/null 2>&1 &
    elif command -v mpv >/dev/null 2>&1 && [[ -f "$sound" ]]; then
        mpv --no-video "$sound" >/dev/null 2>&1 &
    else
        echo -e "\a"
    fi
}

notify_hub() {
    local urgency="${1:-normal}"
    local timeout="${2:-3000}"
    local title="${3:-Productivity Hub}"
    local msg="${4:-}"
    shift 4 2>/dev/null || true

    if command -v notify-send >/dev/null 2>&1; then
        notify-send -e -u "$urgency" -t "$timeout" "$@" "$title" "$msg"
    fi
}

# ==========================================
# 3. FUZZEL & FOOT WRAPPERS
# ==========================================
fuzzel_menu() {
    local prompt="${1:-Select ❯ }"
    local lines="${2:-10}"
    fuzzel --dmenu --prompt="$prompt" --lines="$lines"
}

fuzzel_input() {
    local prompt="${1:-Input ❯ }"
    echo "" | fuzzel --dmenu --prompt="$prompt" --lines=0  --width=75
}

# Launches a script in foot, waits for exit, and triggers autosync if enabled
launch_and_sync() {
    local app_id="$1"
    local script_path="$2"
    shift 2

    log_event "Launching: $app_id ($script_path $*)"
    "$TERMINAL" -a "$app_id" -e "$script_path" "$@"

    trigger_autosync "$app_id"
}

trigger_autosync() {
    local source_name="${1:-manual}"
    if [[ -f "$AUTOSYNC_FILE" ]]; then
        log_event "Autosync triggered by $source_name"
        sync_data > "$SYNC_LOG" 2>&1 &
        disown
    fi
}

# ==========================================
# 4. GIT SYNC ENGINE
# ==========================================
sync_data() {
    export GIT_TERMINAL_PROMPT=0

    # Prevent overlapping background syncs
    exec 9>"$SYNC_LOCK"
    if ! flock -n 9; then
        log_event "Sync skipped: Another sync process is already running."
        return 0
    fi

    mkdir -p "$DATA_DIR"
    cd "$DATA_DIR" || {
        notify_hub critical 0 "Sync Error" "Cannot access $DATA_DIR"
        return 1
    }

    # Module 1: Initialize Repository
    if [[ ! -d ".git" ]]; then
        git init
        git config user.name "$GIT_USER_NAME"
        git config user.email "$GIT_USER_EMAIL"
        touch .sync_keep
        git add .sync_keep
        git commit -m "Initial automated commit"
    fi

    # Module 2: Setup Remote & Branch
    local current_remote
    current_remote=$(git remote get-url origin 2>/dev/null || true)

    if [[ -z "$current_remote" ]]; then
        notify_hub normal 0 "Productivity Hub" "Remote missing. Awaiting user input..."
        local user_remote_url
        user_remote_url=$(fuzzel_input "Git Remote URL ❯ ")

        if [[ -z "$user_remote_url" ]]; then
            notify_hub critical 0 "Sync Error" "No remote URL provided. Aborting sync."
            return 1
        fi

        git remote add origin "$user_remote_url"
    fi

    git checkout -B "$GIT_BRANCH" >/dev/null 2>&1

    # Module 3: Core Sync Handling
    if [[ -n "$(git status --porcelain)" ]]; then
        git add .
        git commit -m "Auto-commit: $(date +'%Y-%m-%d %H:%M:%S')"
    fi

    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        notify_hub normal 3000 "Productivity Hub" "Offline Mode: Local changes committed."
        return 0
    fi

    if ! git fetch origin "$GIT_BRANCH" >/dev/null 2>&1; then
        if git push -u origin "$GIT_BRANCH"; then
            notify_hub normal 3000 "Productivity Hub" "Initial branch pushed to remote."
        else
            notify_hub critical 0 "Sync Error" "Failed to push initial branch. Check sync.log."
            return 1
        fi
        return 0
    fi

    local counts ahead behind
    counts=$(git rev-list --left-right --count "$GIT_BRANCH...origin/$GIT_BRANCH" 2>/dev/null || echo "0 0")
    ahead=$(echo "$counts" | awk '{print $1}')
    behind=$(echo "$counts" | awk '{print $2}')
    ahead=${ahead:-0}
    behind=${behind:-0}

    if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
        notify_hub normal 1000 "Productivity Hub" "Data is already synchronized."
        return 0
    elif [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
        git pull --rebase origin "$GIT_BRANCH"
        notify_hub normal 3000 "Productivity Hub" "Pulled latest updates from remote."
        return 0
    elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
        git push origin "$GIT_BRANCH"
        notify_hub normal 1000 "Productivity Hub" "Pushed local updates to remote."
        return 0
    fi

    # Module 4: Rebase & Conflict Handling
    notify_hub normal 3000 "Productivity Hub" "Divergence detected. Attempting safe rebase..."

    if git rebase "origin/$GIT_BRANCH"; then
        git push origin "$GIT_BRANCH"
        notify_hub normal 2000 "Productivity Hub" "Rebase and push successful."
    else
        notify_hub critical 0 "Productivity Hub" "Conflict detected. Applying local preference..."
        git checkout --theirs .
        git add .

        if git rebase --continue; then
            git push origin "$GIT_BRANCH"
            notify_hub normal 3000 "Productivity Hub" "Conflict resolved automatically. Sync complete."
        else
            git rebase --abort
            notify_hub critical 0 "Sync Error" "Rebase failed. Manual review required!"
            return 1
        fi
    fi
}
