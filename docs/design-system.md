# Warm Sanctuary 设计系统

Kinlogue（续页）的视觉语言以 **Warm Sanctuary** 为核心：减少传统医疗软件的冷硬感，同时保留健康资料产品需要的专业、隐私感与可读性。整体应呈现“如纸张般温润、如玉石般可信”的体验。

本文是配色、组件状态和无障碍取舍的单一产品规范。实现位置：

- macOS SwiftUI 令牌与组件样式：`Sources/KinlogueApp/Views/KinlogueTheme.swift`
- 手机浏览器上传页：`Sources/KinloguePlatform/Resources/LANUpload/styles.css`

仓库当前包含原生 macOS App，以及由 Mac 在局域网临时提供的手机浏览器上传页；不包含原生 iOS 或 Android App。

品牌母色为深玉绿 `#1E6254`、暖象牙白 `#F7F1E4` 和柔和杏色 `#DF8A4A`。当前界面为了建立纸张层级，使用更浅的 `#FFF8F5` 作为主 Surface，并以 `#F5ECE7` 作为 Container；它们是暖象牙白在产品界面中的功能性色阶，不改变品牌母色定义。

## 核心配色

| 角色 | 颜色值 | 视觉意象 | 用途 |
| --- | --- | --- | --- |
| Primary | `#1E6254` | 深玉绿 | 品牌识别、主按钮、标题、时间轴、确认状态 |
| Surface | `#FFF8F5` | 暖象牙白 | 应用和页面主背景，模拟纸张质感 |
| Container | `#F5ECE7` | 温润象牙 | 非交互卡片、搜索框、信息容器 |
| Accent | `#DF8A4A` | 柔和杏色 | 需要关注的健康节点、提醒与强调 |
| On Surface | `#1E1B18` | 深炭灰 | 主文本与高优先级信息 |
| On Variant | `#3F4946` | 玉灰色 | 辅助说明和次要图标 |
| Outline | `#BFC9C4` | 浅玉灰 | 次要按钮、输入框和容器边界 |
| Chip | `#E9E1DC` | 浅暖灰 | 中性功能标签 |
| Selection | `#F5ECE7` | 温润象牙 | 侧边栏与影像库检查选中行的自定义背景 |
| Selection Foreground | `#1E6254` | 深玉绿 | 侧边栏与影像库检查选中行的文字和图标 |
| Selection Hover | `#1E6254` at 8% | 淡深玉绿 | 侧边栏与影像库检查未选中行的悬停底色 |
| Card | `#FFFFFF` | 白纸 | 可交互卡片常规状态 |
| Card Hover | `#FBF2ED` | 极浅象牙 | 可交互卡片悬停状态 |

颜色名描述用途，不描述具体色值。业务代码应引用 `KinlogueTheme.primary`、`surface`、`container` 等语义令牌，避免复制 RGB 或十六进制值。

## 交互状态

### 主按钮

| 状态 | 背景 | 文字 | 反馈 |
| --- | --- | --- | --- |
| Normal | `#1E6254` | 白色 | 轻微静态阴影 |
| Hover | `#15453B` | 白色 | 阴影提升 |
| Active | `#0F322B` | 白色 | 缩放至 95% |
| Disabled | Normal 降低透明度 | 白色 | 不响应指针 |

SwiftUI 主操作统一使用 `.buttonStyle(.kinloguePrimary)`。手机页面的普通 `button` 对应相同状态。

### 次要按钮

| 状态 | 边框 | 文字 | 背景与反馈 |
| --- | --- | --- | --- |
| Normal | `#BFC9C4` | `#1E6254` | 透明 |
| Hover | `#1E6254` | `#1E6254` | 10% Primary |
| Active | `#1E6254` | `#1E6254` | 20% Primary，轻微下移 |

SwiftUI 独立次要操作可使用 `.buttonStyle(.kinlogueSecondary)`。取消、删除、工具栏按钮等具有明确 macOS 语义的控件继续使用系统样式，不应为了视觉统一覆盖其角色。

### 功能标签

