# shellcheck shell=bash

# The install manifest lists what the installer created outside of the game archives, so that an
# uninstall knows what it may remove. One record per line, "<kind><TAB><value>", parsed and never sourced:
#
#   version              1
#   product              UT2004
#   destination          /home/user/.local/share/OldUnreal/UT2004
#   destination-created  yes
#   file                 /home/user/.local/share/applications/OldUnreal-UT2004.desktop
#   dir                  /home/user/.local/share/OldUnreal/UT2004/.wine-unrealed
local MANIFEST_FILENAME=".oldunreal-install"
local MANIFEST_FORMAT_VERSION="1"

# Entries recorded by this run, as "<kind><TAB><path>"
local MANIFEST_NEW_ENTRIES=()

# Content of the manifest loaded by manifest::read
local MANIFEST_PRODUCT=""
local MANIFEST_DESTINATION=""
local MANIFEST_DESTINATION_CREATED="no"
local MANIFEST_ENTRIES=()

# Remembers a file or a folder created by the installer. Always succeeds: failing to track an entry
# must not stop an installation.
manifest::record() {
  local ENTRY_KIND="${1:-}"
  local ENTRY_PATH="${2:-}"

  if [[ "${ENTRY_KIND}" != "file" ]] && [[ "${ENTRY_KIND}" != "dir" ]]; then
    return 0
  fi

  if [[ "${ENTRY_PATH}" != /* ]] || [[ "${ENTRY_PATH}" == *$'\t'* ]] || [[ "${ENTRY_PATH}" == *$'\n'* ]]; then
    echo "Warning: ${ENTRY_PATH} cannot be recorded in the install manifest, it will not be removed by an uninstall." 1>&2
    return 0
  fi

  MANIFEST_NEW_ENTRIES+=("${ENTRY_KIND}"$'\t'"${ENTRY_PATH}")
}

# Loads a manifest into the MANIFEST_* variables.
# Returns 1 if it can't be read, and 2 if it isn't a manifest this version understands.
manifest::read() {
  local MANIFEST_FILE_PATH="${1:-}"

  MANIFEST_PRODUCT=""
  MANIFEST_DESTINATION=""
  MANIFEST_DESTINATION_CREATED="no"
  MANIFEST_ENTRIES=()

  if [[ ! -f "${MANIFEST_FILE_PATH}" ]] || [[ ! -r "${MANIFEST_FILE_PATH}" ]]; then
    return 1
  fi

  local RECORD_KIND RECORD_VALUE
  local HAS_VERSION="no"

  while IFS=$'\t' read -r RECORD_KIND RECORD_VALUE || [[ -n "${RECORD_KIND}" ]]; do
    case "${RECORD_KIND}" in
    version)
      if [[ "${RECORD_VALUE}" != "${MANIFEST_FORMAT_VERSION}" ]]; then
        return 2
      fi
      HAS_VERSION="yes"
      ;;
    product)
      MANIFEST_PRODUCT="${RECORD_VALUE}"
      ;;
    destination)
      MANIFEST_DESTINATION="${RECORD_VALUE}"
      ;;
    destination-created)
      if [[ "${RECORD_VALUE}" == "yes" ]]; then
        MANIFEST_DESTINATION_CREATED="yes"
      fi
      ;;
    file | dir)
      MANIFEST_ENTRIES+=("${RECORD_KIND}"$'\t'"${RECORD_VALUE}")
      ;;
    esac
    # Other records are ignored, so a newer installer can add some without breaking this one
  done <"${MANIFEST_FILE_PATH}"

  if [[ "${HAS_VERSION}" != "yes" ]] || [[ -z "${MANIFEST_PRODUCT}" ]] || [[ -z "${MANIFEST_DESTINATION}" ]]; then
    return 2
  fi
}

# Writes the manifest of the destination, merged with the one of a previous install of the same product
manifest::write() {
  local MANIFEST_FILE_PATH="${_arg_destination%/}/${MANIFEST_FILENAME}"

  local WRITE_DESTINATION_CREATED="${DESTINATION_CREATED_BY_INSTALLER:-no}"
  local WRITE_ENTRIES=()

  if manifest::read "${MANIFEST_FILE_PATH}" &&
    [[ "${MANIFEST_PRODUCT}" == "${PRODUCT_SHORTNAME}" ]] &&
    [[ "${MANIFEST_DESTINATION}" == "${_arg_destination%/}" ]]; then
    if [[ "${MANIFEST_DESTINATION_CREATED}" == "yes" ]]; then
      WRITE_DESTINATION_CREATED="yes"
    fi
    WRITE_ENTRIES=("${MANIFEST_ENTRIES[@]}")
  fi

  WRITE_ENTRIES+=("${MANIFEST_NEW_ENTRIES[@]}")

  local TEMP_MANIFEST_PATH
  TEMP_MANIFEST_PATH=$(mktemp "${MANIFEST_FILE_PATH}.XXXXXX") || return 1

  {
    printf 'version\t%s\n' "${MANIFEST_FORMAT_VERSION}"
    printf 'product\t%s\n' "${PRODUCT_SHORTNAME}"
    printf 'destination\t%s\n' "${_arg_destination%/}"
    printf 'destination-created\t%s\n' "${WRITE_DESTINATION_CREATED}"

    local WRITE_ENTRY
    local WRITTEN_ENTRIES=$'\n'
    for WRITE_ENTRY in "${WRITE_ENTRIES[@]}"; do
      if [[ "${WRITTEN_ENTRIES}" == *$'\n'"${WRITE_ENTRY}"$'\n'* ]]; then
        continue
      fi

      WRITTEN_ENTRIES+="${WRITE_ENTRY}"$'\n'
      printf '%s\n' "${WRITE_ENTRY}"
    done
  } >"${TEMP_MANIFEST_PATH}" || {
    rm -f "${TEMP_MANIFEST_PATH}"
    return 1
  }

  if ! { chmod 644 "${TEMP_MANIFEST_PATH}" && mv -f "${TEMP_MANIFEST_PATH}" "${MANIFEST_FILE_PATH}"; }; then
    rm -f "${TEMP_MANIFEST_PATH}"
    return 1
  fi
}
