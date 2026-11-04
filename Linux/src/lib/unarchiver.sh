# shellcheck shell=bash

local UNARCHIVER_BIN=""
if command -v "7z" &>/dev/null; then
  UNARCHIVER_BIN="7z"
elif command -v "7zz" &>/dev/null; then
  UNARCHIVER_BIN="7zz"
fi

unarchiver::unarchive_file() {
  local ITEM_NAME="${1:-}"
  local ARCHIVE_PATH="${2:-}"
  local TARGET_PATH="${3:-}"
  local IGNORE_PATTERNS_VAR_NAME="${4:-}"
  local IGNORE_PATTERNS_RECURSIVE_VAR_NAME="${5:-}"

  if [[ -z "${ARCHIVE_PATH}" ]] || [[ -z "${TARGET_PATH}" ]]; then
    return 1
  fi

  if [[ ! -f "${ARCHIVE_PATH}" ]]; then
    return 1
  fi

  term::step::new "Extract ${ITEM_NAME}"

  local IS_TARBALL="n"
  if __unarchiver::is_tarball "${ARCHIVE_PATH}"; then
    IS_TARBALL="y"
  else
    # Detect the 7z version here, as the extraction runs in a subshell where the result couldn't be cached
    __unarchiver::read_7z_version
  fi

  local UNARCHIVE_PROGRESS

  term::progress_dialog::open "Extracting ${ITEM_NAME}..."

  local UNARCHIVE_ZENITY_ARGS=(--percentage=0 --time-remaining)
  if [[ "${IS_TARBALL}" == "y" ]]; then
    UNARCHIVE_ZENITY_ARGS=(--pulsate)
  fi

  helper::progress::make_consistant __unarchiver::unarchive_file_with_progress "${ARCHIVE_PATH}" "${TARGET_PATH}" "${IGNORE_PATTERNS_VAR_NAME}" "${IGNORE_PATTERNS_RECURSIVE_VAR_NAME}" |
    while IFS= read -r UNARCHIVE_PROGRESS; do
      if [[ -z "${UNARCHIVE_PROGRESS}" ]]; then
        term::step::progress "" >&6

        term::progress_dialog::pulse || true
        continue
      fi

      local PROGRESS_TEXT="${UNARCHIVE_PROGRESS}"
      if [[ "${IS_TARBALL}" == "n" ]]; then
        PROGRESS_TEXT="${PROGRESS_TEXT}%"
      fi

      term::step::progress "${PROGRESS_TEXT}" >&6

      local DIALOG_TEXT="Extracting ${ITEM_NAME} (${PROGRESS_TEXT})"

      # A tarball has no percentage, only the label changes
      if [[ "${IS_TARBALL}" == "n" ]]; then
        term::progress_dialog::update "${DIALOG_TEXT}" "${UNARCHIVE_PROGRESS}" || true
      else
        term::progress_dialog::update "${DIALOG_TEXT}" || true
      fi
    done | term::progress_dialog::sink "Extracting ${ITEM_NAME}..." --no-cancel "${UNARCHIVE_ZENITY_ARGS[@]}"

  local UNARCHIVE_STATUS="${PIPESTATUS[0]}"

  term::progress_dialog::close

  if [[ "${UNARCHIVE_STATUS}" -ne 0 ]]; then
    term::step::failed
    return "${UNARCHIVE_STATUS}"
  fi

  term::step::complete
}

local SEVENZ_VERSION_MAJOR="0"
local SEVENZ_VERSION_MINOR="0"
local SEVENZ_REQUIRE_SNLD="no"