- Neutral：`#E9E1DC` 背景，`#3F4946` 文字。
- Selected：`#1E6254` 背景，白色文字。
- Accent：`#DF8A4A` 背景，`#1E1B18` 文字。

原始提案中的 Accent 白字与 `#DF8A4A` 对比度不足，因此实现使用深炭灰文字。SwiftUI 使用 `.kinlogueChip()`，选中和强调状态分别传入 `.selected` 或 `.accent`。

### 卡片与列表

- 可交互卡片常规背景为 `#FFFFFF`，悬停切换到 `#FBF2ED`，阴影由小提升到中等。
- 独立可交互卡片按下时缩放至 95%；当前时间线记录卡使用 `.buttonStyle(.kinlogueCard(isHighlighted:))`。
- 时间线卡片的常规与选中描边必须使用组件内描边；记录紧邻排列时，后一张卡片不能覆盖前一张卡片的下边界。
- 原生 `List` 行不统一缩放。缩放整个系统列表行容易造成选中位置跳动，也不符合 macOS 列表行为。
- 常规非交互信息卡使用 Container，不增加悬停或按压反馈，避免暗示可点击。
- 白色模态弹窗中的大面积说明卡使用 Card + Outline，以描边建立层级，避免在白色画布中嵌套大块暖灰背景。

## macOS 适配规则

