# Warm Sanctuary 设计系统

Kinlogue（续页）的视觉语言以 **Warm Sanctuary** 为核心：减少传统医疗软件的冷硬感，同时保留健康资料产品需要的专业、隐私感与可读性。整体应呈现“如纸张般温润、如玉石般可信”的体验。

本文是配色、组件状态和无障碍取舍的单一产品规范。实现位置：

- macOS SwiftUI 令牌与组件样式：`Sources/KinlogueApp/Views/KinlogueTheme.swift`
- 手机浏览器上传页：`Sources/KinloguePlatform/Resources/LANUpload/styles.css`

仓库当前包含原生 macOS App，以及由 Mac 在局域网临时提供的手机浏览器上传页；不包含原生 iOS 或 Android App。

品牌母色为深玉绿 `#1E6254`、暖象牙白 `#F7F1E4` 和柔和杏色 `#DF8A4A`。当前界面为了建立纸张层级，使用更浅的 `#FFF8F5` 作为主 Surface，并以 `#F5ECE7` 作为 Container；它们是暖象牙白在产品界面中的功能性色阶，不改变品牌母色定义。名称、标语、应用图标的构造与重新生成方式由 [`brand.md`](brand.md) 维护；本页只维护界面令牌、组件状态和无障碍取舍。

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
| Chip Hover | `#1E6254` at 10% | 淡玉绿 | 可点选的中性功能标签悬停时叠在 Chip 上的一层 |
| Chip Pressed | `#1E6254` at 20% | 玉绿 | 可点选的中性功能标签按下期间叠在 Chip 上的一层 |
| Selection | `#1E6254` at 13% | 淡玉绿 | 列表行选中背景：侧边栏、手机上传待确认列表与报告页序 |
| Selection Foreground | `#1E6254` | 深玉绿 | 选中行的文字和图标 |
| Selection Hover | `#1E6254` at 5% | 极淡玉绿 | 未选中行的悬停底色 |
| Selection Pressed | `#1E6254` at 18% | 玉绿 | 行按下期间的底色 |
| Success | `#1E6254` | 深玉绿 | 成功与可归档状态，与 Primary 同值 |
| Warning | `#8A4712` | 深杏色 | 警告图标与短标签；Accent 同色相的可读文字色阶 |
| Warning Container | `#FFF4E9` | 淡杏色 | 整句警告横幅的背景，描边使用 Accent |
| Danger | `#8A302D` | 深砖红 | 错误文字、破坏性按钮的文字与图标 |
| Danger Container | `#F4E2DF` | 淡砖红 | 破坏性按钮背景；悬停 `#EDD3CF`，按下 `#E6C4BF` |
| Card | `#FFFFFF` | 白纸 | 可交互卡片常规状态 |
| Card Hover | `#FBF2ED` | 极浅象牙 | 可交互卡片悬停状态 |

颜色名描述用途，不描述具体色值。业务代码应引用 `KinlogueTheme.primary`、`surface`、`container` 等语义令牌，避免复制 RGB 或十六进制值。

三个行交互层使用半透明 Primary，使同一个值在 Surface、Card 和 Container 上都成立，并保证“按下重于选中、选中重于悬停”。选中层不再与 Container 共用，避免选中行与静态信息块、底部操作区同色。Warning、Danger 与两个 Container 取自手机上传页已有的 `.warning` 和 `button.destructive` 配色，两端保持一致。

圆角只有三档，定义在 `KinlogueTheme.Radius`：`control` 8pt（按钮、列表行、输入框、行内提示）、`card` 12pt（静态信息块、预览窗格、设置卡片）、`interactiveCard` 16pt（可点击的时间线卡片）。页面文件不写圆角数值。

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

内容区和 sheet 中的取消、关闭与普通操作统一使用 `.buttonStyle(.kinlogueSecondary)`，与主按钮同高、同圆角。系统样式只保留给窗口工具栏、系统确认框与警告框、菜单，以及 Picker、Toggle、文本框和日期选择等原生表单控件；这些位置不覆盖系统外观。DICOM Viewer 窗口的页眉与底部控制条整体视为工具栏，包含无法套用自定义按钮样式的 Menu 和 Picker，因此整条保留系统控件，只继承 Primary 强调色。

