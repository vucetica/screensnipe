# dmgbuild settings for the ScreenSnipe drag-to-install DMG.
#
# Driven by scripts/make-dmg.sh, which passes -D app_path=... -D assets_dir=...
# Icon positions here must stay in sync with the layout constants in
# scripts/dmg-background.swift, which draws the artwork behind them.
#
# dmgbuild exec()s this file, so there is no __file__ to derive paths from —
# hence assets_dir arriving as a define.

import os.path

app_path = defines["app_path"]
app_name = os.path.basename(app_path)
assets_dir = defines["assets_dir"]

# Finder anchors the background picture at the top-left of the *content* view at
# native size and never scales it, so the window frame has to be sized around the
# chrome or the artwork is clipped.
#
# DESIGN_HEIGHT must match designHeight in scripts/dmg-background.swift — it is
# the region the artwork actually draws in, and it has to survive the worst case:
# a user with both the path bar and the status bar switched on. Those are global
# View-menu preferences, so ShowStatusBar/ShowPathbar below are honoured on some
# machines and ignored on others; we size for them being ignored.
CONTENT_WIDTH = 640
DESIGN_HEIGHT = 400
TITLE_BAR_HEIGHT = 32   # NSWindow.frameRect(forContentRect:) on macOS 26
BOTTOM_CHROME_HEIGHT = 52   # path bar (28) + status bar (24), measured

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [app_path]
symlinks = {"Applications": "/Applications"}

background = os.path.join(assets_dir, "background.tiff")

# App on the left, drop target on the right, following the arrow in the artwork.
icon_locations = {
    app_name: (168, 170),
    "Applications": (472, 170),
}

window_rect = (
    (200, 140),
    (CONTENT_WIDTH, DESIGN_HEIGHT + TITLE_BAR_HEIGHT + BOTTOM_CHROME_HEIGHT),
)
default_view = "icon-view"
icon_size = 128
text_size = 13
label_pos = "bottom"
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
show_icon_preview = False

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 180

include_icon_view_settings = True
include_list_view_settings = False
