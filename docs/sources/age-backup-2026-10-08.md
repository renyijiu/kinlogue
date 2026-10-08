# age v1.3.2 备份加密来源记录

2026-10-08 核对上游固定 tag；本页记录外部来源，不把库的性质当作 Kinlogue 已通过的验证。项目取舍见[Go 手动备份恢复计划](../plans/2026-10-08-1702-feat-go-backup-restore-plan.md)，当前能力见[Go 专题](../go-native-preview.md)。

| 来源 | 核对事实 |
| --- | --- |
| [v1.3.2 release](https://github.com/FiloSottile/age/releases/tag/v1.3.2) | 2026-08-29 发布的固定版本；不是浮动 main 依赖。 |
| [go.mod](https://github.com/FiloSottile/age/blob/v1.3.2/go.mod) | 最低 Go 1.25，toolchain 1.27.0；与本项目 1.27.1 的版本要求相容，实际构建另行验证。 |
| [BSD-3-Clause LICENSE](https://github.com/FiloSottile/age/blob/v1.3.2/LICENSE) | 发布包需保留许可；实际链接的传递依赖也按现有脚本收集。 |
| [公共 API](https://github.com/FiloSottile/age/blob/v1.3.2/age.go)、[HybridIdentity](https://github.com/FiloSottile/age/blob/v1.3.2/pq.go) | 提供流式加解密、生成/解析身份；上游推荐新使用者选择 MLKEM768-X25519 混合身份，私钥由随机 seed 编码。 |
| [stream 实现](https://github.com/FiloSottile/age/blob/v1.3.2/internal/stream/stream.go)、[age v1.1.0 规范](https://c2sp.org/age@v1.1.0) | payload 分块认证并包含最终块语义；必须检查加密 Close，并消费解密到真正 EOF 才验证完整性。上层归档 EOF 不能替代密文尾部验证。 |
| [认证说明](https://words.filippo.io/age-authentication/) | 接收者加密不证明发送者身份；持有公钥者也能创建新密文，不能宣传为签名或防回滚。 |

备份内容、恢复码保存/确认、解析上限、文件发布、恢复事务和错误行为由应用负责验证；库本身不保证这些流程，也不保证 Go 字符串的内存安全擦除。
