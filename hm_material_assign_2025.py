"""HyperMesh 2025 Python material assignment helper.

Run in HyperMesh 2025 Python Window:
    exec(open(r"D:/code_ai/codex/start_gui_2025.py", encoding="utf-8").read())

The HyperMesh 2019 Tcl version is kept in hm_material_assign.tcl.
"""

from __future__ import annotations

import csv
import os
import re
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


SHELL_CONFIGS = {103, 104, 106, 108, 111, 112}
SOLID_CONFIGS = {204, 205, 206, 208, 210, 213}
IMPORT_READER = "#abaqus/abaqus"

IMPORT_SKIP_OPTIONS = [
    "ASSEMS_SKIP ",
    "BEAMSECTCOLS_SKIP ",
    "BEAMSECTS_SKIP ",
    "BLOCKS_SKIP ",
    "COMPONENTS_SKIP ",
    "CONNECTORS_SKIP ",
    "CONTACTSURFS_SKIP ",
    "CONTROLCARDS_SKIP ",
    "CONTROLVOLS_SKIP ",
    "CURVES_SKIP ",
    "ELEMS_SKIP ",
    "EQUATIONS_SKIP ",
    "GROUPS_SKIP ",
    "LOADCOLS_SKIP ",
    "LOADS_SKIP ",
    "LOADSTEPS_SKIP ",
    "NODES_SKIP ",
    "OUTPUTBLOCKS_SKIP ",
    "PLOTS_SKIP ",
    "PROPERTIES_SKIP ",
    "SETS_SKIP ",
    "SYSTCOLS_SKIP ",
    "SYSTEMS_SKIP ",
    "TAGS_SKIP ",
    "TITLES_SKIP ",
    "VECTORS_SKIP ",
]


@dataclass
class RunStats:
    processed: int = 0
    renamed: int = 0
    assigned: int = 0
    prop_material_linked: int = 0
    comp_property_linked: int = 0
    elem_property_linked: int = 0
    skipped: int = 0
    unmapped: List[str] = field(default_factory=list)
    errors: List[str] = field(default_factory=list)


def _hm_modules():
    import hm  # type: ignore
    import hm.entities as ent  # type: ignore

    return hm, ent


def _model():
    hm, _ent = _hm_modules()
    return hm.Model()


def _try_import_hw():
    try:
        import hw  # type: ignore

        return hw
    except Exception:
        return None


def _tcl_quote(value: str) -> str:
    return "{" + value.replace("\\", "/").replace("}", r"\}") + "}"


def eval_tcl(model, command: str):
    if hasattr(model, "evaltclstring"):
        return model.evaltclstring(command)

    hw = _try_import_hw()
    if hw is not None and hasattr(hw, "evalTcl"):
        return hw.evalTcl(command)

    raise RuntimeError("No Tcl evaluation function is available in this HyperMesh Python session.")


def normalize_newlines(value: str) -> str:
    return value.replace("\\r\\n", "\n").replace("\\n", "\n").replace("\\r", "\n")


def normalize_component_name(name: str) -> str:
    cleaned = str(name).strip()
    cleaned = re.sub(r"@+$", "", cleaned)
    match = re.match(r"^(.+)@([^@]+)$", cleaned)
    if match:
        cleaned = re.sub(r"@+$", "", match.group(1))
    return cleaned.strip()


def safe_name(name: str, limit: int = 80) -> str:
    cleaned = re.sub(r"""["'*?$]""", "_", str(name).strip())
    return cleaned[:limit]


def read_csv_rows(path: str) -> List[List[str]]:
    with open(path, "r", encoding="utf-8-sig", newline="") as fh:
        return [[cell.strip() for cell in row] for row in csv.reader(fh) if row and any(c.strip() for c in row)]


def maybe_skip_header(rows: List[List[str]], first_names: Iterable[str], second_names: Iterable[str]) -> List[List[str]]:
    if not rows:
        return rows
    first = rows[0][0].strip().lower() if len(rows[0]) > 0 else ""
    second = rows[0][1].strip().lower() if len(rows[0]) > 1 else ""
    if first in set(first_names) and second in set(second_names):
        return rows[1:]
    return rows


def read_component_map(path: str) -> Dict[str, str]:
    rows = maybe_skip_header(
        read_csv_rows(path),
        {"component", "comp", "part", "part_name", "component_name"},
        {"material", "mat", "material_name"},
    )
    result: Dict[str, str] = {}
    for row in rows:
        if len(row) < 2:
            continue
        comp = normalize_component_name(row[0])
        mat = row[1].strip()
        if comp and mat:
            result[comp] = mat
            result[comp.lower()] = mat
    return result


