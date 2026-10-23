import os
from pathlib import Path

project_dir = Path(os.environ["V5XS_PROJECT_DIR"])

format = "UDZO"
files = [str(project_dir / "dist/v5xs.app")]
symlinks = {"Applications": "/Applications"}
background = str(project_dir / "Resources/dmg-background.png")
icon = str(project_dir / "Resources/AppIcon.icns")
icon_size = 112
icon_locations = {"v5xs.app": (150, 190), "Applications": (490, 190)}
window_rect = ((120, 120), (640, 380))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
