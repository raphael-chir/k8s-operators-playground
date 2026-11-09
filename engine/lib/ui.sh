#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# ui.sh — Terminal UI helpers
# Native Bash and ANSI escape sequences to build interactive terminal-based lab
# scenarios. No external dependency (works with bash 3.2 on macOS and bash 5 on Linux).
#
# Usage:
#   source ./ui.sh
#
# Main helpers:
#   ui_section  : display a major section title
#   ui_step     : display a lab step
#   ui_info     : display informational text
#   ui_success  : display a success message
#   ui_warn     : display a warning message
#   ui_error    : display an error message
#   ui_confirm  : ask for yes/no confirmation
#   ui_pause    : pause until user confirms
#   ui_input    : ask for text input
#   ui_choose   : ask user to choose from a list
#   ui_spin     : show spinner while a command runs
#   ui_type     : simulate typing
#   ui_command  : simulate typing a command, then execute it
#   ui_watch    : refresh a command until Enter is pressed (replaces watch)
# -----------------------------------------------------------------------------

# Palette (ANSI 256, Catppuccin-inspired): title/use case 183 lavender, instructions/context 81 cyan, prompt arrow 121 mint,
# command 255 white, success 114 green, warning/pause 215 amber, error 203 coral, borders 240 dark gray.
# Colors (256-color palette) are used only on an interactive terminal; NO_COLOR disables them.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  _UI_COLOR=1
else
  _UI_COLOR=0
fi

# Print an ANSI SGR sequence (e.g. "1;38;5;75"), or nothing when colors are off.
_ui_sgr() {
  if [ "${_UI_COLOR}" = 1 ]; then
    printf '\033[%sm' "$1"
  fi
}

# Print "text" in the given SGR style, followed by a newline.
_ui_say() {
  _ui_sgr "$1"
  printf '%s' "$2"
  _ui_sgr 0
  printf '\n'
}