### 破坏性按钮

| 状态 | 背景 | 文字 | 反馈 |
| --- | --- | --- | --- |
| Normal | `#F4E2DF` | `#8A302D` | 无阴影 |
| Hover | `#EDD3CF` | `#8A302D` | 无 |
| Active | `#E6C4BF` | `#8A302D` | 轻微下移 |
| Disabled | Normal 降低透明度 | `#8A302D` | 不响应指针 |

内容区的删除、放弃、停止接收和整库替换使用 `.buttonStyle(.kinlogueDestructive)`，并继续声明 `role: .destructive`。系统确认框中的最终确认按钮保留原生 destructive 外观。

### 图标与紧凑按钮

行内的纯图标操作（预览、重试、排序、缩放、旋转、翻页、关闭提示）和紧凑文字操作（“查看原图”“查看已有资料”）使用 `.buttonStyle(.kinlogueGhost)`：至少 28×28pt 的命中区域，默认 Primary 前景，悬停 10% Primary 底色，按下 20%。`.kinlogueGhost(.neutral)` 使用 On Variant 前景，`.kinlogueGhost(.danger)` 使用 Danger 前景与 Danger Container 悬停底色。纯图标按钮必须提供无障碍标签。

### 列表行

自绘选择的列表行（侧边栏导航与命令行、报告页序行）共用同一组状态：悬停 Selection Hover、按下 Selection Pressed、选中 Selection + Selection Foreground、键盘焦点 2pt Primary 描边。行按钮使用 `.buttonStyle(.kinlogueRow { ... })` 上报按下状态，由拥有整行的视图通过 `KinlogueRowInteraction` 绘制一层底色，使带尾部菜单或操作按钮的行也只有一个完整高亮。

### 状态标签

- `KinlogueStatusLabel(_:tone:)` 用于单行状态：`.success` 为 Success + `checkmark.circle`，`.warning` 为 Warning + `exclamationmark.triangle`，`.danger` 为 Danger + `exclamationmark.octagon`。三种语气的符号互不相同，不依赖颜色区分。
- `KinlogueWarningNotice(_:)` 用于整句警告：Warning Container 背景、Accent 描边、On Surface 正文，只有符号使用 Warning。
- 页面不直接使用系统 `.red`、`.orange`、`.green`。

### 功能标签

- Neutral：`#E9E1DC` 背景，`#3F4946` 文字。
- Selected：`#1E6254` 背景，白色文字。
- Accent：`#DF8A4A` 背景，`#1E1B18` 文字。

原始提案中的 Accent 白字与 `#DF8A4A` 对比度不足，因此实现使用深炭灰文字。SwiftUI 使用 `.kinlogueChip()`，选中和强调状态分别传入 `.selected` 或 `.accent`。

可点选的功能标签（当前只有时间线类型筛选）不直接用 `.kinlogueChip()`，改用 `.buttonStyle(.kinlogueChip(isSelected:))`，静止外观与上面的 Neutral / Selected 相同，并补齐交互状态：未选中项悬停叠加 Chip Hover、按下叠加 Chip Pressed，文字保持 On Variant；选中项与主按钮一致，悬停 `#15453B`、按下 `#0F322B`，文字保持白色。只换颜色，不缩放也不位移；`Increase Contrast` 开启时增加与文字同色的描边，禁用时整体降低透明度。

### 卡片与列表

- 可交互卡片常规背景为 `#FFFFFF`，悬停切换到 `#FBF2ED`，阴影由小提升到中等。
- 独立可交互卡片按下时缩放至 95%；当前时间线记录卡使用 `.buttonStyle(.kinlogueCard(isHighlighted:))`。
- 时间线卡片的常规与选中描边必须使用组件内描边；记录紧邻排列时，后一张卡片不能覆盖前一张卡片的下边界。
- 原生 `List` 行不统一缩放。缩放整个系统列表行容易造成选中位置跳动，也不符合 macOS 列表行为。
- 常规非交互信息卡使用 Container，不增加悬停或按压反馈，避免暗示可点击。
- 所有 sheet 使用与主窗口相同的 Surface 画布（`.kinlogueSheetCanvas()`）。只读信息块使用 Container + Outline；承载控件或作为弹窗主体的块（手机接收说明卡、二维码、恢复码、设置卡片）使用 Card + Outline。两者统一通过 `.kinloguePanel(_:)` 绘制。
- 多行文本输入统一使用 `.kinlogueInputFrame()`（Card + Outline，8pt 圆角），SwiftUI `TextEditor` 需同时隐藏系统滚动背景。
- 原件预览的工具条、来源导航和文档底色使用 Container，不使用系统窗口背景色或 Material。

