# shellcheck shell=bash
declare -A ansi_colornum=(
  [black]=0
  [red]=1
  [green]=2
  [yellow]=3
  [blue]=4
  [magenta]=5
  [cyan]=6
  [white]=7
)

declare -A ansi_stylenum=(
  [reset]=0
  [bright]=1
  [dim]=2
  [italic]=3
  [underline]=4
  [flash]=5
  [highlight]=7
  [normal]=22
)

# UI Mode auto-detection
if [[ -z "${_arg_ui_mode:-}" ]] || [[ "${_arg_ui_mode:-}" == "auto" ]]; then
  if ! { [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; } ||
    { [[ -n "${SSH_CLIENT:-}" ]] || [[ -n "${SSH_TTY:-}" ]]; }; then
    # If we do not have a display, or we are in a SSH session, fallback to text mode
    _arg_ui_mode="none"
  elif { [[ "${XDG_CURRENT_DESKTOP:-}" == "KDE" ]] && command -v kdialog &>/dev/null && command -v busctl &>/dev/null; }; then
    # If we are on KDE, and kdialog + busctl is available, use kdialog
    _arg_ui_mode="kdialog"
  elif command -v zenity &>/dev/null; then
    # Use Zenity if available
    _arg_ui_mode="zenity"
  elif command -v kdialog &>/dev/null && command -v busctl &>/dev/null; then
    # If kdialog is available, but zenity is not (outside of KDE)
    _arg_ui_mode="kdialog"
  else
    # If nothing is available, only run in text mode
    _arg_ui_mode="none"
  fi
fi

# Set-up fd6 as an alternate STDOUT for when we are doing operations with pipes, but
# still want to output progress
exec 6>&1

local PROGRESS_MIN_REFRESH=0.1

ansi::styled() {
  local ALLOW_ESCAPES="off"
  if [[ "${1:-}" == "-e" ]]; then
    ALLOW_ESCAPES="on"
    shift
  fi

  local TEXT_TO_PRINT="${1:-}"
  local STYLE="${2:--1}"
  local FORE_COLOR="${3:--1}"
  local BACK_COLOR="${4:--1}"

  declare -a CODES RESETCODES
  if [[ "${STYLE}" -eq 22 ]] || [[ "${STYLE}" -eq -1 ]]; then
    RESETCODES=("$(printf "\033[%sm" "22")" "${RESETCODES[@]}")
  else
    CODES=("${CODES[@]}" "$(printf "\033[%sm" "${STYLE}")")
  fi

  if [[ "${BACK_COLOR}" -eq -1 ]]; then
    RESETCODES=("$(printf "\033[%sm" "49")" "${RESETCODES[@]}")
  else
    CODES=("${CODES[@]}" "$(printf "\033[%sm" "$((BACK_COLOR + 40))")")
  fi

  if [[ "${FORE_COLOR}" -eq -1 ]]; then
    RESETCODES=("$(printf "\033[%sm" "39")" "${RESETCODES[@]}")
  else
    CODES=("${CODES[@]}" "$(printf "\033[%sm" "$((FORE_COLOR + 30))")")
  fi

  local rc
  for rc in "${RESETCODES[@]}"; do
    echo -en "$rc"
  done
  local c
  for c in "${CODES[@]}"; do
    echo -en "$c"
  done

  if [[ "${ALLOW_ESCAPES}" == "on" ]]; then
    echo -en "${TEXT_TO_PRINT}"
  else
    echo -n "${TEXT_TO_PRINT}"
  fi

  echo -en "\033[m"
}

ansi::banner() {
  local TOPEDGE BOTTOMEDGE
  TOPEDGE="┏━${1//?/━}━┓"
  BOTTOMEDGE="┗━${1//?/━}━┛"

  printf "%s\n" "$(ansi::styled "${TOPEDGE}" "${ansi_stylenum[bright]}")"
  printf "%s\n" "$(ansi::styled "┃ ${1} ┃" "${ansi_stylenum[bright]}")"
  printf "%s\n" "$(ansi::styled "${BOTTOMEDGE}" "${ansi_stylenum[bright]}")"
}

term::error() {
  echo -e "$(ansi::styled "Error:" "${ansi_stylenum[bright]}" "${ansi_colornum[red]}") $*" 1>&2
}

term::yesno() {
  local QUESTION="${1:-}"
  local DEFAULT="${2:-N}"

  local DEFAULT_PROMPT="[yN]"
  if [[ "${DEFAULT}" =~ ^[Yy]$ ]]; then
    DEFAULT_PROMPT="[Yn]"
  fi

  # When the script is piped into bash (e.g. from the .desktop file), STDIN is the script itself,
  # so read the answer from the terminal instead
  local PROMPT_INPUT="/dev/stdin"
  if ! test -t 0 && { true </dev/tty; } 2>/dev/null; then
    PROMPT_INPUT="/dev/tty"
  fi

  # In case the user was impatient and typed a whole bunch of crap in their terminal while waiting for a download
  # clear the STDIN buffer
  if test -t 0 || [[ "${PROMPT_INPUT}" == "/dev/tty" ]]; then
    local discard
    read -r -n 1000000 -t 0.001 discard <"${PROMPT_INPUT}" || true

    if [[ -n "${discard:-}" ]]; then
      echo
    fi
  fi

  read -p "$(ansi::styled "?" "${ansi_stylenum[bright]}" "${ansi_colornum[green]}") ${QUESTION} $(ansi::styled "${DEFAULT_PROMPT}" "${ansi_stylenum[bright]}") " -n 1 -r <"${PROMPT_INPUT}"
  echo
  if [[ "${DEFAULT}" =~ ^[Nn]$ ]]; then
    if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
      return 1
    fi
  elif [[ "${DEFAULT}" =~ ^[Yy]$ ]]; then
    if [[ "${REPLY}" =~ ^[Nn]$ ]]; then
      return 1
    fi
  fi

  return 0
}

local CURRENT_STEP_NAME=""
local STEP_PROGRESS_SPINNER_CHARS=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
local STEP_PROGRESS_SPINNER_CURRENT=0

# Width of the terminal the steps are displayed on, 0 when it can't be determined (e.g. output is not a terminal)
local TERM_COLUMNS=0

# The step name as displayed while the step is running
local STEP_FITTED_NAME=""

term::update_columns() {
  local TERM_SIZE

  TERM_COLUMNS=0

  if TERM_SIZE=$(stty size <&6 2>/dev/null) && [[ "${TERM_SIZE}" =~ ^[0-9]+\ ([0-9]+)$ ]]; then
    TERM_COLUMNS="${BASH_REMATCH[1]}"
  fi
}

# While a step is running, its line is rewritten with a carriage return, which can't erase a line that wrapped
# onto the next row of the terminal. The step name is shortened to stay on one row, with one column to spare
# so that the cursor doesn't wrap. The final line of a step is not affected, nothing is rewritten after it.
term::step::fit_name() {
  # Room left once " [ x ] " is displayed
  local STEP_NAME_ROOM=$((TERM_COLUMNS - 1 - 7))

  STEP_FITTED_NAME="${CURRENT_STEP_NAME}"

  if [[ "${TERM_COLUMNS}" -gt 0 ]] && [[ "${#STEP_FITTED_NAME}" -gt "${STEP_NAME_ROOM}" ]]; then
    if [[ "${STEP_NAME_ROOM}" -ge 2 ]]; then
      STEP_FITTED_NAME="${STEP_FITTED_NAME:0:STEP_NAME_ROOM-1}…"
    else
      STEP_FITTED_NAME=""
    fi
  fi
}

term::step::new() {
  CURRENT_STEP_NAME="$*"
  term::update_columns
  term::step::fit_name

  echo -en " $(ansi::styled "[   ]" "${ansi_stylenum[bright]}") ${STEP_FITTED_NAME}"
}

term::step::replace() {
  CURRENT_STEP_NAME="$*"
  term::update_columns
  term::step::fit_name

  echo -en "\r\033[K $(ansi::styled "[   ]" "${ansi_stylenum[bright]}") ${STEP_FITTED_NAME}"
}

term::step::progress() {
  local STEP_PROGRESS_TEXT=""

  term::step::fit_name

  if [[ -n "${1:-}" ]]; then
    local STEP_PROGRESS_LABEL="$*"

    if [[ "${TERM_COLUMNS}" -gt 0 ]]; then
      # Room left once " [ x ] ", the step name and " ()" are displayed
      local STEP_PROGRESS_ROOM=$((TERM_COLUMNS - 1 - 7 - ${#STEP_FITTED_NAME} - 3))

      if [[ "${#STEP_PROGRESS_LABEL}" -gt "${STEP_PROGRESS_ROOM}" ]]; then
        if [[ "${STEP_PROGRESS_ROOM}" -ge 2 ]]; then
          STEP_PROGRESS_LABEL="${STEP_PROGRESS_LABEL:0:STEP_PROGRESS_ROOM-1}…"
        else
          STEP_PROGRESS_LABEL=""
        fi
      fi
    fi

    if [[ -n "${STEP_PROGRESS_LABEL}" ]]; then
      STEP_PROGRESS_TEXT="$(ansi::styled " (${STEP_PROGRESS_LABEL})" "${ansi_stylenum[dim]}")"
    fi
  fi

  echo -en "\r $(ansi::styled "[" "${ansi_stylenum[bright]}") $(ansi::styled "${STEP_PROGRESS_SPINNER_CHARS[$STEP_PROGRESS_SPINNER_CURRENT]}" "${ansi_stylenum[dim]}") $(ansi::styled "]" "${ansi_stylenum[bright]}") ${STEP_FITTED_NAME}${STEP_PROGRESS_TEXT}\033[K"
  STEP_PROGRESS_SPINNER_CURRENT=$((STEP_PROGRESS_SPINNER_CURRENT + 1))

  if [[ "${STEP_PROGRESS_SPINNER_CURRENT}" -ge "${#STEP_PROGRESS_SPINNER_CHARS[@]}" ]]; then
    STEP_PROGRESS_SPINNER_CURRENT=0
  fi
}

term::step::complete() {
  echo -e "\r\033[K $(ansi::styled "[" "${ansi_stylenum[bright]}") $(ansi::styled "✓" "${ansi_stylenum[bright]}" "${ansi_colornum[green]}") $(ansi::styled "]" "${ansi_stylenum[bright]}") ${CURRENT_STEP_NAME}"
}

term::step::failed() {
  echo -e "\r\033[K $(ansi::styled "[" "${ansi_stylenum[bright]}") $(ansi::styled "✗" "${ansi_stylenum[bright]}" "${ansi_colornum[red]}") $(ansi::styled "]" "${ansi_stylenum[bright]}") ${CURRENT_STEP_NAME}"
}

term::step::skipped() {
  local STEP_SKIPPED_REASON=""

  if [[ -n "${1:-}" ]]; then
    STEP_SKIPPED_REASON="$(ansi::styled " ($*)" "${ansi_stylenum[dim]}")"
  fi

  echo -e "\r\033[K $(ansi::styled "[" "${ansi_stylenum[bright]}") $(ansi::styled "-" "${ansi_stylenum[dim]}") $(ansi::styled "]" "${ansi_stylenum[bright]}") ${CURRENT_STEP_NAME}${STEP_SKIPPED_REASON}"
}

term::step::failed_with_error() {
  term::step::failed
  echo

  term::error_with_dialog "$*"
}

# Prints an error, and also displays it in a dialog when running in GUI mode
term::error_with_dialog() {
  local ERROR_TEXT="$*"

  term::error "${ERROR_TEXT}" 1>&2

  if [[ "${_arg_ui_mode:-none}" == "kdialog" ]]; then
    kdialog --title "Error" \
      --error "${ERROR_TEXT}" 2>/dev/null
  elif [[ "${_arg_ui_mode:-none}" == "zenity" ]]; then
    zenity --error --text="${ERROR_TEXT}" --width=350 2>/dev/null
  fi
}

# Asks a yes/no question in a dialog, the answer is the exit status. Only meant for the GUI modes, the
# callers handle the terminal. Usage: term::dialog::yesno TEXT [TITLE] [WIDTH]
term::dialog::yesno() {
  local DIALOG_TEXT="${1:-}"
  local DIALOG_TITLE="${2:-}"
  local DIALOG_WIDTH="${3:-}"

  if [[ "${_arg_ui_mode:-none}" == "kdialog" ]]; then
    local KDIALOG_ARGS=(--yesno "${DIALOG_TEXT}")
    [[ -z "${DIALOG_TITLE}" ]] || KDIALOG_ARGS=(--title "${DIALOG_TITLE}" "${KDIALOG_ARGS[@]}")
    kdialog "${KDIALOG_ARGS[@]}" &>/dev/null
  elif [[ "${_arg_ui_mode:-none}" == "zenity" ]]; then
    local ZENITY_ARGS=(--question --no-markup)
    [[ -z "${DIALOG_TITLE}" ]] || ZENITY_ARGS+=("--title=${DIALOG_TITLE}")
    [[ -z "${DIALOG_WIDTH}" ]] || ZENITY_ARGS+=("--width=${DIALOG_WIDTH}")
    zenity "${ZENITY_ARGS[@]}" "--text=${DIALOG_TEXT}" &>/dev/null
  else
    return 1
  fi
}

# Shows a message in a dialog, and does nothing in terminal mode. A dialog that cannot be shown is not an
# error. Usage: term::dialog::msgbox TEXT [TITLE] [WIDTH]
term::dialog::msgbox() {
  local DIALOG_TEXT="${1:-}"
  local DIALOG_TITLE="${2:-}"
  local DIALOG_WIDTH="${3:-}"

  if [[ "${_arg_ui_mode:-none}" == "kdialog" ]]; then
    local KDIALOG_ARGS=(--msgbox "${DIALOG_TEXT}")
    [[ -z "${DIALOG_TITLE}" ]] || KDIALOG_ARGS=(--title "${DIALOG_TITLE}" "${KDIALOG_ARGS[@]}")
    kdialog "${KDIALOG_ARGS[@]}" &>/dev/null || true
  elif [[ "${_arg_ui_mode:-none}" == "zenity" ]]; then
    local ZENITY_ARGS=(--info --no-markup)
    [[ -z "${DIALOG_TITLE}" ]] || ZENITY_ARGS+=("--title=${DIALOG_TITLE}")
    [[ -z "${DIALOG_WIDTH}" ]] || ZENITY_ARGS+=("--width=${DIALOG_WIDTH}")
    zenity "${ZENITY_ARGS[@]}" "--text=${DIALOG_TEXT}" &>/dev/null || true
  fi
}

# Progress dialog. With kdialog it is driven over D-Bus, with zenity it reads "percent" and "# label" lines
# from its standard input, which the caller pipes to term::progress_dialog::sink. The dialog is opened in the
# calling shell, as the address is kept for the subshells of the progress pipeline.
local PROGRESS_DIALOG_KDIALOG_ADDRESS=()

# Usage: term::progress_dialog::open TEXT [cancellable]
term::progress_dialog::open() {
  local DIALOG_TEXT="${1:-}"
  local IS_CANCELLABLE="${2:-}"

  if [[ "${_arg_ui_mode:-none}" != "kdialog" ]]; then
    return 0
  fi

  read -ra PROGRESS_DIALOG_KDIALOG_ADDRESS < <(kdialog --title "${CURRENT_STEP_NAME}" --progressbar "${DIALOG_TEXT}" 0 2>/dev/null)

  if [[ "${IS_CANCELLABLE}" != "cancellable" ]]; then
    busctl --user call "${PROGRESS_DIALOG_KDIALOG_ADDRESS[@]}" "org.kde.kdialog.ProgressDialog" "showCancelButton" b "false" 2>/dev/null || true
  fi
}

# Sets the label and, if PERCENT is given, the bar. The bar is PERCENT of 100 unless MAXIMUM and VALUE are
# given. It fails when kdialog can no longer be reached, which means the user closed the dialog.
# Usage: term::progress_dialog::update LABEL [PERCENT [MAXIMUM VALUE]]
term::progress_dialog::update() {
  local DIALOG_TEXT="${1:-}"
  local PERCENT="${2:-}"
  local MAXIMUM="${3:-100}"
  local VALUE="${4:-${PERCENT}}"

  if [[ "${_arg_ui_mode:-none}" == "kdialog" ]]; then
    local ESCAPED_DIALOG_TEXT
    ESCAPED_DIALOG_TEXT="$(echo -e "${DIALOG_TEXT}")"

    if [[ -n "${PERCENT}" ]]; then
      busctl --user set-property "${PROGRESS_DIALOG_KDIALOG_ADDRESS[@]}" "org.kde.kdialog.ProgressDialog" "maximum" i "${MAXIMUM}" 2>/dev/null || return 1
      busctl --user set-property "${PROGRESS_DIALOG_KDIALOG_ADDRESS[@]}" "org.kde.kdialog.ProgressDialog" "value" i "${VALUE}" 2>/dev/null || return 1
    fi

    busctl --user call "${PROGRESS_DIALOG_KDIALOG_ADDRESS[@]}" "org.kde.kdialog.ProgressDialog" "setLabelText" s "${ESCAPED_DIALOG_TEXT}" 2>/dev/null || return 1
  elif [[ "${_arg_ui_mode:-none}" == "zenity" ]]; then
    if [[ -n "${PERCENT}" ]]; then
      echo "${PERCENT}"
    fi

    echo "# ${DIALOG_TEXT}"
  fi
}

# Switches the bar to its busy state, as no progress is known, and optionally changes the label first
# Usage: term::progress_dialog::pulse [LABEL]
term::progress_dialog::pulse() {
  local DIALOG_TEXT="${1:-}"

  if [[ "${_arg_ui_mode:-none}" != "kdialog" ]]; then
    return 0
  fi

  if [[ -n "${DIALOG_TEXT}" ]]; then
    busctl --user call "${PROGRESS_DIALOG_KDIALOG_ADDRESS[@]}" "org.kde.kdialog.ProgressDialog" "setLabelText" s "${DIALOG_TEXT}" 2>/dev/null || return 1
  fi

  busctl --user set-property "${PROGRESS_DIALOG_KDIALOG_ADDRESS[@]}" "org.kde.kdialog.ProgressDialog" "maximum" i 0 2>/dev/null || return 1
}

# Succeeds when the user cancelled the kdialog dialog, or closed it
term::progress_dialog::was_cancelled() {
  if [[ "${_arg_ui_mode:-none}" != "kdialog" ]]; then
    return 1
  fi

  local WAS_CANCELLED
  WAS_CANCELLED="$(busctl --user call "${PROGRESS_DIALOG_KDIALOG_ADDRESS[@]}" "org.kde.kdialog.ProgressDialog" "wasCancelled" 2>/dev/null || echo "b true")"

  [[ "${WAS_CANCELLED}" == "b true" ]]
}

term::progress_dialog::close() {
  if [[ "${_arg_ui_mode:-none}" == "kdialog" ]]; then
    busctl --user call "${PROGRESS_DIALOG_KDIALOG_ADDRESS[@]}" "org.kde.kdialog.ProgressDialog" "close" 2>/dev/null || true
  fi
}

# Last command of the progress pipeline. It shows the zenity dialog fed by term::progress_dialog::update,
# or discards what is left when there is no zenity. The extra arguments go to zenity --progress.
# Usage: ... | term::progress_dialog::sink TEXT [ZENITY_ARGS...]
term::progress_dialog::sink() {
  local DIALOG_TEXT="${1:-}"
  shift || true

  if [[ "${_arg_ui_mode:-none}" == "zenity" ]]; then
    zenity --progress "--text=${DIALOG_TEXT}" --auto-close "$@" 2>/dev/null
  else
    cat - >/dev/null
  fi
}

xdgdirs::get_user_dir() {
  local USER_DIR_NAME="${1}"

  if command -v xdg-user-dir &>/dev/null; then
    local USER_DIR_RETURNED
    USER_DIR_RETURNED=$(xdg-user-dir "${USER_DIR_NAME}")

    if [[ -d "${USER_DIR_RETURNED}" ]]; then
      echo "${USER_DIR_RETURNED}"
    fi

    return 0
  fi

  local USER_DIR_VAR_NAME="XDG_${USER_DIR_NAME}_DIR"
  if [[ -n "${!USER_DIR_VAR_NAME:-}" ]] && [[ -d "${!USER_DIR_VAR_NAME}" ]]; then
    echo "${!USER_DIR_VAR_NAME}"
  fi
}

# Escapes a path to be used as a quoted argument of the Exec key. Within double quotes, the Desktop Entry
# specification requires a backslash before the characters '"', '`', '$' and '\\', and the backslash of the
# string value itself must be doubled on top of that. '%' introduces a field code, and is doubled.
xdgdirs::escape_exec_argument() {
  local VALUE="${1:-}"

  VALUE="${VALUE//\\/\\\\\\\\}"
  VALUE="${VALUE//\"/\\\\\"}"
  VALUE="${VALUE//\`/\\\\\`}"
  VALUE="${VALUE//\$/\\\\\$}"
  VALUE="${VALUE//%/%%}"

  printf '%s' "${VALUE}"
}

helper::progress::run_with_progress() {
  local LAST_UPDATE=""

  local PROGRESS_MESSAGE="${1}"
  shift

  while IFS= read -r UPDATE; do
    term::step::progress "${PROGRESS_MESSAGE}" >&6
    LAST_UPDATE="${UPDATE}"
  done < <(helper::progress::make_consistant "$@")

  echo "${LAST_UPDATE}"
}

# This function throttles the output to avoid buffering, while also making sure the last update
# is repeated at a set frequency for the throbber to work
helper::progress::make_consistant() {
  local LAST_UPDATE=""
  local CURRENT_UPDATE=""

  exec 3< <(helper::run_as_proc_group "$@")
  local PROC_SUB_PID=$!

  trap '[ -n "${PROC_SUB_PID:-}" ] && { kill -- "${PROC_SUB_PID}"; }' EXIT

  local CAN_WRITE="y"
  trap 'CAN_WRITE="n"' SIGPIPE

  # When read times out in the middle of a line, the part already consumed is returned in the variable, and
  # the rest of the line comes with the next read. It is carried over, or the start of the line would be lost.
  local PARTIAL_UPDATE=""

  while kill -0 "${PROC_SUB_PID}" 2>/dev/null; do
    while IFS= read -r -u 3 -t 0.001 CURRENT_UPDATE; do
      LAST_UPDATE="${PARTIAL_UPDATE}${CURRENT_UPDATE}"
      PARTIAL_UPDATE=""
    done

    PARTIAL_UPDATE+="${CURRENT_UPDATE}"

    if [[ "${CAN_WRITE}" == "y" ]]; then
      echo "${LAST_UPDATE}" 2>/dev/null
      sleep "${PROGRESS_MIN_REFRESH}"
    else
      break
    fi
  done

  trap - SIGPIPE EXIT

  local EXIT_CODE=1

  if [[ "${CAN_WRITE}" == "y" ]]; then
    # Final drain of remaining data
    while IFS= read -r -u 3 CURRENT_UPDATE; do
      LAST_UPDATE="${PARTIAL_UPDATE}${CURRENT_UPDATE}"
      PARTIAL_UPDATE=""
    done
    echo "${LAST_UPDATE}"
  else
    if kill -0 "${PROC_SUB_PID}" 2>/dev/null; then
      # Explicitly kill if the loop exited due to CAN_WRITE="n"
      kill -TERM -- "${PROC_SUB_PID}"
    fi

    return 1
  fi

  wait "${PROC_SUB_PID}"
  EXIT_CODE=$?

  exec 3<&-
  return "${EXIT_CODE}"
}

helper::run_as_proc_group() {
  set -m
  { "$@"; } &
  set +m
  local PROC_SUB_PID=$!

  trap 'trap - EXIT; [[ -n "${PROC_SUB_PID:-}" ]] && { kill -- -"${PROC_SUB_PID}"; wait "${PROC_SUB_PID}"; return $?; }' EXIT

  wait "${PROC_SUB_PID}"
  local EXIT_CODE=$?
  trap - EXIT
  return "${EXIT_CODE}"
}

# Reads the n-th (1-based) field of a separated string, the separator defaults to "|"
helper::string::field() {
  local VALUE="${1:-}"
  local FIELD_INDEX="${2:-1}"
  local SEPARATOR="${3:-|}"

  local i
  for ((i = 1; i < FIELD_INDEX; i++)); do
    if [[ "${VALUE}" != *"${SEPARATOR}"* ]]; then
      return 0
    fi

    VALUE="${VALUE#*"${SEPARATOR}"}"
  done

  echo "${VALUE%%"${SEPARATOR}"*}"
}
