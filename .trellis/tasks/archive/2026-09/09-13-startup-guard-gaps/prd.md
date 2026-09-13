# 修复启动前哨窗口与死代码清理项

## Goal

处理 `.trellis/spec/runtime/index.md` 中记录的两个已确认缺口。两者都在产品源码内，
需要修改 `src/`、重新生成 `sb.sh`，并可能同步 `tests/` 中的钉死断言。

## Scope

- 目标源码：`src/90-main.sh`、`src/80-lifecycle.sh`、`src/85-repair.sh`
- 受影响测试：`tests/repair.sh`（临时文件清单）、`tests/verify.sh`（生命周期字符串钉死）
- **不在范围内**：重写 ACME 恢复点判定逻辑；改动 `with_acme_lock` 语义；
  处理 `resolve_orphaned_acme_state_backup` 菜单本身的产品行为（除非用户选择该方案）

---

## 缺口 2：`.sb.json.rollback.*` 死条目

### 证据

| 事实 | 来源 |
|---|---|
| 该字符串由 `d101c6d Release v1.9.0 with transactional repair` 引入 | `git log --all -S'.sb.json.rollback'` 仅命中该提交 |
| 该提交**同时**引入了清理清单本身 | 同上 |
| `src/` 内无任何生产者写入该前缀 | `grep -rn 'sb\.json\.rollback' src/` 仅命中清理清单一行 |
| 全部历史修订中它只出现在清理清单里 | 对每个修订 `git grep` 的结果一致 |
| 测试端有一份手工重复的清单 | `tests/repair.sh:414-416` |

**结论**：它不是旧版本遗留的清理项（从未有过生产者），是一条从引入起就未接线的死条目。
它会让后续读者误以为存在对应的事务回滚临时文件。

### 建议修法

从 `src/85-repair.sh:439` 的清理 glob 中删除该前缀，并同步删除
`tests/repair.sh:415` 中的对应模式。

清理 glob 是 `rm -rf` 陈旧临时文件，删掉一个无生产者的模式不会影响任何现有行为。

---

## 缺口 1：`prepare_runtime_state` 的启动前哨窗口

### 现状

```
src/90-main.sh（当前顺序）
# sb-entrypoint
prepare_runtime_state || exit 1             ← 198 行：先做前置工作
handle_install_interrupt(){ ... }           ← 200-229 行
trap handle_install_interrupt INT TERM HUP  ← 230 行：后装陷阱
```

`prepare_runtime_state`（`src/80-lifecycle.sh:297-310`）做两件会改动系统的事：

1. `prepare_managed_directory` → `write_managed_marker`：`mkdir -p /etc/sb`，随后写
   `/etc/sb/.sb-managed` 标记。
2. 若存在 ACME 恢复点候选：`with_acme_lock resolve_orphaned_acme_state_backup`
   —— 一个交互菜单，选项 1 会调用 `restore_acme_state_backup 1` 并可能重启服务。

### 深入分析后的修正：这里有**两个**独立风险，而不是一个

**风险 A — 撕裂的受管目录导致自锁**

`write_managed_marker_at`（`src/40-service.sh:52-63`）先 `mkdir -p "$directory"`，再写标记。
若在两者之间被中断（Ctrl-C、OOM、断电），`/etc/sb` 已存在但无标记，于是
`prepare_managed_directory` 走到：

```bash
# src/40-service.sh:82-84
  else
    red "检测到不属于本脚本的 $SB_DIR，拒绝覆盖"
    return 1
```

**下一次运行会拒绝继续，并给出误导性提示**（目录其实是本脚本刚创建的）。
`install_singbox` 与修复流程同样被挡住，用户必须手工删除目录才能恢复。

关键在于：**这条风险与中断陷阱无关**。即使提前安装陷阱，处理器所有事务标志均为 0，
对「目录已建、标记未写」没有任何清理动作。断电或 OOM 同样能触发。

**风险 B — ACME 恢复点流程中途中止**

`find_orphaned_acme_state_backup` 会设置 `ACME_STATE_BACKUP`（`src/10-acme.sh:988`），
随后菜单在用户选择前一直保持该值。此窗口内中断：

- 选择菜单时中断 → 事务处理器第三分支会**自动恢复该恢复点并删除它**。
- 当前行为（无陷阱）反而是：脚本直接终止，**恢复点保留**，用户下次运行可重新决定。

因此「简单地把陷阱提前」不是严格改进，而是**改变产品语义**：它会在用户明确拒绝决策时，
替用户做出「恢复并消耗恢复点」的决定。若该恢复点来自一次已完成但未清理的操作，
这会回退到更旧的证书状态。

### 需要用户决策的点

风险 A 的修法无副作用，可直接实施。风险 B 的三种取向见 implement.md「待决」章节，
差别是产品行为而非实现质量，需确认后实施。

---

## Acceptance Criteria

- [x] 清理清单与其测试副本中不再出现无生产者的 `.sb.json.rollback.*`
- [x] 撕裂的受管目录不再导致下一次运行拒绝继续
- [x] 按选定方案（C）处理启动前哨窗口的中断语义
- [x] `bash scripts/build.sh && bash tests/verify.sh` 通过（54 项，原 52 + 新增 2）
- [x] `.trellis/spec/runtime/index.md` 的「已知缺口」章节改为「已解决缺口」
- [x] 新增行为有回归测试，且两个新用例均已验证在改动前的代码上会失败

## Outcome

全部完成。改动 6 个文件（5 个 src 模块 + tests/repair.sh），
`sb.sh` 重新生成（哈希 `e3e9b50e…`），提交 `24f6748`。

实施中发现并一并修复了原记录之外的问题：纯布尔「操作进行中」标志会被
`src/70-management.sh` 的三处恢复点移交路径永久卡住，因此改用按路径归属判定
（`ACME_INFLIGHT_BACKUP`）。

另因源码行号偏移，重新校验并修正了 32 处 spec 引用。

## Rules

- 只改 `src/`，不直接编辑 `sb.sh`；提交前必须 `scripts/build.sh` 重新生成。
- 遵守 `spec/runtime/atomic-writes.md`：任何替换走 candidate → 校验 → `mv -fT`。
- 遵守 `spec/shell/bash-conventions.md`：无 `set -e`，显式 `|| return 1`。
- 若某处被 `tests/verify.sh` 钉死，同步更新钉死值与测试。