def read_material_blocks(path: str) -> Dict[str, str]:
    rows = maybe_skip_header(
        read_csv_rows(path),
        {"material", "mat", "material_name"},
        {"inp", "abaqus_inp", "material_block"},
    )
    result: Dict[str, str] = {}
    for row in rows:
        if len(row) < 2:
            continue
        mat = row[0].strip()
        block = normalize_newlines(row[1].strip())
        if not mat or not block:
            continue
        if not re.match(r"^\s*\*material\s*,", block, flags=re.I):
            block = f"*Material, name={mat}\n{block}"
        result[mat] = block
    return result


def unique_material_names(component_map: Dict[str, str]) -> List[str]:
    names: List[str] = []
    for key, name in component_map.items():
        if key != key.lower() and name not in names:
            names.append(name)
    if not names:
        for name in component_map.values():
            if name not in names:
                names.append(name)
    return names


def entity_by_name(model, entity_cls, name: str):
    for entity in _collection(model, entity_cls):
        if getattr(entity, "name", None) == name:
            return entity
    return None


def _collection(model, *args, **kwargs):
    hm, _ent = _hm_modules()
    return hm.Collection(model, *args, **kwargs)


def write_material_import_file(material_names: Iterable[str], material_blocks: Dict[str, str], out_path: str) -> None:
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("** Generated by hm_material_assign_2025.py\n")
        for mat_name in material_names:
            if mat_name not in material_blocks:
                raise RuntimeError(f"Material '{mat_name}' is referenced but missing in material CSV.")
            fh.write(material_blocks[mat_name].rstrip() + "\n\n")


def import_materials_from_inp(model, inp_path: str) -> None:
    options = " ".join(_tcl_quote(opt) for opt in IMPORT_SKIP_OPTIONS)
    tcl = "\n".join(
        [
            f"*createstringarray {len(IMPORT_SKIP_OPTIONS)} {options}",
            f"*feinputwithdata2 {_tcl_quote(IMPORT_READER)} {_tcl_quote(inp_path)} 0 0 0 0 0 1 {len(IMPORT_SKIP_OPTIONS)} 1 0",
        ]
    )
    eval_tcl(model, tcl)


def ensure_materials(model, material_names: List[str], material_blocks: Dict[str, str], work_dir: str) -> Dict[str, object]:
    _hm, ent = _hm_modules()
    missing = [name for name in material_names if entity_by_name(model, ent.Material, name) is None]
    if missing:
        import_path = str(Path(work_dir) / "__hm_mat_assign_materials_2025.inp")
        write_material_import_file(missing, material_blocks, import_path)
        import_materials_from_inp(model, import_path)

    result: Dict[str, object] = {}
    for name in material_names:
        mat = entity_by_name(model, ent.Material, name)
        if mat is None:
            raise RuntimeError(f"Material '{name}' was not found after import.")
        result[name] = mat
    return result


def component_material(component_map: Dict[str, str], comp_name: str) -> Tuple[bool, str, str]:
    key = normalize_component_name(comp_name)
    if key in component_map:
        return True, key, component_map[key]
    lower = key.lower()
    if lower in component_map:
        return True, key, component_map[lower]
    return False, key, ""


def unique_component_name(model, desired: str, current_id: int) -> str:
    _hm, ent = _hm_modules()
    existing = entity_by_name(model, ent.Component, desired)
    if existing is None or getattr(existing, "id", None) == current_id:
        return desired
    base = desired[:74]
    index = 1
    while True:
        candidate = f"{base}_{index:03d}"
        existing = entity_by_name(model, ent.Component, candidate)
        if existing is None or getattr(existing, "id", None) == current_id:
            return candidate
        index += 1


def elements_by_component(model, comp):
    hm, ent = _hm_modules()
    comp_col = hm.Collection(model, ent.Component, [comp.id])
    filt = hm.FilterByCollection(ent.Element, ent.Component)
    return hm.Collection(model, filt, comp_col)


def component_mesh_kind(model, comp) -> str:
    has_shell = False
    has_solid = False
    for elem in elements_by_component(model, comp):
        config = int(getattr(elem, "config", 0) or 0)
        if config in SHELL_CONFIGS:
            has_shell = True
        if config in SOLID_CONFIGS:
            has_solid = True
    if has_shell and has_solid:
        return "mixed"
    if has_solid:
        return "solid"
    if has_shell:
        return "shell"
    return "unknown"


