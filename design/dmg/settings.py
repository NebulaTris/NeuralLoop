# dmgbuild settings for NeuralLoop's disk image (used by scripts/package-mac.sh):
#   dmgbuild -s design/dmg/settings.py -D app=PATH/NeuralLoop.app -D here=design/dmg "NeuralLoop" OUT.dmg
# The window shows design/dmg/background.tiff with the app on the left and Applications on the right; the icon
# positions match APP and APPLICATIONS in make_background.py.
import os

application = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
here = defines["here"]  # noqa: F821 (this folder)

format = "ULFO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it sets Finder info on the app, which breaks strict signature checks
# (Finder hides ".app" anyway).
icon_locations = {
    os.path.basename(application): (165, 238),
    "Applications": (495, 238),
    ".background.tiff": (1200, 1200),  # out of sight for people who show hidden files
}
background = os.path.join(here, "background.tiff")

window_rect = ((200, 140), (660, 468))  # the height includes the title bar; the picture is 660 x 440
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 112
text_size = 13
