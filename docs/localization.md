# macOS App 本地化

## 当前语言契约

Kinlogue macOS App 当前只支持简体中文 `zh-Hans` 和英文 `en`。简体中文是 source/development localization。首次运行和“跟随系统”模式使用 macOS 为 App 解析的 preferred localization；用户也可以从侧栏“设置”即时选择简体中文或 English，选择通过 `@AppStorage` 保存在当前 Mac 用户的 App 偏好中。不匹配或损坏的偏好回退到“跟随系统”，系统 locale 不匹配时回退到简体中文。

这个契约只覆盖 Mac App 界面和 `Info.plist` 系统文案。局域网上传的手机浏览器页面仍是独立中文资源；加入它需要另外设计 HTTP `Accept-Language`、会话语言和前端资源测试，不能由 Mac 当前 locale 隐式决定。

## 资源与运行时设计

| 层 | 位置 | 责任 |
| --- | --- | --- |
| 翻译源 | `Sources/KinlogueApp/Localization/Localizable.xcstrings` | 简体中文 source keys、英文翻译、类型化插值和复数 variation。 |
| 运行时资源 | `Sources/KinlogueApp/Resources/{zh-Hans,en}.lproj/` | SwiftPM 可打包的已编译 strings/stringsdict，以及 `InfoPlist.strings`。 |
| 运行时解析 | `Sources/KinlogueApp/App/AppLocalization.swift` | 定义持久化语言选择，显式选择优先于 main bundle 的 preferred localization；同一选择生成 SwiftUI locale 与语言化 Gregorian calendar；正式 `.app` 只读取 main bundle，SwiftPM 开发和测试目标才使用 `Bundle.module`。 |
| 原生日期控件 | `Sources/KinlogueApp/Views/LocalizedDatePicker.swift` | macOS 紧凑型 SwiftUI `DatePicker` 和 `NSDatePicker.presentsCalendarOverlay` 的系统私有弹层不会可靠采用 App locale。共享控件改用 App 自己管理的 SwiftUI popover，在其中嵌入 `.clockAndCalendar` `NSDatePicker`，显式设置所选 `AppLanguage` 的 locale、Gregorian calendar、时区、启用态和无障碍标签，并把原生选择回写 SwiftUI binding。 |
| 设置界面 | `Sources/KinlogueApp/Views/SettingsView.swift`、`MemberSidebarView.swift` | 侧栏固定设置入口、Warm Sanctuary 语言与本机数据管理卡片和即时语言切换；资料浏览继续使用原三栏导航。 |
| 发布组装 | `scripts/build-app.sh`、`scripts/verify-app.sh` | 把 App target 的 `.lproj` 复制到 `.app/Contents/Resources`，并校验只存在中英资源和对应用途说明。 |

SwiftPM 命令行构建不会在当前工具链中自动把 `.xcstrings` 转成可直接运行的 `.strings`。因此 catalog 放在不参与 SwiftPM resource processing 的 `Localization/`，提交由 `xcstringstool` 生成的英文 `.strings`/`.stringsdict`；`scripts/compile-localizations.sh --check` 防止生成物漂移。简体中文直接使用 catalog 的 source value，`zh-Hans.lproj/Localizable.strings` 只负责声明运行时 localization。

发布脚本会把两个 `.lproj` 复制到 `.app/Contents/Resources`，不会保留 SwiftPM 生成的 App target resource bundle。SwiftPM 的 `Bundle.module` accessor 在找不到该 bundle 时会直接终止进程，因此正式 `.app` 的运行时分支不得求值 `Bundle.module`；对应测试验证这个 fallback 保持惰性，最终发布包仍需实际启动验证。

## 编码规则

