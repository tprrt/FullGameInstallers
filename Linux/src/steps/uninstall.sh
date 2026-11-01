# shellcheck shell=bash

# Removes an installation made by this installer, using the install manifest written by lib/manifest.sh.
# Nothing outside of what the manifest lists is removed, and the game files are only removed when the
# installer created the destination folder, so an install over an existing game is never wiped.

# Folders that are never removed, whatever the manifest says
local UNINSTALL_PROTECTED_PATHS=(/ /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var)

step::uninstall() {
  ansi::banner "OldUnreal ${PRODUCT_NAME} Linux Uninstaller"
  echo

  local UNINSTALL_DESTINATION
  UNINSTALL_DESTINATION=$(realpath -m -- "${_arg_destination}")

  if __step::uninstall::is_protected_path "${UNINSTALL_DESTINATION}"; then
    term::error_with_dialog "Refusing to uninstall from ${UNINSTALL_DESTINATION}. Use --destination to select the folder ${PRODUCT_NAME} is installed in."
    return 1
  fi

  # What the uninstall will do, filled in by the functions below
  local UNINSTALL_FILES=()
  local UNINSTALL_DIRS=()
  local UNINSTALL_USER_DATA=()
  local UNINSTALL_KEPT=()
  local UNINSTALL_REMOVE_DESTINATION="no"

  term::step::new "Looking for the installation"

  local MANIFEST_STATUS=0
  manifest::read "${UNINSTALL_DESTINATION}/${MANIFEST_FILENAME}" || MANIFEST_STATUS=$?

  case "${MANIFEST_STATUS}" in
  0)
    if [[ "${MANIFEST_PRODUCT}" != "${PRODUCT_SHORTNAME}" ]] || [[ "${MANIFEST_DESTINATION}" != "${UNINSTALL_DESTINATION}" ]]; then
      term::step::failed_with_error "The install manifest in ${UNINSTALL_DESTINATION} belongs to ${MANIFEST_PRODUCT} installed in ${MANIFEST_DESTINATION}, not to ${PRODUCT_NAME}. Nothing was removed."
      return 1
    fi

    term::step::complete
    __step::uninstall::plan_from_manifest "${UNINSTALL_DESTINATION}"
    ;;
  1)
    term::step::skipped "No install manifest, looking for known files"
    __step::uninstall::plan_without_manifest "${UNINSTALL_DESTINATION}"
    ;;
  *)
    term::step::failed_with_error "The install manifest in ${UNINSTALL_DESTINATION} was written by a newer installer. Download the latest uninstaller and run it again. Nothing was removed."
    return 1
    ;;
  esac

  __step::uninstall::plan_user_data

  if [[ "${#UNINSTALL_FILES[@]}" -eq 0 ]] &&
    [[ "${#UNINSTALL_DIRS[@]}" -eq 0 ]] &&
    [[ "${#UNINSTALL_USER_DATA[@]}" -eq 0 ]] &&
    [[ "${UNINSTALL_REMOVE_DESTINATION}" != "yes" ]]; then
    echo
    echo "Nothing to remove."
    __step::uninstall::print_list "Left in place:" "${UNINSTALL_KEPT[@]}"
    return 0
  fi

  local PLAN_TEXT
  PLAN_TEXT=$(__step::uninstall::plan_text "${UNINSTALL_DESTINATION}")

  echo
  echo "${PLAN_TEXT}"

  if ! __step::uninstall::confirm "${PLAN_TEXT}"; then
    echo
    echo "Uninstall cancelled, nothing was removed."
    return 2
  fi

  echo

  local ITEM

  if [[ "${#UNINSTALL_FILES[@]}" -gt 0 ]] || [[ "${#UNINSTALL_DIRS[@]}" -gt 0 ]]; then
    term::step::new "Remove entries, icons and launchers"

    for ITEM in "${UNINSTALL_FILES[@]}"; do
      rm -f -- "${ITEM}" || {
        term::step::failed_with_error "Failed to remove ${ITEM}. Uninstall aborted."
        return 77 #E_PERM
      }
    done

    for ITEM in "${UNINSTALL_DIRS[@]}"; do
      rm -rf -- "${ITEM}" || {
        term::step::failed_with_error "Failed to remove ${ITEM}. Uninstall aborted."
        return 77 #E_PERM
      }
    done

    term::step::complete
  fi

  if [[ "${UNINSTALL_REMOVE_DESTINATION}" == "yes" ]]; then
    term::step::new "Remove ${UNINSTALL_DESTINATION}"

    rm -rf -- "${UNINSTALL_DESTINATION}" || {
      term::step::failed_with_error "Failed to remove ${UNINSTALL_DESTINATION}. Uninstall aborted."
      return 77 #E_PERM
    }

    # The OldUnreal folder is shared by all titles, only remove it once the last one is gone
    if [[ "${UNINSTALL_DESTINATION##*/}" != "OldUnreal" ]] && [[ "${UNINSTALL_DESTINATION%/*}" == */OldUnreal ]]; then
      rmdir -- "${UNINSTALL_DESTINATION%/*}" 2>/dev/null || true
    fi

    term::step::complete
  fi

  if [[ "${#UNINSTALL_USER_DATA[@]}" -gt 0 ]]; then
    term::step::new "Remove saves and configuration"

    for ITEM in "${UNINSTALL_USER_DATA[@]}"; do
      rm -rf -- "${ITEM}" || {
        term::step::failed_with_error "Failed to remove ${ITEM}. Uninstall aborted."
        return 77 #E_PERM
      }
    done

    term::step::complete
  fi

  echo
  echo -e "$(ansi::styled "${PRODUCT_NAME}" "${ansi_stylenum[bright]}" "${ansi_colornum[green]}") $(ansi::styled "has been uninstalled." "" "${ansi_colornum[green]}")"
  __step::uninstall::print_list "Left in place:" "${UNINSTALL_KEPT[@]}"
  __step::uninstall::notify_finished
}

