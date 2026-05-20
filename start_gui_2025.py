"""Start the HyperMesh 2025 Python material assignment GUI."""

from pathlib import Path
import runpy

script_dir = Path(globals().get("__file__", r"D:/code_ai/codex/start_gui_2025.py")).resolve().parent
module_globals = runpy.run_path(str(script_dir / "hm_material_assign_2025.py"))
module_globals["show_gui"]()