__unarchiver::read_7z_version() {
  if [[ "${SEVENZ_VERSION_MAJOR}" -gt 0 ]]; then
    return 0
  fi

  # Matches banners such as "7-Zip 25.01 (x64)", "7-Zip (z) 25.01 (x64)" and "7-Zip [64] 16.02"
  local SEZENV_VERSION_REGEX='^7-Zip( \[[0-9a-zA-Z_-]+\]| \([0-9a-zA-Z_-]+\))? ([0-9]+)(\.([0-9]+)| |:)'

  local SEVENZ_OUTPUT_LINE
  while IFS= read -r SEVENZ_OUTPUT_LINE; do
    if [[ "${SEVENZ_VERSION_MAJOR}" -gt 0 ]]; then
      continue
    fi

    if [[ "${SEVENZ_OUTPUT_LINE}" =~ ${SEZENV_VERSION_REGEX} ]]; then
      # Force base 10, as minor versions such as "08" would otherwise be read as invalid octal
      SEVENZ_VERSION_MAJOR="$((10#${BASH_REMATCH[2]}))"
      SEVENZ_VERSION_MINOR="$((10#${BASH_REMATCH[4]:-0}))"

      if [[ "${SEVENZ_VERSION_MAJOR}" -gt 25 ]]; then
        SEVENZ_REQUIRE_SNLD="yes"
      elif [[ "${SEVENZ_VERSION_MAJOR}" -eq 25 ]] && [[ "${SEVENZ_VERSION_MINOR}" -ge 1 ]]; then
        SEVENZ_REQUIRE_SNLD="yes"
      fi
    fi
  done < <("${UNARCHIVER_BIN}" 2>&1)
}

__unarchiver::is_tarball() {
  local ARCHIVE_PATH="${1:-}"

  local ARCHIVE_FILENAME="${ARCHIVE_PATH##*/}"

  case "${ARCHIVE_FILENAME}" in
  *.tar.gz | *.tgz)
    return 0
    ;;
  *.tar.bz2 | *.tbz)
    return 0
    ;;
  *.tar.xz | *.txz)
    return 0
    ;;
  *.tar.zst | *.tar.zstd)
    return 0
    ;;
  esac

  return 1
}

__unarchiver::unarchive_file_with_progress() {
  local ARCHIVE_PATH="${1:-}"
  local TARGET_PATH="${2:-}"
  local IGNORE_PATTERNS_VAR_NAME="${3:-}"
  local IGNORE_PATTERNS_RECURSIVE_VAR_NAME="${4:-}"

  if [[ -z "${ARCHIVE_PATH}" ]] || [[ -z "${TARGET_PATH}" ]]; then
    return 1
  fi

  local IS_TARBALL="n"
  if __unarchiver::is_tarball "${ARCHIVE_PATH}"; then
    IS_TARBALL="y"
  fi

  # The progress output of tar and 7z is parsed below, it must not be translated or use localized number formats
  local -x LC_ALL=C

  local UNARCHIVE_PROGRESS
  if [[ "${IS_TARBALL}" == "y" ]]; then
    local TAR_REGEX='^tar:\s+r:\s+[0-9]+\s+\((.+)\)$'

    __unarchiver::unarchive_file::call_tar \
      "${ARCHIVE_PATH}" "${TARGET_PATH}" \
      "${IGNORE_PATTERNS_VAR_NAME}" "${IGNORE_PATTERNS_RECURSIVE_VAR_NAME}" |
      while IFS= read -r UNARCHIVE_PROGRESS; do
        if [[ "${UNARCHIVE_PROGRESS}" =~ ${TAR_REGEX} ]]; then
          echo "${BASH_REMATCH[1]}"
        else
          echo "${UNARCHIVE_PROGRESS}" 1>&2
        fi
      done
    return "${PIPESTATUS[0]}"
  else
    local SEVENZ_REGEX='^\s*([0-9]+)%'

    __unarchiver::unarchive_file::call_7z \
      "${ARCHIVE_PATH}" "${TARGET_PATH}" \
      "${IGNORE_PATTERNS_VAR_NAME}" "${IGNORE_PATTERNS_RECURSIVE_VAR_NAME}" |
      stdbuf -oL -- tr $'\b\r' $'\n\n' |
      while IFS= read -r UNARCHIVE_PROGRESS; do
        if [[ "${UNARCHIVE_PROGRESS}" =~ ${SEVENZ_REGEX} ]]; then
          echo "${BASH_REMATCH[1]}"
        fi
      done
    return "${PIPESTATUS[0]}"
  fi
}

