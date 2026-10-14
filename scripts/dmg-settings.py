# dmgbuild settings for the OpenEar installer window. Used by scripts/make-dmg.sh.
# Icon positions must line up with the slots drawn in scripts/render-art.swift.

app = defines["app"]

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["OpenEar.app"]

icon = defines["icon"]
background = defines["background"]

format = "UDZO"
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False

icon_size = 112
text_size = 13
icon_locations = {
    "OpenEar.app": (180, 215),
    "Applications": (480, 215),
}
