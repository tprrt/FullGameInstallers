# shellcheck shell=bash

step::ut2004_unpack_cabs() {
  term::step::new "Unpack Install CABs"

  local STAGING_PATH="${_arg_destination%/}/Installer/.staging"
  local CABS_PATH="${STAGING_PATH}/Cabs"
  local TARGET_PATH="${STAGING_PATH}/Data"

  if [[ -d "${CABS_PATH}" ]]; then
    rm -rf "${CABS_PATH}" &>/dev/null || {
      term::step::failed_with_error "User does not have permission to create staging folder. Aborting installation."
      return 77 #E_PERM
    }
  fi

  # Create the cabs folder
  mkdir -p "${CABS_PATH}" &>/dev/null || {
    term::step::failed_with_error "User does not have permission to create staging folder. Aborting installation."
    return 77 #E_PERM
  }

  {
    local DISK_FOLDER
    for DISK_FOLDER in "${STAGING_PATH}"/Disk*; do
      if [[ ! -d "${DISK_FOLDER}" ]]; then
        continue
      fi

      local DISK_CAB
      for DISK_CAB in "${DISK_FOLDER}"/*.cab; do
        if [[ ! -f "${DISK_CAB}" ]]; then
          continue
        fi

        local DISK_CAB_BASE="${DISK_CAB##*/}"
        ln -fs "${DISK_CAB}" "${CABS_PATH}/${DISK_CAB_BASE}"
      done

      for DISK_CAB in "${DISK_FOLDER}"/*.hdr; do
        if [[ ! -f "${DISK_CAB}" ]]; then
          continue
        fi

        local DISK_CAB_BASE="${DISK_CAB##*/}"
        ln -fs "${DISK_CAB}" "${CABS_PATH}/${DISK_CAB_BASE}"
      done
    done
  } || {
    term::step::failed_with_error "Failed to prepare cabs for unpacking. Aborting installation."
    return 1
  }

  if [[ ! -d "${TARGET_PATH}" ]]; then
    # Create the installation folder
    mkdir -p "${TARGET_PATH}" &>/dev/null || {
      term::step::failed_with_error "User does not have permission to create staging folder. Aborting installation."
      return 77 #E_PERM
    }
  fi

  term::progress_dialog::open "Unpacking install CABs..."

  helper::progress::make_consistant __step::ut2004_unpack_cabs::run "${CABS_PATH}/data1.cab" "${TARGET_PATH}" | while IFS= read -r UNPACK_PROGRESS; do
    if [[ -z "${UNPACK_PROGRESS}" ]]; then
      term::step::progress "" >&6

      term::progress_dialog::pulse || true
      continue
    fi

    local TOTAL_FILES PERCENT CURRENT_FILE_INDEX FILE_NAME

    TOTAL_FILES=$(helper::string::field "${UNPACK_PROGRESS}" 1)
    PERCENT=$(helper::string::field "${UNPACK_PROGRESS}" 2)
    CURRENT_FILE_INDEX=$(helper::string::field "${UNPACK_PROGRESS}" 3)
    FILE_NAME=$(helper::string::field "${UNPACK_PROGRESS}" 4)

    term::step::progress "${CURRENT_FILE_INDEX} of ${TOTAL_FILES} - ${FILE_NAME}" >&6

    local DIALOG_TEXT="Unpacking ${FILE_NAME} (${CURRENT_FILE_INDEX} of ${TOTAL_FILES})"

    term::progress_dialog::update "${DIALOG_TEXT}" "${PERCENT}" "${TOTAL_FILES}" "${CURRENT_FILE_INDEX}" || true
  done | term::progress_dialog::sink "Unpacking install CABs..." --percentage=0 --no-cancel --time-remaining || {
    term::progress_dialog::close

    term::step::failed_with_error "Failed to unpack CABs. Installation aborted."
    return 1
  }

  term::progress_dialog::close

  rm -rf "${CABS_PATH}" &>/dev/null || {
    term::step::failed_with_error "User does not have permission to remove temporary staging folder for CABs. Aborting installation."
    return 77 #E_PERM
  }

  term::step::complete
}

__step::ut2004_unpack_cabs::run() {
  local CAB_FILE="${1:-}"
  local WRITE_TO_PATH="${2:-}"

  # The output of unshield is parsed below, it must not be translated or use localized number formats
  local -x LC_ALL=C

  local UNSHIELD_BIN="unshield"

  if [[ "${DOWNLOADS_FILENAME_LIST[unshield]:-}" == "unshield" ]]; then
    UNSHIELD_BIN="${_arg_destination%/}/Installer/unshield"

    if [[ ! -f "${UNSHIELD_BIN}" ]]; then
      term::error "unshield binary not present"
      return 1
    fi

    chmod +x "${UNSHIELD_BIN}"
  fi

  # If the file count cannot be determined, extraction still proceeds without a percentage
  local RAW_TOTAL_FILES_TO_EXTRACT TOTAL_FILES_TO_EXTRACT=0
  RAW_TOTAL_FILES_TO_EXTRACT=$("${UNSHIELD_BIN}" l "${CAB_FILE}" | tail -n1) || true

  local LINE_MATCH_REGEX='^\s*([0-9]+)'

  if [[ "${RAW_TOTAL_FILES_TO_EXTRACT}" =~ ${LINE_MATCH_REGEX} ]]; then
    TOTAL_FILES_TO_EXTRACT="${BASH_REMATCH[1]}"
  fi

  local CURRENT_FILE_INDEX=0
  local EXTRACTING_MATCH_REGEX='^\s*extracting:\s+(.+)$'

  "${UNSHIELD_BIN}" -d "${WRITE_TO_PATH}" x "${CAB_FILE}" |
    while IFS= read -r UNPACK_PROGRESS; do
      if [[ "${UNPACK_PROGRESS}" =~ ${EXTRACTING_MATCH_REGEX} ]]; then
        local CURRENT_FILE="${BASH_REMATCH[1]##*/}"

        local PERCENT_PROGRESS=0
        if [[ "${TOTAL_FILES_TO_EXTRACT}" -gt 0 ]]; then
          PERCENT_PROGRESS="$(((CURRENT_FILE_INDEX * 100) / TOTAL_FILES_TO_EXTRACT))"
        fi
        CURRENT_FILE_INDEX=$((CURRENT_FILE_INDEX + 1))

        echo "${TOTAL_FILES_TO_EXTRACT}|${PERCENT_PROGRESS}|${CURRENT_FILE_INDEX}|${CURRENT_FILE}"
      fi
    done
}
