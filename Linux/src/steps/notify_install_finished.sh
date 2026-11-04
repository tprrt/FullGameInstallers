# shellcheck shell=bash

step::notify_install_finished() {
  # Remove installation files, only if the ./Installer folder was created by this installer
  if [[ "${_arg_keep_installer_files:-off}" != "on" ]] &&
    [[ -f "${_arg_destination%/}/Installer/${INSTALLER_FOLDER_MARKER_FILENAME}" ]]; then
    rm -rf "${_arg_destination%/}/Installer"
  fi

  echo
  echo -e "$(ansi::styled "${PRODUCT_NAME}" "${ansi_stylenum[bright]}" "${ansi_colornum[green]}") $(ansi::styled "is now installed!" "" "${ansi_colornum[green]}")"
  echo
  echo "You can launch the game by running:"
  echo "  ${DESTINATION_HOMIFIED}/System${UE_SYSTEM_FOLDER_SUFFIX:-}/${MAIN_BINARY_NAME}${ARCHITECTURE_BINARY_SUFFIX}"

  local DIALOG_TEXT="""
${PRODUCT_NAME} is now installed!

You can launch the game by running:

  ${DESTINATION_HOMIFIED}/System${UE_SYSTEM_FOLDER_SUFFIX:-}/${MAIN_BINARY_NAME}${ARCHITECTURE_BINARY_SUFFIX}
"""

  term::dialog::msgbox "${DIALOG_TEXT}" "" 400
}
