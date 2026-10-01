# dmgbuild layout for the DroidDock installer window (see scripts/make-dmg.sh).
# `app` is passed in with -D app=path/to/DroidDock.app; paths are relative to the repo root.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")  # volume icon

background = "scripts/dmg/background.png"  # background@2x.png is picked up too
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (160, 185),
    "Applications": (480, 185),
}
