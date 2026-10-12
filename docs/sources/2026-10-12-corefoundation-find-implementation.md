# Core Foundation 子串查找实现核对（2026-10-12）

本页保存搜索预筛键设计时查阅的开源实现，补充 [API 契约核对](2026-10-11-apple-search-semantics.md)。它不是 Apple 发布二进制的行为证明。

## 来源与读取方式

- swift-corelibs-foundation 的 [`Sources/CoreFoundation/CFString.c`](https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/main/Sources/CoreFoundation/CFString.c)，`main` 分支，2026-10-12 读取。
- 读取方式是按字符偏移分段抓取并由工具摘要回答指定问题，不是对整份文件的逐行通读。`CFStringFindWithOptionsAndLocale` 位于原始文件第 150,000–250,000 字符之间；它调用的 `__CFStringFoldCharacterClusterAtIndex` 函数体没有读到。

## 来源陈述的事实

- 查找路径没有使用排序规则：`_CFCompareStringsWithLocale` 与 ICU 只出现在比较函数里。`kCFCompareLocalized` 在查找中只影响语言代码的取得。
- 传入 locale 时，语言代码取自 `_CFStrGetSpecialCaseHandlingLanguageIdentifierForLocale`。ASCII 字母直接转小写；语言代码存在时字母 I 不走这条捷径，交给折叠函数处理。
- 非 ASCII 字符经 `__CFStringFoldCharacterClusterAtIndex` 按字符簇折叠后比较。折叠结果长度可以不同，大小写不敏感时允许匹配跨越不同长度。
- 带 `kCFCompareNonliteral` 时，候选匹配之后如果紧跟非基字符，该匹配被拒绝。
- 被跳过的字符只来自按选项构造的忽略集合和变音符不敏感模式；查找逻辑中没有对零宽连接符或变体选择符的单独跳过。

## 对项目的约束

这些事实只解释 [预筛键](../../Sources/KinloguePlatform/Storage/SQLiteReportSearchKey.swift) 为什么这样构造：规范等价加大小写折叠决定两个字符簇是否相等，所以键对每个标量做兼容分解和逐标量的大写再小写映射，只保留字母与数字。键不漏结果的保证不由本页证明，而由 [`SQLiteReportSearchKeyTests`](../../Tests/KinloguePlatformTests/SQLiteReportSearchKeyTests.swift) 在运行系统上对照真实 Foundation 搜索检查；是否命中仍只由 Foundation 谓词决定。
