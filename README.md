# HyperMesh 材料自动读取和赋值工具

本项目现在保留两个版本：

- HyperMesh 2019 Tcl 版：`hm_material_assign.tcl`
- HyperMesh 2025 Python 版：`hm_material_assign_2025.py`

两个版本共用同样的 CSV 格式和处理规则。

## HyperMesh 2025 Python 版

在 HyperMesh 2025 的 Python Window 中执行：

```python
exec(open(r"D:/code_ai/codex/start_gui_2025.py", encoding="utf-8").read())
```

也可以直接运行主文件：

```python
exec(open(r"D:/code_ai/codex/hm_material_assign_2025.py", encoding="utf-8").read())
```

如果要用代码直接指定 CSV：

```python
import sys
sys.path.append(r"D:/code_ai/codex")

import hm_material_assign_2025 as hmma25

stats = hmma25.run(
    r"D:/code_ai/codex/examples/component_material.csv",
    r"D:/code_ai/codex/examples/materials.csv",
)
print(hmma25.stats_text(stats))
```

Python 版会执行：

- 遍历当前模型中的所有 components
- 根据组件-材料映射重命名组件
- 自动导入材料
- 创建或复用 property
- 设置 `property -> material`
- 设置 `component -> property`
- 同步设置 `element -> property`
- 完成后只显示没有定义 property 的 components

## HyperMesh 2019 Tcl 版

在 HyperMesh Tcl Console 中执行：

```tcl
source D:/code_ai/codex/start_gui.tcl
```

或者：

```tcl
source D:/code_ai/codex/hm_material_assign.tcl
hmma
```

## 重命名规则

程序会对映射表中出现的所有组件执行同一规则：

```text
原始组件名@映射材料
```

例如：

```text
Part_A + Q275   -> Part_A@Q275
Part_B + AL6061 -> Part_B@AL6061
```

如果组件已经是 `Part_A@Q275` 或误变成 `Part_A@@Q275`，程序会先识别基础名 `Part_A`，再重新生成正确目标名，避免重复叠加 `@材料名`。

## CSV 格式

### 组件-材料映射 CSV

第一列为 HyperMesh 中已有的 component 名称，第二列为材料名称。

```csv
component,material
Part_A,Q275
Part_B,AL6061
```

### 材料定义 CSV

第一列为材料名称，第二列为完整或局部 Abaqus inp 材料卡片。

```csv
material,inp
Q275,"*Material, name=Q275\n*Elastic\n206000.,0.3\n*Density\n7.85e-9"
AL6061,"*Material, name=AL6061\n*Elastic\n69000.,0.33\n*Density\n2.70e-9"
```

注意：Abaqus inp 内容通常含有逗号，第二列必须用英文双引号包起来。可以在单元格里使用真实换行，也可以使用 `\n`。

如果材料定义没有以 `*Material, name=...` 开头，程序会自动补上材料名。

## GUI 运行结果

运行完成后会显示：

- 已处理组件数量
- 已重命名组件数量
- 已赋值属性数量
- `property -> material` 关联数量
- `component -> property` 关联数量
- `element -> property` 关联数量
- 跳过组件数量
- 映射表中找不到的组件列表
- 混合网格、无法识别网格等错误信息

## 需要确认的点

不同 Abaqus 模板或企业定制模板里，property card image 名称可能略有差异。当前使用：

- `SOLIDSECTION`
- `SHELLSECTION`

如果你的 HyperMesh 命令日志显示名称不同，请修改对应脚本中的 card image。

材料导入仍使用 HyperMesh 的 Abaqus reader：

```text
#abaqus/abaqus
```

如果你的安装中 reader 名称不同，请修改脚本顶部的 `IMPORT_READER`。