1. 保留控件角色。破坏性操作继续使用 `role: .destructive`；取消操作和工具栏按钮优先使用系统外观。窗口工具栏只统一背景为 Surface，不重做交通灯、按钮形态或键盘行为。
2. 保留键盘语义。主操作仍可使用 `.keyboardShortcut(.defaultAction)`，取消操作使用 `.cancelAction`。
3. 自定义按钮和卡片不能移除可访问性标签、提示、禁用状态或键盘激活能力。
4. `Reduce Motion` 开启时不执行按压缩放和状态动画，颜色仍即时变化。
5. `Increase Contrast` 开启时增加组件描边，并提高辅助文字对比度。
6. 不使用颜色作为唯一状态信号；状态应同时包含文本或 SF Symbol。
7. 当前色板是明确的亮色 Warm Sanctuary 方案。手机上传页声明 `color-scheme: light`，macOS 根视图明确采用亮色外观，避免系统自适应文字与固定浅色背景产生低对比度。后续若完整支持深色外观，应先补齐经过对比度验证的深色色板，不能只反转颜色。
8. 侧边栏只使用原生 `List` 承担分区、滚动和布局，不把导航状态交给 `List(selection:)`。全部记录、医学影像、手机上传、成员和设置使用可键盘激活的 plain Button 更新专用选择模型，并显式附加 `.isSelected` 无障碍 trait；上下方向键按可见顺序移动焦点和选择。主要导航、成员、添加成员、待确认动作和设置行的标签命中区域必须撑满可用行宽且至少 44pt 高；视觉选中/悬停背景与实际命中区域保持一致，成员尾部管理菜单仍是独立按钮。医学影像主导航不显示已确认检查总数，避免与“待确认”状态混淆；待确认影像继续只在待确认分区逐项显示。导航按钮关闭系统蓝色 focus effect 后必须显示 2pt Primary 自定义焦点描边，不能留下不可见焦点。选中 Tab 使用 `#F5ECE7` Container 背景与 `#1E6254` Primary 文字/图标；未选中 Tab 使用透明背景与 `#3F4946` 文字，悬停只显示 Primary 8% 底色。完整 Tab/方向键/VoiceOver 行为仍需人工矩阵复核，不能用源码 trait 或纯函数断言代替。
9. 手机上传待确认列表继续使用原生 `List(selection:)` 支持单选和多选，但不能把固定浅色行背景与系统选中白字混用。选中行背景使用 Container，文件名使用 On Surface，状态/大小/日期使用 On Variant，预览与重试使用 Primary，删除保留 destructive red；这些前景色必须显式设置，避免窗口焦点变化后被系统选中前景覆盖。
10. 侧边栏中的“添加家庭成员”“待确认”和“待确认影像”属于命令，不属于导航选择。它们使用独立的全宽 plain Button 与矩形命中区域，不附加 `.selectionDisabled()`；文字、行内空白和尾随箭头都必须触发同一个动作。
11. 医学影像库的检查列表只使用原生 `List` 承担滚动与布局，不把检查选择交给 `List(selection:)`，避免 macOS 系统蓝色覆盖 Warm Sanctuary 色板。检查行使用全宽 plain Button 更新专用选择模型：选中为 Selection 背景与 Selection Foreground，悬停为 Selection Hover；关闭系统蓝色 focus effect 后显示 2pt Primary 焦点描边，并保留上下方向键相邻选择和 `.isSelected` 无障碍 trait。中栏列表与右侧详情必须分别直接观察同一个影像库选择模型；首次选择检查后，右侧摘要和操作立即替换空状态，不能等待父级导航或其他无关状态刷新。完整 Tab/方向键/VoiceOver 行为仍需人工矩阵复核。
12. 整个本机资料库的删除不放在主窗口工具栏。入口只位于“设置 → 数据管理”的普通 Card 内，按钮保留系统 destructive 语义，并显式使用红色前景与 tint；设置卡片右侧的语言选择器、备份目录、原始文件导出和删除操作使用同宽、右对齐的控制列，备份与恢复动作行也沿卡片右内边距对齐。进入删除弹窗后还必须输入当前界面展示的精确短语才能启用最终操作，中文为“彻底删除”，英文为“Permanently Delete”。
13. 窗口工具栏中的纯图标操作必须提供随 App 语言解析的原生悬停帮助文本。提示应描述点击后的操作，而不是复述 SF Symbol 外观；当按钮行为随状态变化时，提示也必须同步更新。现有菜单快捷键继续由系统菜单公开，不在帮助文本中维护第二份快捷键映射。
14. 已确认记录编辑页的“检查结果”“检查结论”和“我的备注”使用同一原生多行文本组件。文本容器四周至少保留 8pt 内容边距，并使用 Card + Outline 明确输入范围；不能只增加外层留白或最小高度，因为那不会把首行字形移出 `NSTextView` 的裁切边界。
15. “导出全部原始文件”与删除使用两个独立设置 Card；导出是普通 Primary 操作，不使用 destructive 红色。导出 sheet 必须先显示明文、非备份和外部副本保留范围，再允许打开系统保存面板。写入和验证阶段显示线性进度、文件数与字节数并提供取消；最终提交阶段移除取消入口并禁止交互式关闭。成功态提供“在访达中显示”和“完成”，失败、空内容和取消均有明确文本/SF Symbol，不能只靠颜色区分。完整键盘、保存面板和 VoiceOver 公告仍需人工验收。
16. DICOM 待确认 review 在初始加载、保存、删除以及仍为 `needsReview` 的稳定状态下都禁止交互式关闭，根视图 Escape 与 sheet dismissal 使用同一 policy；初始加载失败或已确认检查的稳定 review 保留明确关闭路径。删除检查或整库时，相关 Viewer 窗口先清空像素并等待底层 close，再由系统 dismiss；不能只关闭当前发起操作的一个窗口。

## 组件映射

