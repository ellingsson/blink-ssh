#!/bin/sh
set -eu

source="$SRCROOT/SSHOnly/TestIdentity"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/TestIdentity"

if [ ! -f "$source" ]; then
  echo "error: Debug requires SSHOnly/TestIdentity for integration tests." >&2
  exit 1
fi

install -m 600 "$source" "$destination"
