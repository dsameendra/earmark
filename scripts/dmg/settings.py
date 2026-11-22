"""Finder layout for the Earmark installer. Inputs are supplied only by make-dmg.sh."""
import os

app = os.path.realpath(defines["app"])
format = "UDZO"
filesystem = "HFS+"
files = [(app, "Earmark.app")]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
badge_icon = None
icon_locations = {"Earmark.app": (170, 200), "Applications": (490, 200)}
hide_extensions = ["Earmark.app"]
window_rect = ((160, 120), (660, 420))
default_view = "icon-view"
show_icon_preview = False
show_item_info = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 80
scroll_position = (0, 0)
label_pos = "bottom"
include_icon_view_settings = True
include_list_view_settings = False