def ensure_property(model, prop_name: str, mesh_kind: str, mat):
    _hm, ent = _hm_modules()
    prop_name = safe_name(prop_name)
    prop = entity_by_name(model, ent.Property, prop_name)
    if prop is None:
        prop = ent.Property(model)
        prop.name = prop_name

    card_image = {"solid": "SOLIDSECTION", "shell": "SHELLSECTION"}.get(mesh_kind)
    if card_image is None:
        raise RuntimeError(f"Unsupported mesh kind '{mesh_kind}' for property '{prop_name}'.")

    try:
        prop.cardimage = card_image
    except Exception:
        eval_tcl(model, f"*setvalue props id={prop.id} cardimage={_tcl_quote(card_image)}")

    try:
        prop.materialid = mat
    except Exception:
        eval_tcl(model, f"*setvalue props id={prop.id} materialid={mat.id}")
    return prop


def assign_property_to_component(model, comp, prop, mat) -> int:
    comp.propertyid = prop
    try:
        comp.materialid = mat
    except Exception:
        eval_tcl(model, f"*setvalue comps id={comp.id} materialid={mat.id}")

    linked_elems = 0
    try:
        for elem in elements_by_component(model, comp):
            elem.propertyid = prop
            try:
                elem.materialid = mat
            except Exception:
                pass
            linked_elems += 1
    except Exception:
        eval_tcl(
            model,
            "\n".join(
                [
                    f"*createmark elems 1 \"by comp id\" {comp.id}",
                    f"*setvalue elems mark=1 propertyid={prop.id}",
                ]
            ),
        )
    return linked_elems


def show_only_unassigned_components(model) -> None:
    _hm, ent = _hm_modules()
    lines = ['*displaycollector components none "" 1 1']
    for comp in _collection(model, ent.Component):
        prop = getattr(comp, "propertyid", None)
        if not prop:
            lines.append(f"*displaycollector components on {_tcl_quote(comp.name)} 1 1")
    eval_tcl(model, "\n".join(lines))


def stats_text(stats: RunStats, component_csv: str = "", material_csv: str = "") -> str:
    lines = ["Run completed."]
    if component_csv:
        lines.append(f"Component map: {component_csv}")
    if material_csv:
        lines.append(f"Material CSV:  {material_csv}")
    lines.extend(
        [
            "",
            f"Processed components: {stats.processed}",
            f"Renamed components:   {stats.renamed}",
            f"Assigned properties:  {stats.assigned}",
            f"Linked prop/material: {stats.prop_material_linked}",
            f"Linked comp/property: {stats.comp_property_linked}",
            f"Linked elem/property: {stats.elem_property_linked}",
            f"Skipped components:   {stats.skipped}",
            f"Unmapped components:  {len(stats.unmapped)}",
            "",
            "Only components without property definition are displayed now.",
        ]
    )
    if stats.unmapped:
        lines.append("")
        lines.append("Components not found in component-material CSV:")
        lines.extend(f"  - {name}" for name in stats.unmapped)
    if stats.errors:
        lines.append("")
        lines.append("Warnings / errors:")
        lines.extend(f"  - {msg}" for msg in stats.errors)
    return "\n".join(lines)


def run(component_csv: str, material_csv: str) -> RunStats:
    model = _model()
    component_csv = os.path.abspath(component_csv)
    material_csv = os.path.abspath(material_csv)
    component_map = read_component_map(component_csv)
    material_blocks = read_material_blocks(material_csv)
    material_names = unique_material_names(component_map)
    material_by_name = ensure_materials(model, material_names, material_blocks, os.path.dirname(material_csv))

    _hm, ent = _hm_modules()
    stats = RunStats()
    for comp in list(_collection(model, ent.Component)):
        old_name = comp.name
        mapped, lookup_name, mat_name = component_material(component_map, old_name)
        if not mapped:
            stats.unmapped.append(old_name)
            stats.skipped += 1
            continue

        try:
            mesh_kind = component_mesh_kind(model, comp)
            if mesh_kind in {"mixed", "unknown"}:
                stats.errors.append(f"{old_name}: mesh type is {mesh_kind}; property not assigned.")
                stats.skipped += 1
                continue

            mat = material_by_name[mat_name]
            target_name = safe_name(f"{lookup_name}@{mat_name}")
            final_name = unique_component_name(model, target_name, comp.id)
            if comp.name != final_name:
                comp.name = final_name
                stats.renamed += 1

            prop = ensure_property(model, final_name, mesh_kind, mat)
            linked_elems = assign_property_to_component(model, comp, prop, mat)

            stats.processed += 1
            stats.assigned += 1
            stats.prop_material_linked += 1
            stats.comp_property_linked += 1
            stats.elem_property_linked += linked_elems
        except Exception as exc:
            stats.errors.append(f"{old_name}: {exc}")
            stats.skipped += 1

    try:
        show_only_unassigned_components(model)
    except Exception as exc:
        stats.errors.append(f"Display filter failed: {exc}")
    return stats