# Adds the entries listed by the manifest that are safe to remove to the plan
__step::uninstall::plan_from_manifest() {
  local DESTINATION="${1:-}"

  local ENTRY ENTRY_KIND ENTRY_PATH
  local HAS_LEFT_ENTRIES="no"

  for ENTRY in "${MANIFEST_ENTRIES[@]}"; do
    ENTRY_KIND="${ENTRY%%$'\t'*}"
    ENTRY_PATH="${ENTRY#*$'\t'}"

    if [[ ! -e "${ENTRY_PATH}" ]] && [[ ! -L "${ENTRY_PATH}" ]]; then
      continue
    fi

    if ! __step::uninstall::is_allowed_entry "${ENTRY_KIND}" "${ENTRY_PATH}" "${DESTINATION}"; then
      UNINSTALL_KEPT+=("${ENTRY_PATH} (not a path this installer creates)")
      HAS_LEFT_ENTRIES="yes"
      continue
    fi

    __step::uninstall::plan_entry "${ENTRY_KIND}" "${ENTRY_PATH}"
  done

  if [[ "${MANIFEST_DESTINATION_CREATED}" == "yes" ]]; then
    UNINSTALL_REMOVE_DESTINATION="yes"
  else
    UNINSTALL_KEPT+=("${DESTINATION} (it existed before the installation, the game files are not tracked)")

    # The manifest is only useful while it lists something that is still there
    if [[ "${HAS_LEFT_ENTRIES}" == "no" ]]; then
      UNINSTALL_FILES+=("${DESTINATION}/${MANIFEST_FILENAME}")
    fi
  fi
}