# Print a rounded box around the lines of $1.
# Arguments: text, border color, text color, bold (0|1), vertical padding, horizontal padding.
_ui_box() {
  local text="$1" border="$2" fg="$3" bold="$4" vpad="$5" hpad="$6"
  local line width=0 bar="" pad="" gap="" i
  local lines=()
  while IFS= read -r line; do
    lines+=("${line}")
    [ "${#line}" -le "${width}" ] || width="${#line}"
  done <<< "${text}"
  for (( i = 0; i < width + 2 * hpad; i++ )); do bar+="─"; done
  for (( i = 0; i < hpad; i++ )); do pad+=" "; done
  local blank=""
  for (( i = 0; i < width; i++ )); do blank+=" "; done
  local b="38;5;${border}" t="38;5;${fg}"
  [ "${bold}" = 0 ] || t="1;${t}"

  _ui_say "${b}" "╭${bar}╮"
  for (( i = 0; i < vpad; i++ )); do
    _ui_sgr "${b}"; printf '│%s%s%s│' "${pad}" "${blank}" "${pad}"; _ui_sgr 0; printf '\n'
  done
  for line in "${lines[@]}"; do
    gap=""
    for (( i = ${#line}; i < width; i++ )); do gap+=" "; done
    _ui_sgr "${b}"; printf '│'; _ui_sgr 0
    _ui_sgr "${t}"; printf '%s%s%s%s' "${pad}" "${line}" "${gap}" "${pad}"; _ui_sgr 0
    _ui_sgr "${b}"; printf '│'; _ui_sgr 0; printf '\n'
  done
  for (( i = 0; i < vpad; i++ )); do
    _ui_sgr "${b}"; printf '│%s%s%s│' "${pad}" "${blank}" "${pad}"; _ui_sgr 0; printf '\n'
  done
  _ui_say "${b}" "╰${bar}╯"
}

# Kept for compatibility with scenarios written for the gum-based version: nothing to check.
ui_require_gum() {
  return 0
}

# Display a compact rounded box (blue-gray border) sized to its content, styled from a Markdown-like text:
#   "# 01 / Title"  bold mint title (number included)                 "## Section"  bold cyan heading
#   "- Item"        mint bullet, light gray text                      anything else light gray text
# A blank line follows the title and precedes each section; an empty line adds one more (leading and trailing ones are
# ignored). Text wraps at 80 columns. One blank line is printed after the box.
# Example:
#   ui_note "
#   # 01 / Install operators
#   Deploy the components using Helm.
#   ## Prerequisites
#   - Kubernetes cluster running
#   "
ui_note() {
  local kinds=() nums=() texts=() line text num rest part n i j width=0 len pad bar="" last=start pending=0 first
  # Appends one row: kind (B blank, T title, H heading, L bullet, C bullet continuation, P paragraph), number, text.
  _ui_note_add() { kinds+=("$1"); nums+=("$2"); texts+=("$3"); last="$1"; }
  while IFS= read -r line; do
    if [ -z "${line}" ]; then pending=1; continue; fi
    if [ "${last}" != start ] && [ "${last}" != B ]; then
      if [ "${pending}" = 1 ]; then _ui_note_add B "" ""
      else case "${line}" in "## "*) _ui_note_add B "" "" ;; esac; fi
    fi
    pending=0
    case "${line}" in
      "## "*) _ui_note_add H "" "$(printf '%s' "${line#\#\# }" | tr '[:lower:]' '[:upper:]')" ;;
      "# "*)
        text="$(printf '%s' "${line#\# }" | tr '[:lower:]' '[:upper:]')"; num=""; rest="${text}"
        if [[ "${text}" =~ ^([0-9]+)[[:space:]]*[/—-]?[[:space:]]*(.*)$ ]]; then num="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; fi
        _ui_note_add T "${num}" "${rest}"; _ui_note_add B "" "" ;;
      "- "*)
        first=L
        while IFS= read -r part; do _ui_note_add "${first}" "" "${part}"; first=C; done < <(printf '%s\n' "${line#- }" | fold -s -w 76) ;;
      *)
        while IFS= read -r part; do _ui_note_add P "" "${part}"; done < <(printf '%s\n' "${line}" | fold -s -w 80) ;;
    esac
  done <<< "$1"
  # No blank row left at the end (the box has its own vertical padding).
  while [ "${#kinds[@]}" -gt 0 ] && [ "${kinds[${#kinds[@]}-1]}" = B ]; do
    unset "kinds[${#kinds[@]}-1]" "nums[${#nums[@]}-1]" "texts[${#texts[@]}-1]"
  done
  n="${#kinds[@]}"
  [ "${n}" -gt 0 ] || return 0
  for (( i = 0; i < n; i++ )); do
    case "${kinds[i]}" in
      T) len=$(( ${#texts[i]} + ${#nums[i]} + (${#nums[i]} > 0 ? 2 : 0) )) ;;
      L|C) len=$(( ${#texts[i]} + 2 )) ;;
      *) len=${#texts[i]} ;;
    esac
    [ "${len}" -le "${width}" ] || width="${len}"
  done
  for (( i = 0; i < width + 4; i++ )); do bar+="─"; done
  _ui_say "38;5;60" "╭${bar}╮"
  _ui_note_row() {   # <printed length> then the already styled text on stdin-free args: $1 length, $2 styled text
    pad=""; for (( j = 0; j < width - $1; j++ )); do pad+=" "; done
    _ui_sgr "38;5;60"; printf '│'; _ui_sgr 0; printf '  %s%s  ' "$2" "${pad}"; _ui_sgr "38;5;60"; printf '│'; _ui_sgr 0; printf '\n'
  }
  _ui_note_row 0 ""
  for (( i = 0; i < n; i++ )); do
    case "${kinds[i]}" in
      B) _ui_note_row 0 "" ;;
      T)
        len=$(( ${#texts[i]} + ${#nums[i]} + (${#nums[i]} > 0 ? 2 : 0) ))
        text=""; [ -z "${nums[i]}" ] || text="$(_ui_sgr "1;38;5;121")${nums[i]}$(_ui_sgr 0)  "
        _ui_note_row "${len}" "${text}$(_ui_sgr "1;38;5;121")${texts[i]}$(_ui_sgr 0)" ;;
      H) _ui_note_row "${#texts[i]}" "$(_ui_sgr "1;38;5;81")${texts[i]}$(_ui_sgr 0)" ;;
      L) _ui_note_row $(( ${#texts[i]} + 2 )) "$(_ui_sgr "38;5;121")◆$(_ui_sgr 0) $(_ui_sgr "38;5;252")${texts[i]}$(_ui_sgr 0)" ;;
      C) _ui_note_row $(( ${#texts[i]} + 2 )) "  $(_ui_sgr "38;5;252")${texts[i]}$(_ui_sgr 0)" ;;
      P) _ui_note_row "${#texts[i]}" "$(_ui_sgr "38;5;252")${texts[i]}$(_ui_sgr 0)" ;;
    esac
  done
  _ui_note_row 0 ""
  _ui_say "38;5;60" "╰${bar}╯"
  printf '\n'
}

# Display a major section header.
# Example:
#   ui_section "CNPG Cluster Deployment"
ui_section() {
  _ui_box "$1" 240 183 1 0 2
}

# Display informational text.
# Example:
#   ui_info "Checking Kubernetes cluster..."
ui_info() {
  printf "\n"
  _ui_say "1;38;5;81" "◆ $1"
}

# Display a success message.
# Example:
#   ui_success "Cluster is ready"
ui_success() {
  _ui_say "1;38;5;114" "✓ $1"
}

# Display a warning message.
# Example:
#   ui_warn "This operation may take several minutes"
ui_warn() {
  _ui_say "1;38;5;215" "⚠ $1"
}

# Display an error message.
# Example:
#   ui_error "Cluster creation failed"
ui_error() {
  _ui_say "1;38;5;203" "✗ $1"
}

# Display a numbered or named lab step.
# Example:
#   ui_step "1 - Deploy the CNPG cluster"
ui_step() {
  _ui_say "1;38;5;75" "▶ STEP $1"
}

# Ask the user to confirm an action.
# Returns:
#   0 = confirmed
#   1 = cancelled
# Example:
#   ui_confirm "Do you want to continue?"
ui_confirm() {
  local answer=""
  _ui_sgr "38;5;247"
  printf '%s [Y/n] ' "$1"
  _ui_sgr 0
  read -r answer || return 1
  case "${answer}" in
    ""|y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Pause the lab flow until the user confirms.
# Example:
#   ui_pause
ui_pause() {
  _ui_sgr "38;5;114"
  printf '↳ '
  _ui_sgr "38;5;245"
  printf ' Enter to continue '
  _ui_sgr 0
  read -r _
}

# Ask the user for text input.
# The first argument is used as placeholder text.
# Example:
#   namespace=$(ui_input "Namespace name")
ui_input() {
  local value=""
  # Prompt on stderr so that $(ui_input ...) captures only the typed value.
  printf '%s: ' "$1" >&2
  read -r value || return 1
  printf '%s\n' "${value}"
}

ui_login() {
  local user
  echo
  _ui_say "38;5;247" "Username"
  read -rp "❯ " user
  [ -z "$user" ] && return 1
  # -m keeps the environment and working directory (a plain `su -` is a fresh login: the terminal's KUBECONFIG
  # and directory would be lost). The shell then reads ~/.bashrc, so the Bash prompt is the same as outside.
  exec su -m "$user"
}

# Display a selection menu and print the selected value.
# Example:
#   choice=$(ui_choose "Deploy" "Backup" "Restore")
ui_choose() {
  local choice="" i
  # Menu on stderr so that $(ui_choose ...) captures only the selected value.
  while true; do
    for (( i = 1; i <= $#; i++ )); do
      printf '  %d) %s\n' "${i}" "${!i}" >&2
    done
    printf '#? ' >&2
    read -r choice || return 1
    if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "$#" ]; then
      printf '%s\n' "${!choice}"
      return 0
    fi
  done
}

# Display a spinner while running a command.
# Example:
#   ui_spin "Creating cluster..." kubectl apply -f cluster.yaml
ui_spin() {
  local title="$1"
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local pid i=0 status=0
  shift

  # Without a terminal there is nothing to animate: just run the command.
  if [ ! -t 1 ]; then
    "$@" >/dev/null 2>&1
    return
  fi

  "$@" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    printf '\r'
    _ui_sgr "38;5;247"
    printf '%s %s' "${frames:$((i % 10)):1}" "${title}"
    _ui_sgr 0
    i=$((i + 1))
    sleep 0.1
  done
  wait "${pid}" || status=$?
  printf '\r\033[K'
  return "${status}"
}

# Simulate text being typed character by character.
# Arguments:
#   $1 = text to display
#   $2 = optional delay between characters, default 0.03 seconds
# Example:
#   ui_type "kubectl get pods"
ui_type() {
  local text="$1"
  local delay="${2:-0.03}"

  for ((i = 0; i < ${#text}; i++)); do
    printf "%s" "${text:$i:1}"
    sleep "$delay"
  done

  printf "\n"
}

# Simulate a command being typed, then execute it.
# Useful for guided demonstrations.
# Warning:
#   This uses eval, so only pass trusted commands.
# Example:
#   ui_command "kubectl get pods -A"
ui_command() {
  local cmd="$1"
  _ui_sgr "1;38;5;121"
  _ui_prompt
  _ui_sgr "1;38;5;255"
  ui_type "$cmd" 0.015
  _ui_sgr 0
  eval "$cmd"
}

# Single-line prompt prefix, printed in the caller's color:   ☸ cluster-<n> ➜
# <n> is the trailing number of the active context (kind-cnpg-lab-<usecase>-<n>), read at every call with
# kubectl config current-context. A context without a trailing number is shown as is; no answer = no-context.
_ui_prompt() {
  local ctx="" label
  if command -v kubectl >/dev/null 2>&1; then ctx="$(kubectl config current-context 2>/dev/null)" || ctx=""; fi
  if [ -z "${ctx}" ]; then label="no-context"
  elif [[ "${ctx}" =~ -([0-9]+)$ ]]; then label="cluster-${BASH_REMATCH[1]}"
  else label="${ctx}"; fi
  printf '☸ %s ➜ ' "${label}"
}

# Run a command repeatedly, refreshing the screen, until the user presses Enter.
# Native replacement for the Unix watch command.
# Warning:
#   This uses eval, so only pass trusted commands.
# Arguments:
#   $1 = command to run
#   $2 = refresh interval in whole seconds, default 2
# Example:
#   ui_watch "kubectl get pods -o wide"
#   ui_watch "kubectl get clusters -A" 5
ui_watch() {
  local cmd="$1"
  local interval="${2:-2}"
  local i status started

  case "${interval}" in
    ''|*[!0-9]*|0) interval=2 ;;
  esac

  # Alternate screen: the refresh frames never reach the scrollback, and the previous display comes back on exit.
  # A subshell, so that Ctrl+C ends the watch (and runs the EXIT trap) the same way when called from a script or
  # straight from an interactive prompt, and the caller's own EXIT trap is never replaced.
  (
  printf '\033[?1049h'
  trap 'printf "\033[?1049l"' EXIT
  while true; do
    printf '\033[H\033[J'   # not `clear`: it also sends ESC[3J, which erases the scrollback
    printf "\033[1;32m❯\033[0m %s\n" "${cmd}"
    # stdin is closed for the command so it cannot swallow the Enter key.
    eval "${cmd}" </dev/null || true
    printf "\n\033[38;5;214m▶ Press Enter to continue ...\033[0m\n"
    # Wait in 1-second slices (integer timeouts only, for bash 3.2). Keys typed
    # while the command was running stay buffered and are read here.
    for (( i = 0; i < interval; i++ )); do
      status=0
      started="${SECONDS}"
      read -r -t 1 _ || status=$?
      [ "${status}" -ne 0 ] || break 2
      # bash 3.2 returns 1 on timeout like on EOF: a read that came back
      # within the same second (Ctrl-D, closed stdin) means no more input.
      [ "${SECONDS}" -ne "${started}" ] || break 2
    done
  done
  printf '\033[?1049l'
  )
}