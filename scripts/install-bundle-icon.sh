#!/bin/bash
set -euo pipefail
# Icon Composer supplies the modern appearance assets. Install the complete
# current ICNS as well, so Launch Services has the same identity at every size
# before the process can apply its preferred Dock appearance.
: "${SRCROOT:?}"
: "${TARGET_BUILD_DIR:?}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
icon_source="$SRCROOT/WeGit/Resources/AppearanceIcons/WeGitLight.icns"
icon_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AppIcon.icns"
test -f "$icon_source"
test -d "$(dirname "$icon_destination")"
/usr/bin/ditto "$icon_source" "$icon_destination"
