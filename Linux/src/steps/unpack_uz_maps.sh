# shellcheck shell=bash

step::unpack_uz_maps() {
  term::step::new "Unpack Maps"

  term::progress_dialog::open "Unpacking maps..."

  helper::progress::make_consistant __step::unpack_uz_maps::run | while IFS= read -r UNPACK_PROGRESS; do
    if [[ -z "${UNPACK_PROGRESS}" ]]; then
      term::step::progress "" >&6

      term::progress_dialog::pulse || true
      continue
    fi

    local TOTAL_FILES PERCENT CURRENT_FILE_INDEX MAP_NAME

    TOTAL_FILES=$(helper::string::field "${UNPACK_PROGRESS}" 1)
    PERCENT=$(helper::string::field "${UNPACK_PROGRESS}" 2)
    CURRENT_FILE_INDEX=$(helper::string::field "${UNPACK_PROGRESS}" 3)
    MAP_NAME=$(helper::string::field "${UNPACK_PROGRESS}" 4)

    term::step::progress "${CURRENT_FILE_INDEX} of ${TOTAL_FILES} - ${MAP_NAME}" >&6

    local DIALOG_TEXT="Unpacking ${MAP_NAME} (${CURRENT_FILE_INDEX} of ${TOTAL_FILES})"

    term::progress_dialog::update "${DIALOG_TEXT}" "${PERCENT}" "${TOTAL_FILES}" "${CURRENT_FILE_INDEX}" || true
  done | term::progress_dialog::sink "Unpacking maps..." --percentage=0 --no-cancel --time-remaining || {
    term::progress_dialog::close

    term::step::failed_with_error "Failed to unpack all maps. Installation aborted."
    return 1
  }

  term::progress_dialog::close

  term::step::complete
}

__step::unpack_uz_maps::run() {
  local UCC_BIN_PATH="${_arg_destination%/}/System${UE_SYSTEM_FOLDER_SUFFIX:-}/ucc-bin${ARCHITECTURE_BINARY_SUFFIX}"

  local MAP_FILES=()
  local MAP_FILE

  for MAP_FILE in "${_arg_destination%/}/Maps"/*.unr.uz; do
    if [[ ! -f "${MAP_FILE}" ]]; then
      continue
    fi

    local MAP_BASENAME="${MAP_FILE##*/}"
    MAP_FILES+=("${MAP_BASENAME}")
  done

  local TOTAL_MAP_FILES="${#MAP_FILES[@]}"
  local MAP_FILES_PROCESSED=0

  for MAP_FILE in "${MAP_FILES[@]}"; do
    local MAP_BASENAME_UNCOMPRESSED="${MAP_FILE%.uz}"

    local COMPRESSED_FILE="${_arg_destination%/}/Maps/${MAP_FILE}"
    local DECOMPRESS_STAGING="${_arg_destination%/}/System${UE_SYSTEM_FOLDER_SUFFIX:-}/${MAP_BASENAME_UNCOMPRESSED}"
    local DECOMPRESS_TARGET="${_arg_destination%/}/Maps/${MAP_BASENAME_UNCOMPRESSED}"

    local PERCENT_PROGRESS="$(((MAP_FILES_PROCESSED * 100) / TOTAL_MAP_FILES))"
    MAP_FILES_PROCESSED=$((MAP_FILES_PROCESSED + 1))

    echo "${TOTAL_MAP_FILES}|${PERCENT_PROGRESS}|${MAP_FILES_PROCESSED}|${MAP_BASENAME_UNCOMPRESSED}"

    if [[ -f "${DECOMPRESS_TARGET}" ]]; then
      rm -f "${COMPRESSED_FILE}"
    else
      "${UCC_BIN_PATH}" decompress "../Maps/${MAP_FILE}" -nohomedir &>/dev/null || {
        return 1
      }

      if [[ -f "${DECOMPRESS_STAGING}" ]]; then
        { mv -f "${DECOMPRESS_STAGING}" "${DECOMPRESS_TARGET}" && rm -f "${COMPRESSED_FILE}"; } || {
          return 1
        }
      else
        return 1
      fi
    fi
  done
}