## macOS 适配规则

1. 保留控件角色。破坏性操作继续使用 `role: .destructive`；窗口工具栏、系统确认框和原生表单控件保留系统外观。窗口工具栏只统一背景为 Surface，不重做交通灯、按钮形态或键盘行为。
2. 保留键盘语义。主操作仍可使用 `.keyboardShortcut(.defaultAction)`，取消操作使用 `.cancelAction`；含多行编辑器的报告复核页改用 Command-Return，见第 24 条。
3. 自定义按钮和卡片不能移除可访问性标签、提示、禁用状态或键盘激活能力。
4. `Reduce Motion` 开启时不执行按压缩放和状态动画，颜色仍即时变化。
5. `Increase Contrast` 开启时增加组件描边，并提高辅助文字对比度。
6. 不使用颜色作为唯一状态信号；状态应同时包含文本或 SF Symbol。
7. 当前色板是明确的亮色 Warm Sanctuary 方案。手机上传页声明 `color-scheme: light`；macOS 端的主窗口、DICOM Viewer 窗口、每个 sheet 和日期选择 popover 都各自通过 `.kinlogueAppearance()`（sheet 为 `.kinlogueSheetCanvas()`）声明 Primary 强调色与亮色外观，不依赖一个 presentation 的 tint 或配色方案传递到另一个，避免系统自适应文字与固定浅色背景产生低对比度。DICOM Viewer 中叠在黑色影像画布上的加载、空状态和失败浮层固定使用深色 Material 与浅色文字。日期选择 popover 内只有一个原生日历控件，因此关闭它的内层底框和系统焦点环，由 popover 本身充当边框，选中日即键盘焦点指示。SwiftUI 的 tint 到达不了 AppKit 自绘的部分，所以正式 App 包另带一个与 Primary 同值的 `AccentColor` 资源（[`packaging/Assets.xcassets`](../packaging/Assets.xcassets)，由 `Info.plist` 的 `NSAccentColorName` 声明），原生控件的键盘焦点环、文本选区、日历选中日和系统确认框的默认按钮随之使用玉绿。这个资源只在用户的系统强调色保持默认“多色”时生效；用户在系统设置里选了具体强调色时，原生控件按 macOS 的规则跟随用户的选择，SwiftUI 控件仍为 Primary。`swift build` 直接产出的可执行文件和测试进程没有主包资源，不体现这一颜色。后续若完整支持深色外观，应先补齐经过对比度验证的深色色板，不能只反转颜色。
8. 侧边栏只使用原生 `List` 承担分区、滚动和布局，不把导航状态交给 `List(selection:)`。全部记录、手机上传、成员和设置使用可键盘激活的 plain Button 更新专用选择模型，并显式附加 `.isSelected` 无障碍 trait；上下方向键按可见顺序移动焦点和选择。主要导航、成员、添加成员、待确认动作和设置行的标签命中区域必须撑满可用行宽且至少 44pt 高；视觉选中/悬停背景与实际命中区域保持一致，成员尾部管理菜单仍是独立按钮。已确认医学影像不占用侧边栏导航项，只经成员时间线进入；待确认影像继续只在待确认分区逐项显示。导航按钮关闭系统蓝色 focus effect 后必须显示 2pt Primary 自定义焦点描边，不能留下不可见焦点。侧边栏样式的 `List` 会把普通 `Label` 的图标染成强调色，并在窗口不活跃时置灰，不跟随行的前景色；因此导航行和命令行都通过 `SidebarRowLabel` 在符号上显式设置颜色，使图标与文字始终同色。选中 Tab 使用 Selection 背景与 `#1E6254` Primary 文字/图标；未选中 Tab 使用透明背景与 `#3F4946` 文字，悬停显示 Selection Hover，按下期间显示 Selection Pressed。完整 Tab/方向键/VoiceOver 行为仍需人工矩阵复核，不能用源码 trait 或纯函数断言代替。
9. 手机上传待确认列表继续使用原生 `List(selection:)` 支持单选和多选，但不能把固定浅色行背景与系统选中白字混用。选中行背景使用叠在 Surface 上的 Selection（保持不透明，系统选中高亮不能透出），文件名使用 On Surface，状态/大小/日期使用 On Variant，预览与重试使用 Primary，删除使用 Danger；这些前景色由行内文本和 `.kinlogueGhost` 按钮显式设置，避免窗口焦点变化后被系统选中前景覆盖。
10. 侧边栏中的“添加家庭成员”“待确认”和“待确认影像”属于命令，不属于导航选择。它们使用独立的全宽行按钮与矩形命中区域，不附加 `.selectionDisabled()`；文字、行内空白和尾随箭头都必须触发同一个动作。命令行与导航行使用相同的 On Variant 前景、悬停与按下底色和 2pt Primary 焦点描边，但没有选中态；“识别失败，点按重试”同样是命令行，尾部的放弃按钮是独立的 Danger 图标按钮。
11. 已确认医学影像检查作为时间线卡片与报告同列，不另设列表。检查卡片使用与报告相同的 Interactive Card：选中时为 2pt Primary 组件内描边并附加 `.isSelected` 无障碍 trait，比较选择进行中禁用。时间线顶部的“全部 / 报告 / 影像”筛选使用可点选的功能标签而不是系统分段控件，避免系统强调色覆盖 Warm Sanctuary 色板：当前项为 Selected 标签并带对勾，其他项为 Neutral 标签，悬停与按下状态见“功能标签”；状态不只靠颜色表达。资料库中没有已确认检查时不显示筛选。中栏时间线与右侧详情必须分别直接观察同一个影像选择模型；选中检查后右侧摘要和操作立即替换报告详情，不能等待父级导航或其他无关状态刷新。实现与门禁见 [`TimelineView`](../Sources/KinlogueApp/Views/TimelineView.swift)、[`KinlogueThemeSourceTests`](../Tests/KinlogueAppTests/KinlogueThemeSourceTests.swift) 和 [`DICOMStudyDetailViewTests`](../Tests/KinlogueAppTests/DICOMStudyDetailViewTests.swift)。筛选标签的悬停与按下反馈，以及筛选标签与卡片的 Tab/VoiceOver 行为仍需人工矩阵复核。
12. 整个本机资料库的删除不放在主窗口工具栏。入口只位于“设置 → 数据管理”的普通 Card 内，按钮保留 `role: .destructive` 语义并使用破坏性按钮样式；设置卡片右侧的语言选择器、备份目录、原始文件导出和删除操作使用同宽、右对齐的控制列，备份与恢复动作行也沿卡片右内边距对齐。进入删除弹窗后还必须输入当前界面展示的精确短语才能启用最终操作，中文为“彻底删除”，英文为“Permanently Delete”。
13. 窗口工具栏中的纯图标操作必须提供随 App 语言解析的原生悬停帮助文本。提示应描述点击后的操作，而不是复述 SF Symbol 外观；当按钮行为随状态变化时，提示也必须同步更新。现有菜单快捷键继续由系统菜单公开，不在帮助文本中维护第二份快捷键映射。
14. 已确认记录编辑页的“检查结果”“检查结论”和“我的备注”使用同一原生多行文本组件。文本容器四周至少保留 8pt 内容边距，并使用 Card + Outline 明确输入范围；不能只增加外层留白或最小高度，因为那不会把首行字形移出 `NSTextView` 的裁切边界。
15. “导出全部原始文件”与删除使用两个独立设置 Card；导出是普通操作，使用次要按钮样式，不使用破坏性样式。导出 sheet 必须先显示明文、非备份和外部副本保留范围，再允许打开系统保存面板。写入和验证阶段显示线性进度、文件数与字节数并提供取消；最终提交阶段移除取消入口并禁止交互式关闭。成功态提供“在访达中显示”和“完成”，失败、空内容和取消均有明确文本/SF Symbol，不能只靠颜色区分。完整键盘、保存面板和 VoiceOver 公告仍需人工验收。
16. DICOM 待确认 review 在初始加载、保存、删除以及仍为 `needsReview` 的稳定状态下都禁止交互式关闭，根视图 Escape 与 sheet dismissal 使用同一 policy；初始加载失败或已确认检查的稳定 review 保留明确关闭路径。删除检查或整库时，相关 Viewer 窗口先清空像素并等待底层 close，再由系统 dismiss；不能只关闭当前发起操作的一个窗口。
17. 报告复核在重新识别、确认、稍后处理或删除进行中禁用整个编辑表单，避免请求已经捕获字段后仍接受无法保存的新输入；失败结束后恢复编辑。原件仍可供核对。实现与门禁见 [`ImportReviewView`](../Sources/KinlogueApp/Views/ImportReviewView.swift) 和 [`ImportReviewViewSafetyTests`](../Tests/KinlogueAppTests/ImportReviewViewSafetyTests.swift)。
18. 报告详情随已接受的 catalog 快照更新到当前记录 revision，同时保留仍有效的原件选择与不可变原件；已打开编辑页仍保留自己的 revision，冲突后由用户明确重新载入。见 [`AppModelTests`](../Tests/KinlogueAppTests/AppModelTests.swift)。
19. 确认整库恢复后，正常和资料库不可用的启动路径都先清空报告、手机收件箱与所有独立 Viewer 状态，等待 Viewer 关闭后才激活恢复；成功或激活失败均禁止普通资料访问，直到重新启动。恢复前验证失败仍不进入这条破坏性边界。组装与跨模型检查见 [`AppComposition`](../Sources/KinlogueApp/App/AppComposition.swift) 和 [`RestoreModelTests`](../Tests/KinlogueAppTests/RestoreModelTests.swift)。
20. 报告时间线每次出现且没有打开任何记录时，自动打开当前可见时间线中最新的一条：启动完成、从手机上传/设置返回、切换“全部记录”或某位成员，以及资料库内容换代后界面重新载入（例如确认一份报告之后）。最新按时间线日期判断，所以确认报告后打开的不一定是刚确认的那一条。已经打开的记录不会被替换，已选中的医学影像检查同样算作已打开；搜索中、比较选择中或有 sheet/提示时不触发；只有日期未知的记录时打开其中一条。自动打开只挑报告，不会选中医学影像检查，筛选为“影像”时时间线没有报告因而不触发。这次打开不是用户点选的，原件读取失败时只在详情区显示“原件不可用”，不弹提示；用户手动点选同一条记录仍照常提示。删除当前记录后详情保持为空，直到时间线下一次出现。见 [`AppModel.openNewestRecordIfNothingIsOpen`](../Sources/KinlogueApp/App/AppModel.swift)、[`AppModelTests`](../Tests/KinlogueAppTests/AppModelTests.swift) 和 [`DICOMAppModelTests`](../Tests/KinlogueAppTests/DICOMAppModelTests.swift)。
21. 时间线卡片上的成员 Chip 只在“全部记录”显示。选中某位成员后窗口标题已经是该成员，每张报告卡和影像卡不再重复；搜索结果遵循同一规则。卡片的 VoiceOver 标签和值仍包含成员。
22. 侧边栏“待确认”分区标题显示草稿数量，每一行显示该草稿第一份原件的文件名，过长时中间截断并在悬停时给出全名；没有文件名时回退为“等待确认”。文件名是用户内容，不翻译。多份原件组成的草稿只显示第一份的名称；草稿标题保存在草稿文档里，侧边栏不为此逐份读取文档，因此不显示标题。
23. 导入或重试报告时，侧边栏列表与“设置”之间显示识别状态：一个不确定进度指示和“正在识别报告…”，一次选择多份文件时附带“第 n/总数 个”。这块状态不在滚动列表内，列表滚到任何位置都可见。识别持续超过 4 秒后追加一段说明，告诉用户识别仍在进行、系统首次识别需要准备模型；报告复核页的“重新识别并覆盖”使用同一段说明。说明只解释等待，不改变识别调用，也不在启动时预热。整库删除或恢复清空界面状态时这块状态随之清除，迟到的导入结果不能把它恢复出来。手机上传项的后台预处理不使用这块状态。
24. 报告复核页的“确认并加入时间线”可用 Command-Return 触发；逐字转录编辑器里的 Return 仍是换行，页面不设置 Return 默认按钮。快捷键先于输入法提交到达表单，所以当焦点控件还有未上屏的组合文字时这次按键不执行确认，用鼠标点按不受影响。已确认记录编辑页保持原有的 Return 默认按钮；SwiftUI 的一个按钮只能绑定一个快捷键，为它再加 Command-Return 需要一个不可见控件或放弃 Return，本轮没有做。
25. sheet 内联错误统一使用 `KinlogueStatusLabel(_:tone: .danger)`，即 Danger 前景加 `exclamationmark.octagon` 符号，不单独用有颜色的文字表示错误；错误在页面上保留到下一次操作。全局错误继续使用需要用户关闭的系统提示。Kinlogue 没有会滞留的成功状态行，成功结果由 sheet 关闭、时间线更新或页面内的结果说明表达，因此没有引入短暂浮层提示。