- `Sources/KinlogueApp` 中新的用户可见文案必须使用 `AppLocalization.string("中文 source value")`。范围不仅包括 `Text`、`Label`、`Button` 和窗口标题，也包括空状态、确认框、错误提示以及 `accessibilityLabel` / `accessibilityHint`；ViewModel 中最终展示给用户的错误字符串遵循同一规则。
- 长生命周期的 ViewModel 不保存已经翻译完成的 `String` 作为错误或状态；保存语义 case/key，在 View 重绘或属性读取时按当前 `AppLanguage` 解析，避免切换语言后残留旧语言。
- VoiceOver announcement 同样属于用户可见状态：保存带参数的语义 case，而不是触发时已经本地化的字符串。比较选择的计数、达到上限、原件加载结果和关闭通知都在属性读取时按当前语言解析；自动化必须覆盖错误与 announcement 在语言切换后同步变化。
- 动态值直接放进 `AppLocalization.string` 的类型化插值，不先拼接句子片段。文件名、成员名、局域网地址等内容数据保持原值，只本地化包裹它们的句子骨架。
- App 级语言偏好只能使用 `AppLanguage` 的 `.system`、`.simplifiedChinese`、`.english`；不要直接写入任意 locale，避免声明语言与运行时资源不一致。
- 需要单复数变化时在 String Catalog 中使用 variation，不在 Swift 中用 `count == 1` 拼英文句子；运行时断言同时覆盖 `count == 1` 和复数边界。
- 应用显示名、权限用途说明等系统读取的字段写入每种语言的 `InfoPlist.strings`。
- 日期、数字和文件大小继续交给 Foundation formatter；不要把格式化结果硬编码成某个语言的顺序。App 根视图继续注入 `AppLocalization.locale(for:)` 与 `AppLocalization.calendar(for:)`，但 sheet/popover 内的用户可见日期不得依赖 SwiftUI locale 一定被继承；`ReportDateSemantics` 和生产日期输入直接从当前 `AppLanguage` 解析 locale。生产日期输入必须使用 `LocalizedDatePicker`，不得直接使用 SwiftUI `DatePicker` 或 `NSDatePicker.presentsCalendarOverlay`；共享控件在 App 自己的 popover 内嵌入 `.clockAndCalendar` 原生控件，保留本机时区、每周起始日和首周规则，使月份与星期符号按 App 语言显示。
- OCR heading/keyword、原报告文字、家庭成员姓名、文件名和用户备注是内容数据，不翻译。LAN display name 只经过安全清洗；无法保留有效名称时使用语言无关的 `_`，不能把本地化后的占位名写回领域模型或持久化数据。
- 整库销毁的输入确认 token 跟随当前 App 显示语言：中文为“彻底删除”，英文为“Permanently Delete”。删除弹窗必须展示当前 token，并只接受与该展示值完全一致的输入；切换语言后不得继续接受另一语言的 token。
- 翻译不能新增诊断、趋势或建议，也不能弱化明文存储和普通 HTTP 的用户提示。

### 重构与合并门禁

- 新增、重命名或替换 `View` / `ViewModel` 后，必须重新扫描整个 `Sources/KinlogueApp`，不能假设旧 catalog 自动覆盖新代码。特别检查状态枚举、错误分支、空状态、确认框和无障碍文案。
- `LocalizationPackagingTests.appSwiftSourcesDoNotIntroduceBareChineseUserFacingLiterals` 是硬门禁：App Swift 源码中的中文字符和中文标点字符串必须在同一表达式中经过 `AppLocalization.string`。扫描按字符串字面量而不是整行判断，并覆盖普通、raw、多行和同一行混合字符串。当前唯一例外是设置菜单中精确匹配的自称语言标签“简体中文”；新增例外必须说明它为何是不可翻译的内容数据，并同步测试 allow-list。该自动门禁不尝试从任意英文技术字符串中推断 UI 语义，新增英文裸文案仍由代码评审和中英运行时断言阻止。
- 重构删除旧界面或领域术语时，同时搜索并移除只服务于旧代码的 catalog key 和本地化专项测试，避免旧翻译掩盖新流程尚未覆盖的问题。
- 新增带插值、复数或参数重排的文案时，至少增加一个中英文运行时断言；测试必须证明参数类型、顺序和用户数据在英文环境下仍正确。
- 合并主干后若 `Sources/KinlogueApp` 有新增或大范围改名，即使没有本地化文件冲突，也必须按本节重新执行扫描和验证。

## 修改与验证流程

1. 先运行 `rg -n '\p{Han}' Sources/KinlogueApp --glob '*.swift'` 盘点受影响文案，再在 Swift 中添加中文 source value，并在 `Localizable.xcstrings` 填写英文翻译和必要的 variation。
2. 对静态文案确认硬编码扫描测试可发现遗漏；对带插值、复数或参数重排的文案增加中英文运行时测试。
3. 运行 `scripts/compile-localizations.sh --write` 更新提交的英文运行时资源，再运行 `scripts/compile-localizations.sh --check` 防止 catalog 与生成物漂移。
4. 运行 `swift test --disable-sandbox --filter AppLocalizationTests`、`swift test --disable-sandbox --filter LocalizationPackagingTests` 和 `swift test --disable-sandbox --filter LocalizedDatePickerTests`。catalog 测试会拒绝缺失/空英文或出现第三种 locale；运行时测试覆盖静态文案、类型化插值、复数、持久化选择、显式覆盖、系统选择和 fallback；日期控件测试直接检查底层 `NSDatePicker` 的 locale/calendar、`.clockAndCalendar` 样式、私有 overlay 保持关闭、binding 回写，以及生产日期输入和展示入口不回退到 SwiftUI/系统 locale。
5. 运行 `scripts/test.sh`；发布候选再运行 `scripts/verify-app.sh`，确认最终 bundle 的语言声明、资源 allow-list、应用名和局域网用途说明。
6. 人工在设置页依次选择“跟随系统 / 简体中文 / English”，检查当前窗口、菜单、窗口标题、日期选择器弹窗的月份与星期、新增/重构页面、窄窗口布局、截断、键盘焦点和 VoiceOver，并重启确认选择保留。当前自动化不替代这一步。

采用依据见 [`sources/apple-localization-guidance-2026-08-05.md`](sources/apple-localization-guidance-2026-08-05.md)。