def show_tk_gui():
    import tkinter as tk
    from tkinter import filedialog, messagebox, scrolledtext

    root = tk.Toplevel() if tk._default_root else tk.Tk()
    root.title("HyperMesh 2025 Material Assign")
    root.geometry("720x460")
    root.minsize(680, 430)
    root.attributes("-topmost", True)

    component_var = tk.StringVar()
    material_var = tk.StringVar()
    status_var = tk.StringVar(value="Ready")

    body = tk.Frame(root, padx=12, pady=12)
    body.pack(fill=tk.BOTH, expand=True)
    body.columnconfigure(1, weight=1)
    body.rowconfigure(4, weight=1)

    def browse(target_var: tk.StringVar, title: str) -> None:
        path = filedialog.askopenfilename(
            parent=root,
            title=title,
            filetypes=[("CSV files", "*.csv"), ("All files", "*.*")],
        )
        if path:
            target_var.set(os.path.abspath(path))

    def set_output(message: str) -> None:
        output.configure(state=tk.NORMAL)
        output.delete("1.0", tk.END)
        output.insert(tk.END, message)
        output.configure(state=tk.DISABLED)

    def on_run() -> None:
        comp_csv = component_var.get().strip()
        mat_csv = material_var.get().strip()
        if not comp_csv or not mat_csv:
            messagebox.showwarning("Missing CSV", "Please select both CSV files.", parent=root)
            root.lift()
            return
        try:
            status_var.set("Running...")
            set_output("Running, please wait...")
            root.update_idletasks()
            stats = run(comp_csv, mat_csv)
            message = stats_text(stats, comp_csv, mat_csv)
            status_var.set("Completed")
            set_output(message)
            messagebox.showinfo("Material assignment completed", message, parent=root)
        except Exception:
            message = traceback.format_exc()
            status_var.set("Failed")
            set_output(message)
            messagebox.showerror("Material assignment failed", message, parent=root)
        finally:
            root.lift()

    tk.Label(body, text="HyperMesh 2025 Material Assign", font=("Arial", 12, "bold")).grid(
        row=0, column=0, columnspan=3, sticky="w", pady=(0, 10)
    )

    tk.Label(body, text="Component map CSV").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=4)
    tk.Entry(body, textvariable=component_var).grid(row=1, column=1, sticky="ew", pady=4)
    tk.Button(body, text="Browse...", command=lambda: browse(component_var, "Select component-material CSV")).grid(
        row=1, column=2, padx=(8, 0), pady=4
    )

    tk.Label(body, text="Material definition CSV").grid(row=2, column=0, sticky="w", padx=(0, 8), pady=4)
    tk.Entry(body, textvariable=material_var).grid(row=2, column=1, sticky="ew", pady=4)
    tk.Button(body, text="Browse...", command=lambda: browse(material_var, "Select material definition CSV")).grid(
        row=2, column=2, padx=(8, 0), pady=4
    )

    actions = tk.Frame(body)
    actions.grid(row=3, column=0, columnspan=3, sticky="w", pady=(10, 8))
    tk.Button(actions, text="Run", width=12, command=on_run).pack(side=tk.LEFT)
    tk.Button(actions, text="Close", width=12, command=root.destroy).pack(side=tk.LEFT, padx=8)
    tk.Label(actions, textvariable=status_var).pack(side=tk.LEFT, padx=16)

    output = scrolledtext.ScrolledText(body, height=12, wrap=tk.WORD)
    output.grid(row=4, column=0, columnspan=3, sticky="nsew")
    set_output("Select both CSV files, then click Run.")

    root.lift()
    return root


def show_gui():
    return show_tk_gui()


def main(component_csv: Optional[str] = None, material_csv: Optional[str] = None):
    if component_csv and material_csv:
        stats = run(component_csv, material_csv)
        print(stats_text(stats, component_csv, material_csv))
        return stats
    return show_gui()


if __name__ == "__main__":
    main()