26. 搜索结果没有日期分组标题，因此每张报告卡片在标题下用日历符号显示报告日期，日期未知时写“日期未知”；时间线分组内的卡片不显示。搜索词出现在已确认检查结果的表格行里时，卡片在结论的位置放一个 Container 底的紧凑网格，逐格显示原文：第一格项目、第二格加粗、其余格 On Variant，数字使用等宽数字，每格单行截断；最多 8 行，超出时注明“还有 n 行匹配”（英文按单复数）。这一块不使用 Danger、Warning、Accent 或 Success，也不加任何符号，报告自己印的“↑”只作为原文出现；`TimelineViewSourceTests` 对这一点做源码检查。没有命中行、搜索词又不在标题、机构或日期里时，结论的位置换成命中字段的上下文摘录：前置 On Variant 的 `text.magnifyingglass` 符号，正文两行截断，两端被截处带省略号。卡片标题、机构、命中行和摘录里的搜索词用加粗加 Primary 标出，加粗保证不只靠颜色区分。VoiceOver 标签在成员和类型之后读出日期，再读出命中行或摘录；摘录两端的省略号只画在卡片上，不进入朗读。窄窗口下的截断和朗读需要人工核对。

27. 成员对话（实验）与报告详情共用详情栏，二者只显示一个。工具栏“对话”按钮只在 App 嵌入了 bridge、且设置中已开启时出现，选中某位成员后才可用，悬停帮助随状态变化。点选时间线里的报告卡或影像卡，或点回答里的来源 Chip，都会切回详情；同一成员的对话和同意在切换期间保留。面板头部的“历史对话”菜单列出这位成员保存的对话（更新时间、首个问题的开头、轮数），当前对话带对勾，菜单末尾是破坏性的“删除当前对话…”，删除前用系统确认框说明恢复点和已发送内容不受影响；显示的对话来自另一个 CLI 或模型时，输入框上方用 On Variant 文字说明继续提问会开始新对话。设置页的“已保存的对话”Card 在右侧控制列放破坏性按钮“删除全部对话…”，同样先确认。面板顶部用两行 On Variant 文字说明接收方（Codex 版本与模型）和发送范围（报告数、年月范围、大小），“查看发送内容”打开确认页。确认页是唯一给出同意的地方：先写接收方，再列出会发送和不会发送的内容；“不是匿名化、发送后无法撤回”使用 Warning 横幅；“包含检查机构名称”默认关闭，改动后需要重新确认；全文放在折叠区里。需要确认时，面板用一张 Card 取代输入框。回答放在 Card 中，顶部是 On Variant 的“模型生成 · 可能有误 · 不是诊断”，正文为 On Surface，只保留行内强调并去掉链接，不用 Danger、Warning、Success 或 Accent 表达判断。来源 Chip 用符号区分当前、已更新、已删除和未发送四种状态，后两种不可点。提问框使用 `TextEditor` 加 `.kinlogueInputFrame()`：Return 换行，Command-Return 发送，输入法还有未上屏文字时不发送。等待回答时显示已等待的秒数和“停止”。错误和停止统一用 `KinlogueStatusLabel`，停止和需要重新确认用 Warning，其余用 Danger。设置页“AI 对话（实验）”Card 的开关放在统一的右侧控制列，状态和字段用 Grid 对齐；代理地址不接受用户名或密码，因为设置以明文保存。实现与门禁见 [`AssistantPanelView`](../Sources/KinlogueApp/Views/AssistantPanelView.swift)、[`AssistantConsentSheet`](../Sources/KinlogueApp/Views/AssistantConsentSheet.swift)、[`AssistantSettingsSection`](../Sources/KinlogueApp/Views/AssistantSettingsSection.swift) 和 [`AssistantViewSafetyTests`](../Tests/KinlogueAppTests/AssistantViewSafetyTests.swift)。中英文和窄宽度布局只用合成数据做过离屏渲染核对；真实窗口中的焦点、输入法、VoiceOver 朗读和 Command-Return 仍属于人工矩阵。