# Installations made before the manifest existed: only look for the files the installer is known to write
__step::uninstall::plan_without_manifest() {
  local DESTINATION="${1:-}"

  local XDG_DATA="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local ICONS_PATH="${XDG_DATA%/}/icons/hicolor"
  local DESKTOP_PATH
  DESKTOP_PATH=$(xdgdirs::get_user_dir "DESKTOP")

  local ESCAPED_DESTINATION
  ESCAPED_DESTINATION=$(xdgdirs::escape_exec_argument "${DESTINATION}")

  local CANDIDATES=(
    "${XDG_DATA%/}/applications/OldUnreal-${PRODUCT_SHORTNAME}.desktop"
    "${XDG_DATA%/}/applications/OldUnreal-${PRODUCT_SHORTNAME}-UnrealEd.desktop"
  )

  if [[ -n "${DESKTOP_PATH}" ]]; then
    CANDIDATES+=(
      "${DESKTOP_PATH%/}/${PRODUCT_SHORTNAME}.desktop"
      "${DESKTOP_PATH%/}/UnrealEd-${PRODUCT_SHORTNAME}.desktop"
    )
  fi

  local CANDIDATE
  local HAS_OTHER_INSTALLATION="no"
  for CANDIDATE in "${CANDIDATES[@]}"; do
    if [[ ! -f "${CANDIDATE}" ]]; then
      continue
    fi

    # Only the entries that start the installation being removed, not another one of the same game
    if ! grep -qF -- "Exec=\"${ESCAPED_DESTINATION}/" "${CANDIDATE}" 2>/dev/null; then
      UNINSTALL_KEPT+=("${CANDIDATE} (it starts another installation)")
      HAS_OTHER_INSTALLATION="yes"
      continue
    fi

    if __step::uninstall::is_allowed_entry "file" "${CANDIDATE}" "${DESTINATION}"; then
      __step::uninstall::plan_entry "file" "${CANDIDATE}"
    fi
  done

  # Icons are named after the game, they can't tell the installations apart. They are left alone while
  # an entry starting another installation of the game still uses them.
  local ICON_SIZE ICON_NAME ICON_PATH
  for ICON_SIZE in 32x32 48x48; do
    for ICON_NAME in "OldUnreal_${PRODUCT_SHORTNAME}" "OldUnreal_${PRODUCT_SHORTNAME}_UnrealEd"; do
      ICON_PATH="${ICONS_PATH}/${ICON_SIZE}/apps/${ICON_NAME}.png"

      if [[ ! -f "${ICON_PATH}" ]]; then
        continue
      fi

      if [[ "${HAS_OTHER_INSTALLATION}" == "yes" ]]; then
        UNINSTALL_KEPT+=("${ICON_PATH} (used by another installation)")
      elif __step::uninstall::is_allowed_entry "file" "${ICON_PATH}" "${DESTINATION}"; then
        __step::uninstall::plan_entry "file" "${ICON_PATH}"
      fi
    done
  done

  # Without a manifest, the folder is only removed when it is the default one and holds the game
  local DEFAULT_DESTINATION
  DEFAULT_DESTINATION=$(realpath -m -- "${XDG_DATA%/}/OldUnreal/${PRODUCT_SHORTNAME}")

  if [[ ! -d "${DESTINATION}" ]]; then
    return 0
  fi

  if [[ "${DESTINATION}" == "${DEFAULT_DESTINATION}" ]] && compgen -G "${DESTINATION}/System*/${MAIN_BINARY_NAME}*" >/dev/null; then
    UNINSTALL_REMOVE_DESTINATION="yes"
  else
    UNINSTALL_KEPT+=("${DESTINATION} (no install manifest, and not the default folder of an installation)")
  fi
}

