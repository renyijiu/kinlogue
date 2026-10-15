# 品牌说明

本页维护续页（Kinlogue）的名称、定位、标语和应用图标。界面配色与组件状态由 [`design-system.md`](design-system.md) 维护，当前产品能力由 [`project-overview.md`](project-overview.md) 维护。本页末尾的“方向”一节描述尚未实现的计划，不能当作当前能力引用。

## 名称

| 项 | 当前值 | 依据 |
| --- | --- | --- |
| 中文名 | 续页 | [`Info.plist`](../packaging/Info.plist) 的 `CFBundleDisplayName` |
| 英文名 | Kinlogue，读作 KIN-log | [`InfoPlist.strings`](../Sources/KinlogueApp/Resources/en.lproj/InfoPlist.strings) |

- **续页**：每个人的健康资料一页页延续，新的一页总能接上过去。
- **Kinlogue**：`Kin` 指自己和家人，`-logue` 联想到记录、档案与对话。

两个名称在 2026-10-11 的定位调整中保持不变，取舍见 [`decisions.md`](decisions.md)。

## 当前定位

**以人为单位，一人管全家。** 每位家庭成员有自己的资料与时间线；由一位使用者在一台 Mac 上统一导入、确认和查找。这与单一操作员、多家庭成员的现有实现一致，不引入账号或多人协作。

| 用途 | 文案 |
| --- | --- |
| 中文标语 | 你和家人的健康记录，前后相续。 |
| 英文标语 | Your health history and your family’s, continued. |
| 一句话定位 | 把你和家人的每次检查，续成各自一条复诊时随手可查的健康记录。 |
| 图标文案 | 翻开一页，接上过去。 |

## 文案规则

- 先写“你”，再写“家人”：`你和家人`、`for you and your kin`。
- 只描述当前版本能做的事。续页整理、检索和呈现来源明确的记录，不写成诊断、问诊、趋势判断或治疗建议。
- 不使用“AI 医生”“智能诊断”一类说法，也不把 OCR 候选写成结论。
- 明文存储、普通 HTTP 和未执行的验收门禁保持可见，不被“隐私优先”“本机优先”的表述掩盖。

## 应用图标

**意象**：纸页翻起一角，一条连续的线从页下延伸出来，串起三个节点。纸页是有来源的原件；线是一个人前后相续的健康线索；节点是这条线上不同时间的记录。

**构造**：1024 × 1024 画布，824 × 824 的圆角底板居中，圆角半径 185。底板为暖象牙白 `#F7F1E4`，纸页为深玉绿 `#1E6254`，翻起的页背为 `#15453B`，线为深玉绿，节点为柔和杏色 `#DF8A4A` 并带象牙白描边。这些取值与设计系统的品牌母色和主按钮 Hover 色一致。

**不使用的符号**：医疗十字、心电图、盾牌、云端和 AI 星光。

### 母版与生成

| 文件 | 用途 |
| --- | --- |
| [`packaging/AppIcon.svg`](../packaging/AppIcon.svg) | 常规母版，用于 64 像素及以上的表示和 README 展示图 |
| [`packaging/AppIcon-small.svg`](../packaging/AppIcon-small.svg) | 小尺寸母版，线更粗、只保留末端节点，用于 16 和 32 像素的表示 |
| [`scripts/render-app-icon.swift`](../scripts/render-app-icon.swift) | 从两个母版渲染 `packaging/AppIcon.png` 和 `packaging/Kinlogue.iconset/` 的 10 个表示 |

修改图标时只改 SVG 母版，再重新生成位图：

```sh
swift scripts/render-app-icon.swift packaging
```

位图是提交内容。[`scripts/build-app.sh`](../scripts/build-app.sh) 在构建时用 [`scripts/generate-icns.swift`](../scripts/generate-icns.swift) 把 iconset 打包为 `Kinlogue.icns`，不会重新渲染 SVG。

重新生成后，必须在 [`scripts/privacy-history-media-digests.txt`](../scripts/privacy-history-media-digests.txt) 中为每个变化的路径**追加**新的 SHA-256 行，保留旧行：被替换的位图仍留在可达历史里，历史门禁要求每个历史版本都对应一条已审查摘要。门禁语义见 [`privacy-and-security.md`](privacy-and-security.md)。

### 未验证

- 图标在 macOS 26 和 macOS 27 的 Dock、Finder 与“应用程序”文件夹中的实际显示尚未人工核对。
- 没有提供深色、着色或分层外观的图标变体；系统对这些外观的处理待验证。
- 16 和 32 像素表示只做过离屏放大检查，没有在真实菜单和列表密度下核对。

## 方向（尚未实现）

以下内容是 2026-10-11 记录的产品方向，**当前版本不包含其中任何能力**。在对应决策完成并落地之前，[`project-overview.md`](project-overview.md) 的“当前明确不做”和 [`../PRIVACY.md`](../PRIVACY.md) 的承诺继续有效。

**方向**：从健康记录整理延伸为健康助手。计划接入运动数据，并接入模型，让使用者以某一位成员的资料为上下文了解和询问健康信息。

**落地前必须先决定**：

1. 运动数据从哪里来。HealthKit 在 macOS 上能否读取数据待核实；若不能，需要决定是否增加 iPhone 端或文件导入。
2. 模型在本机运行还是联网调用。联网会改变“不连接互联网或云服务”的当前承诺。
3. 模型输出如何保持在非诊断边界内，以及它与用户已确认的来源转录如何区分。
4. `README.md`、`PRIVACY.md`、[`privacy-and-security.md`](privacy-and-security.md) 和相关验收脚本如何同步改写。

2026-10-15 提议的第一步见 [成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md)：只做模型问答，首版由使用者本机已登录的 Codex CLI 提供模型（Claude Code 留待后续）；它回答了上面第 2、3 项的候选做法，但仍待决策和实现。

**落地时采用的品牌约束**（推断，待届时确认）：

- 助手一次只使用一位成员的资料作为上下文，不混用不同成员的数据，除非使用者明确要求对比。
- 不承诺每位成员的数据同样完整：运动数据通常只来自操作者自己的设备。
- 模型生成的内容在界面上与已确认记录明确区分，并能回到所引用的原件。
- 届时的候选文案：品类描述“续页 · 你和家人的健康助手”，标语“你和家人的健康，有据可问。”与 *Health in context, for you and your kin.* 在助手能力上线前不使用这些文案。

## 相关页面

- 产品契约：[`project-overview.md`](project-overview.md)
- 决策与替代方案：[`decisions.md`](decisions.md)
- 界面配色与组件：[`design-system.md`](design-system.md)
- 界面文案与本地化流程：[`localization.md`](localization.md)