第 20–25 条的自动化只覆盖模型行为、宿主窗口中的 Command-Return 键等价和源码结构；实际窗口中的焦点、输入法、VoiceOver 朗读和窄侧边栏下的换行仍属于人工矩阵。

## 组件映射

| 产品界面 | 使用方式 |
| --- | --- |
| App、时间线、收件箱主背景 | Surface |
| 窗口标题栏与工具栏背景 | Surface；控件保留 macOS 系统外观；纯图标操作提供本地化原生悬停帮助 |
| 侧边栏大背景 | Surface；选中 Tab 使用 Selection |
| 时间线类型筛选 | 可点选的 Selected / Neutral 功能标签，带悬停与按下状态；当前项带对勾；仅在存在已确认医学影像时显示 |
| 手机上传待确认行 | 常规 Surface；选中 Selection；正文 On Surface、辅助信息 On Variant、操作使用 Primary/Danger 图标按钮 |
| 收件箱底部操作区 | Container |
| 所有 sheet 画布 | Surface；页眉、表单和页脚不再分色 |
| 取消、关闭与普通操作 | Secondary Button（工具栏、系统确认框和 DICOM Viewer 控制条除外） |
| 行内图标与紧凑文字操作 | Ghost Button |
| 设置中的本机数据管理 | 导出与删除使用独立普通 Card + Outline；右侧控件固定 intrinsic 尺寸后使用同宽右对齐列，操作的右边缘与卡片右内边距一致。导出使用次要按钮，删除使用破坏性按钮；主工具栏不提供这两个整库入口 |
| 原始文件导出 sheet | 600×480 固定工作区；warning/checking/choosing/exporting/cancelling/cancelled/empty/failed/succeeded 语义状态。进度只显示聚合计数与大小，不显示敏感路径；active/commit 阶段禁止交互式关闭 |
| 详情信息块、搜索框 | Container + Outline |
| 已确认记录多行编辑器 | 原生 `NSTextView`；文本容器 8pt 内容边距；Card + Outline；三个多行字段保持一致 |
| 内嵌原件预览 | 报告详情、导入确认、已确认记录编辑、报告对比和手机上传页序统一按预览区宽度等比显示；超出区域可独立滚动；工具栏提供 60%–240% 缩放，图片额外提供左右 90° 旋转；旋转只属于当前查看状态，不修改原件、来源顺序或 OCR；只有宿主提供独立查看器时才显示“查看原图”入口。图片解码与 PDF 文档打开、所选页元数据读取、当前页栅格化都在各自的串行 actor 中完成；PDF open 只发布页数，不预扫全部页面。主线程只发布不可变图像；页码或渲染尺寸变化会取消旧请求并拒绝晚到结果。 |
| DICOM Viewer 窗口 | 从确认页或时间线的检查详情统一打开标准 macOS 独立窗口；保留原生关闭、最小化、缩放/全屏控件和拖边调整大小，不使用无标题栏的 sheet 承载 Viewer |
| DICOM Series 选择 | Viewer 在所有窗口宽度使用原生菜单式 Picker；选项显示序列序号和切片数，切换后由现有加载状态反馈结果；前后序列按钮只作为相邻导航快捷入口，不另设宽窗口侧栏列表 |
| “从手机接收资料”弹窗及安全说明卡 | Surface 画布；说明卡与二维码使用 Card + Outline |
| 保存、比较、开始接收、确认归档 | Primary Button |
| 时间线记录与医学影像检查 | Interactive Card |
| 成员、来源等标签 | Neutral Chip |
| 时间轴和成功/可归档状态 | Primary |
| 警告和关键提醒 | 短标签使用 Warning；整句使用 Warning Container + Accent 描边的横幅，并配合图标 |
| 错误 | Danger 状态标签，带 `exclamationmark.octagon` |
| 删除、放弃、停止与整库替换 | 破坏性按钮；系统确认框内保留原生 destructive |