__step::uninstall::plan_user_data() {
  if [[ "${_arg_remove_user_data:-off}" != "on" ]]; then
    return 0
  fi

  if [[ "${#PRODUCT_USER_DATA_DIRS[@]}" -eq 0 ]]; then
    UNINSTALL_KEPT+=("saves and configuration (no known folder for ${PRODUCT_NAME})")
    return 0
  fi

  local USER_DATA_DIR
  for USER_DATA_DIR in "${PRODUCT_USER_DATA_DIRS[@]}"; do
    if [[ -d "${USER_DATA_DIR}" ]] && [[ ! -L "${USER_DATA_DIR}" ]] && ! __step::uninstall::is_protected_path "$(realpath -m -- "${USER_DATA_DIR}")"; then
      UNINSTALL_USER_DATA+=("${USER_DATA_DIR}")
    fi
  done
}

__step::uninstall::plan_entry() {
  local ENTRY_KIND="${1:-}"
  local ENTRY_PATH="${2:-}"

  if [[ "${ENTRY_KIND}" == "dir" ]]; then
    UNINSTALL_DIRS+=("${ENTRY_PATH}")
  else
    UNINSTALL_FILES+=("${ENTRY_PATH}")
  fi
}

__step::uninstall::plan_text() {
  local DESTINATION="${1:-}"

  local ITEM

  echo "The following will be removed:"
  for ITEM in "${UNINSTALL_FILES[@]}" "${UNINSTALL_DIRS[@]}"; do
    echo "  - ${ITEM}"
  done

  if [[ "${UNINSTALL_REMOVE_DESTINATION}" == "yes" ]]; then
    echo "  - ${DESTINATION} and everything in it"
  fi

  if [[ "${#UNINSTALL_USER_DATA[@]}" -gt 0 ]]; then
    for ITEM in "${UNINSTALL_USER_DATA[@]}"; do
      echo "  - ${ITEM} (saves and configuration)"
    done
  fi

  if [[ "${#UNINSTALL_KEPT[@]}" -gt 0 ]]; then
    echo
    echo "The following will be left in place:"
    for ITEM in "${UNINSTALL_KEPT[@]}"; do
      echo "  - ${ITEM}"
    done
  fi
}

