# shellcheck shell=bash

# Called once the destination exists, then again once everything is installed. The first call lets an
# interrupted installation be removed, the second one lists the entries created in between.
step::write_manifest() {
  manifest::write || {
    echo "Warning: Unable to write the install manifest, this installation can't be uninstalled automatically." 1>&2
  }
}