## 使用约束

- 不在页面文件中新增品牌色 RGB、十六进制常量或同义颜色。
- 页面文件不使用系统 `.secondary` / `.tertiary` 文字色、系统 `.red` / `.orange` / `.green`、`.borderless` 按钮样式、`Color(nsColor:)`、`regularMaterial` 或圆角数值；辅助说明使用 On Variant，装饰性箭头使用 On Variant Subtle。`KinlogueThemeSourceTests` 对整个 `Views` 目录执行这条门禁。
- Accent 不用于长段正文，也不与白字组合显示小号文本。
- 不把所有按钮都改成 Primary；一个操作区域通常只有一个明显主操作。
- 不给静态容器添加 hover、阴影提升或缩放。
- 阴影只用于表达层级或交互，不用于装饰大面积背景。

## 验证清单

视觉变更提交前至少检查：

- 主按钮、次要按钮、破坏性按钮和图标按钮的普通、悬停、按下、禁用状态。
- 列表行的悬停、按下、选中和键盘焦点状态；选中必须明显重于悬停。
- 每个 sheet 与 DICOM Viewer 窗口在系统深色模式下仍为亮色画布，开关、进度条和图标按钮使用 Primary 而不是系统蓝。
- 键盘 Tab 导航、默认按钮和 Escape 取消。
- VoiceOver 名称、值与提示仍可理解。
- 开启“减少动态效果”后没有缩放动画。
- 开启“提高对比度”后边界和辅助文字清晰。
- 标题栏与主画布保持暖色连续，不出现系统白色工具栏断层，原生窗口控件仍正常。
- 窄窗口下主按钮不会压缩标签或挤出操作区。
- 竖版图片和 PDF 默认占满原件预览宽度；图片旋转后按新的横竖方向重新计算适配尺寸，左右旋转、缩放、双向滚动和“查看原图”入口互不遮挡；PDF 保持原始页面方向。
- PDF 预览打开时不遍历全部页面，只按当前 `(sessionID, pageIndex)` 读取并缓存有限页 metadata；当前页栅格化最长边不超过 4,000 px、页缩放不超过 5 倍。`PDFDocument`、`PDFPage` 和 PDFKit 生成的 `NSImage` 不进入 SwiftUI/MainActor 状态，切页或连续缩放的旧任务即使完成也不能覆盖当前页，无效页显示既有 unavailable 状态。
- 手机上传页在窄屏和桌面浏览器下均无横向滚动。

## macOS 27 控件验收

编辑器布局回归保留现有 SwiftUI key-view proxy 观测方式，检查所有观测控件的非空 frame 和完整可见性；最低数量覆盖取消、保存和手动日期操作，不再假定系统内部控件总数固定。该实现细节观测不替代真实键盘和 VoiceOver 验收。逐字转录编辑器的系统写作工具限制见 [`import-and-ocr.md`](import-and-ocr.md)。系统 Picker、菜单、工具栏的外观沿用原生行为；本轮不重做色板或 Liquid Glass。macOS 26/27 上的键盘、VoiceOver、提高对比度和窄窗口实际交互仍属于人工矩阵。