__step::uninstall::print_list() {
  local TITLE="${1:-}"
  shift

  if [[ $# -eq 0 ]]; then
    return 0
  fi

  echo
  echo "${TITLE}"

  local ITEM
  for ITEM in "$@"; do
    echo "  - ${ITEM}"
  done
}

__step::uninstall::confirm() {
  local PLAN_TEXT="${1:-}"

  if [[ "${_arg_yes:-off}" == "on" ]]; then
    return 0
  fi

  local DIALOG_TEXT="${PLAN_TEXT}

Do you want to continue?"

  if [[ "${_arg_ui_mode:-none}" == "kdialog" ]]; then
    kdialog --title "Uninstall ${PRODUCT_NAME}" --yesno "${DIALOG_TEXT}" &>/dev/null
  elif [[ "${_arg_ui_mode:-none}" == "zenity" ]]; then
    zenity --question --no-markup --title="Uninstall ${PRODUCT_NAME}" --width=500 "--text=${DIALOG_TEXT}" &>/dev/null
  else
    echo
    term::yesno "Do you want to continue?"
  fi
}

__step::uninstall::notify_finished() {
  local DIALOG_TEXT="${PRODUCT_NAME} has been uninstalled."

  if [[ "${_arg_ui_mode:-none}" == "kdialog" ]]; then
    kdialog --msgbox "${DIALOG_TEXT}" &>/dev/null || true
  elif [[ "${_arg_ui_mode:-none}" == "zenity" ]]; then
    zenity --info --no-markup --width=400 "--text=${DIALOG_TEXT}" &>/dev/null || true
  fi
}

# Both folders are compared once resolved, as the home folder or the data folder can be behind a symbolic link
__step::uninstall::is_same_folder() {
  [[ "$(realpath -m -- "${1:-}")" == "$(realpath -m -- "${2:-}")" ]]
}

__step::uninstall::is_protected_path() {
  local CANDIDATE="${1:-}"
  CANDIDATE="${CANDIDATE%/}"

  if [[ -z "${CANDIDATE}" ]] || [[ "${CANDIDATE}" != /* ]] || [[ "${CANDIDATE}/" == *"/../"* ]]; then
    return 0
  fi

  local PROTECTED_PATH
  for PROTECTED_PATH in "${UNINSTALL_PROTECTED_PATHS[@]}"; do
    if [[ "${CANDIDATE}" == "${PROTECTED_PATH}" ]]; then
      return 0
    fi
  done

  local HOME_PATH DATA_PATH
  HOME_PATH=$(realpath -m -- "${HOME}")
  DATA_PATH=$(realpath -m -- "${XDG_DATA_HOME:-${HOME}/.local/share}")

  # The home folder, the data folder, the shared OldUnreal folder, and all their parents
  if [[ "${HOME_PATH}/" == "${CANDIDATE}/"* ]] ||
    [[ "${DATA_PATH}/" == "${CANDIDATE}/"* ]] ||
    [[ "${CANDIDATE}" == "${DATA_PATH}/OldUnreal" ]]; then
    return 0
  fi

  return 1
}

# Tells if an entry of the manifest may be removed. The manifest is a file the user can edit, and it is
# not trusted: anything under the destination is fine, anything else must be a file named like the ones
# the installer creates, in the folder it creates them in.
__step::uninstall::is_allowed_entry() {
  local ENTRY_KIND="${1:-}"
  local ENTRY_PATH="${2:-}"
  local DESTINATION="${3:-}"

  if [[ "${ENTRY_KIND}" != "file" ]] && [[ "${ENTRY_KIND}" != "dir" ]]; then
    return 1
  fi

  if [[ "${ENTRY_PATH}" != /* ]] || [[ "${ENTRY_PATH}/" == *"/../"* ]]; then
    return 1
  fi

  # A file may be a symbolic link (only the link is removed), but never a folder
  if [[ "${ENTRY_KIND}" == "file" ]] && [[ -d "${ENTRY_PATH}" ]] && [[ ! -L "${ENTRY_PATH}" ]]; then
    return 1
  fi

  local ENTRY_NAME="${ENTRY_PATH##*/}"
  local ENTRY_DIR
  ENTRY_DIR=$(realpath -m -- "${ENTRY_PATH%/*}/")

  if [[ "${ENTRY_DIR}/${ENTRY_NAME}" == "${DESTINATION}/"* ]]; then
    return 0
  fi

  if [[ "${ENTRY_KIND}" != "file" ]]; then
    return 1
  fi

  local XDG_DATA="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local DESKTOP_PATH
  DESKTOP_PATH=$(xdgdirs::get_user_dir "DESKTOP")

  case "${ENTRY_NAME}" in
  "OldUnreal-${PRODUCT_SHORTNAME}.desktop" | "OldUnreal-${PRODUCT_SHORTNAME}-UnrealEd.desktop")
    __step::uninstall::is_same_folder "${ENTRY_DIR}" "${XDG_DATA%/}/applications"
    ;;
  "${PRODUCT_SHORTNAME}.desktop" | "UnrealEd-${PRODUCT_SHORTNAME}.desktop")
    [[ -n "${DESKTOP_PATH}" ]] && __step::uninstall::is_same_folder "${ENTRY_DIR}" "${DESKTOP_PATH}"
    ;;
  "OldUnreal_${PRODUCT_SHORTNAME}.png" | "OldUnreal_${PRODUCT_SHORTNAME}_UnrealEd.png")
    __step::uninstall::is_same_folder "${ENTRY_DIR}" "${XDG_DATA%/}/icons/hicolor/32x32/apps" ||
      __step::uninstall::is_same_folder "${ENTRY_DIR}" "${XDG_DATA%/}/icons/hicolor/48x48/apps"
    ;;
  *)
    return 1
    ;;
  esac
}