__unarchiver::unarchive_file::call_7z() {
  local ARCHIVE_PATH="${1:-}"
  local TARGET_PATH="${2:-}"

  if [[ -z "${ARCHIVE_PATH}" ]] || [[ -z "${TARGET_PATH}" ]]; then
    return 1
  fi

  local IGNORE_PATTERNS=()
  local IGNORE_PATTERNS_VAR_NAME="${3:-}"
  if [[ -n "${IGNORE_PATTERNS_VAR_NAME}" ]]; then
    local IGNORE_PATTERN_VAR_REF="${IGNORE_PATTERNS_VAR_NAME}[@]"
    IGNORE_PATTERNS=("${!IGNORE_PATTERN_VAR_REF}")
  fi

  local IGNORE_PATTERNS_RECURSIVE=()
  local IGNORE_PATTERNS_RECURSIVE_VAR_NAME="${4:-}"
  if [[ -n "${IGNORE_PATTERNS_RECURSIVE_VAR_NAME}" ]]; then
    local IGNORE_PATTERN_RECURSIVE_VAR_REF="${IGNORE_PATTERNS_RECURSIVE_VAR_NAME}[@]"
    IGNORE_PATTERNS_RECURSIVE=("${!IGNORE_PATTERN_RECURSIVE_VAR_REF}")
  fi

  __unarchiver::read_7z_version
  local SEZENZ_ARGS=()

  SEZENZ_ARGS=("x" "${ARCHIVE_PATH}" "-y" "-bsp1" "-bso0" "-bse2" "-aoa" "-o${TARGET_PATH}")

  if [[ "${SEVENZ_REQUIRE_SNLD}" == "yes" ]]; then
    SEZENZ_ARGS+=("-snld")
  else
    SEZENZ_ARGS+=("-snl")
  fi

  local IGNORE
  for IGNORE in "${IGNORE_PATTERNS[@]}"; do
    SEZENZ_ARGS+=("-x!${IGNORE}")
  done

  for IGNORE in "${IGNORE_PATTERNS_RECURSIVE[@]}"; do
    SEZENZ_ARGS+=("-xr!${IGNORE}")
  done

  "${UNARCHIVER_BIN}" "${SEZENZ_ARGS[@]}"
}

__unarchiver::unarchive_file::call_tar() {
  local ARCHIVE_PATH="${1:-}"
  local TARGET_PATH="${2:-}"

  if [[ -z "${ARCHIVE_PATH}" ]] || [[ -z "${TARGET_PATH}" ]]; then
    return 1
  fi

  local IGNORE_PATTERNS=()
  local IGNORE_PATTERNS_VAR_NAME="${3:-}"
  if [[ -n "${IGNORE_PATTERNS_VAR_NAME}" ]]; then
    local IGNORE_PATTERN_VAR_REF="${IGNORE_PATTERNS_VAR_NAME}[@]"
    IGNORE_PATTERNS=("${!IGNORE_PATTERN_VAR_REF}")
  fi

  local IGNORE_PATTERNS_RECURSIVE=()
  local IGNORE_PATTERNS_RECURSIVE_VAR_NAME="${4:-}"
  if [[ -n "${IGNORE_PATTERNS_RECURSIVE_VAR_NAME}" ]]; then
    local IGNORE_PATTERN_RECURSIVE_VAR_REF="${IGNORE_PATTERNS_RECURSIVE_VAR_NAME}[@]"
    IGNORE_PATTERNS_RECURSIVE=("${!IGNORE_PATTERN_RECURSIVE_VAR_REF}")
  fi

  local TAR_ARGS=()

  TAR_ARGS=("xf" "${ARCHIVE_PATH}" "--checkpoint=10" '--checkpoint-action=echo=%{r}T' "--overwrite" "-C" "${TARGET_PATH}")

  local IGNORE
  for IGNORE in "${IGNORE_PATTERNS[@]}"; do
    TAR_ARGS+=("--exclude=${IGNORE}")
  done

  for IGNORE in "${IGNORE_PATTERNS_RECURSIVE[@]}"; do
    TAR_ARGS+=("--exclude=${IGNORE}")
  done

  tar "${TAR_ARGS[@]}" 2>&1
}