| 产品界面 | 使用方式 |
| --- | --- |
| App、时间线、收件箱主背景 | Surface |
| 窗口标题栏与工具栏背景 | Surface；控件保留 macOS 系统外观；纯图标操作提供本地化原生悬停帮助 |
| 侧边栏大背景 | Surface；选中 Tab 使用 Container |
| 医学影像库检查行 | 常规 Surface；选中 Selection + Selection Foreground；悬停 Selection Hover；焦点使用 Primary 描边 |
| 手机上传待确认行 | 常规 Surface；选中 Container；正文 On Surface、辅助信息 On Variant、操作使用 Primary/destructive |
| 收件箱底部操作区 | Container |
| 设置中的本机数据管理 | 导出与删除使用独立普通 Card + Outline；右侧控件固定 intrinsic 尺寸后使用同宽右对齐列，操作的右边缘与卡片右内边距一致。导出使用普通操作语义，删除使用系统 destructive/red 语义；主工具栏不提供这两个整库入口 |
| 原始文件导出 sheet | 600×480 固定工作区；warning/checking/choosing/exporting/cancelling/cancelled/empty/failed/succeeded 语义状态。进度只显示聚合计数与大小，不显示敏感路径；active/commit 阶段禁止交互式关闭 |
| 详情信息块、搜索框 | Container + Outline |
| 已确认记录多行编辑器 | 原生 `NSTextView`；文本容器 8pt 内容边距；Card + Outline；三个多行字段保持一致 |
| 内嵌原件预览 | 报告详情、导入确认、已确认记录编辑、报告对比和手机上传页序统一按预览区宽度等比显示；超出区域可独立滚动；工具栏提供 60%–240% 缩放，图片额外提供左右 90° 旋转；旋转只属于当前查看状态，不修改原件、来源顺序或 OCR；只有宿主提供独立查看器时才显示“查看原图”入口。图片解码与 PDF 文档打开、所选页元数据读取、当前页栅格化都在各自的串行 actor 中完成；PDF open 只发布页数，不预扫全部页面。主线程只发布不可变图像；页码或渲染尺寸变化会取消旧请求并拒绝晚到结果。 |
| DICOM Viewer 窗口 | 从确认页、家庭时间线或医学影像库统一打开标准 macOS 独立窗口；保留原生关闭、最小化、缩放/全屏控件和拖边调整大小，不使用无标题栏的 sheet 承载 Viewer |
| DICOM Series 选择 | Viewer 在所有窗口宽度使用原生菜单式 Picker；选项显示序列序号和切片数，切换后由现有加载状态反馈结果；前后序列按钮只作为相邻导航快捷入口，不另设宽窗口侧栏列表 |
| “从手机接收资料”弹窗及安全说明卡 | Card；说明卡增加 Outline |
| 保存、比较、开始接收、确认归档 | Primary Button |
| 时间线记录 | Interactive Card |
| 成员、来源等标签 | Neutral Chip |
| 时间轴和成功/可归档状态 | Primary |
| 警告和关键提醒 | Accent，并配合文本或图标 |
| 错误与永久删除 | 系统 destructive/red 语义，不改用 Accent |

## 使用约束

- 不在页面文件中新增品牌色 RGB、十六进制常量或同义颜色。
- Accent 不用于长段正文，也不与白字组合显示小号文本。
- 不把所有按钮都改成 Primary；一个操作区域通常只有一个明显主操作。
- 不给静态容器添加 hover、阴影提升或缩放。
- 阴影只用于表达层级或交互，不用于装饰大面积背景。

## 验证清单

视觉变更提交前至少检查：

- 普通、悬停、按下、禁用四种按钮状态。
- 键盘 Tab 导航、默认按钮和 Escape 取消。
- VoiceOver 名称、值与提示仍可理解。
- 开启“减少动态效果”后没有缩放动画。
- 开启“提高对比度”后边界和辅助文字清晰。
- 标题栏与主画布保持暖色连续，不出现系统白色工具栏断层，原生窗口控件仍正常。
- 窄窗口下主按钮不会压缩标签或挤出操作区。
- 竖版图片和 PDF 默认占满原件预览宽度；图片旋转后按新的横竖方向重新计算适配尺寸，左右旋转、缩放、双向滚动和“查看原图”入口互不遮挡；PDF 保持原始页面方向。
- PDF 预览打开时不遍历全部页面，只按当前 `(sessionID, pageIndex)` 读取并缓存有限页 metadata；当前页栅格化最长边不超过 4,000 px、页缩放不超过 5 倍。`PDFDocument`、`PDFPage` 和 PDFKit 生成的 `NSImage` 不进入 SwiftUI/MainActor 状态，切页或连续缩放的旧任务即使完成也不能覆盖当前页，无效页显示既有 unavailable 状态。
- 手机上传页在窄屏和桌面浏览器下均无横向滚动。
