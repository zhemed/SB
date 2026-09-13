# 实施计划

## 决策记录

- 缺口 1 采用**方案 C**：陷阱提前安装 + 新增「归属本次操作」判定，不改变
  「发现的孤儿恢复点」处的中断语义。
- 风险 A 一并修复：识别并接管被中断撕裂的受管目录。
- 缺口 2：删除无生产者的死条目。

## 关键设计修正：为什么不用纯布尔标志

`src/70-management.sh:276-277`、`339-340`、`383-384` 三处会**故意**把
`ACME_STATE_BACKUP` 移交到局部变量后清空全局，同时**保留**恢复点（因为当前配置可能仍引用它）。
若用布尔标志「`begin_acme_state_backup` 置 1 / `clear_acme_state_backup` 清 0」，
这五条不调用 `clear_acme_state_backup` 的路径会让标志永久卡在 1，
之后任意中断都会打印「证书操作已中断…」并进入不该走的恢复分支。

**改用按路径归属判定**，只需一个赋值点、零清理点：

```bash
ACME_INFLIGHT_BACKUP=            # 本次操作自己创建的恢复点路径
```

- 只在 `begin_acme_state_backup` 末尾与 `ACME_STATE_BACKUP=$backup` 一起赋值。
- 处理器条件改为「两个变量都存在且相等」：

```bash
elif [[ -n ${ACME_STATE_BACKUP:-} &&
        ${ACME_INFLIGHT_BACKUP:-} == "${ACME_STATE_BACKUP:-}" ]]; then
```

- 移交路径清空 `ACME_STATE_BACKUP` → 条件为假 ✓ 不会卡住
- 启动时发现的孤儿只设 `ACME_STATE_BACKUP`、不设 `ACME_INFLIGHT_BACKUP` → 条件为假 ✓
- 进行中的操作两值相同 → 条件为真 ✓ 保持现有回滚行为
- 无跨运行碰撞风险：`.acme-backup.XXXXXX` 由 `mktemp` 生成随机名，且发现阶段先于任何新操作

---

## 变更清单

### 1. `src/85-repair.sh` — 删除死条目

`cleanup_repair_temporary_files` 的 glob 列表去掉 `"$SB_DIR"/.sb.json.rollback.*`。

### 2. `tests/repair.sh` — 同步清单

中断测试的禁止模式列表（414-416 行）去掉 `.sb.json.rollback.*`。

### 3. `src/40-service.sh` — 撕裂目录接管

新增谓词（放在 `managed_directory_is_owned` 之后）：

```bash
managed_directory_is_incomplete_creation(){
  local entry name
  [[ -d $SB_DIR && ! -L $SB_DIR ]] || return 1
  managed_directory_is_owned && return 1
  [[ ! -e $SB_MANAGED_MARKER && ! -L $SB_MANAGED_MARKER ]] || return 1
  for entry in "$SB_DIR"/* "$SB_DIR"/.[!.]* "$SB_DIR"/..?*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    [[ $name == .sb-managed.* ]] || return 1
  done
}
```

`prepare_managed_directory` 增加分支：

```bash
  elif managed_directory_is_incomplete_creation; then
    yellow "检测到上次运行中断留下的空 $SB_DIR，按本脚本目录接管"
    write_managed_marker
```

**判定边界（重要）**：只接管「空目录」或「仅含 `.sb-managed.*` 临时文件」的目录；
**已存在 `.sb-managed` 但校验不通过的一律仍然拒绝**——那意味着标记被破坏或属于他人。
`mv -fT` 是原子的，所以 `mkdir` 与写标记之间被撕裂的状态只可能是这两种。

### 4. `src/00-bootstrap.sh` — 新全局

在 ACME 状态组内增加 `ACME_INFLIGHT_BACKUP=`（紧邻 `ACME_STATE_BACKUP=`）。

### 5. `src/10-acme.sh` — 赋值点

`begin_acme_state_backup` 末行改为：

```bash
  ACME_STATE_BACKUP=$backup
  ACME_INFLIGHT_BACKUP=$backup
```

### 6. `src/90-main.sh` — 陷阱提前 + 处理器条件

顺序改为：`# sb-entrypoint` → 定义 `handle_install_interrupt` → 安装 trap →
`prepare_runtime_state || exit 1` → `is_installed` 自检块 → `menu`。

处理器第三分支条件由 `[[ -n ${ACME_STATE_BACKUP:-} ]]` 改为上述双变量判定。

### 7. 规范同步

- `runtime/index.md`：删除「已知缺口」两条，改为记录修复后的实际状态
- `runtime/managed-assets.md`：登记新谓词
- `runtime/certificates.md`：记录 `ACME_INFLIGHT_BACKUP` 语义
- `runtime/transactions.md`：更新陷阱顺序描述（原文档明确写了 198 在 230 之前）

---

## 验证

```bash
bash scripts/build.sh
bash tests/verify.sh      # 必须 52 项全过
```

新增回归：

| 用例 | 断言 |
|---|---|
| 空 `/etc/sb` 被接管 | 写入标记且返回成功 |
| 仅含 `.sb-managed.*` 的 `/etc/sb` 被接管 | 同上 |
| 含外来文件的 `/etc/sb` 仍被拒绝 | 返回非 0，且目录内容未改动 |
| 含无效 `.sb-managed` 的 `/etc/sb` 仍被拒绝 | 同上 |
| 处理器不恢复「发现的孤儿」 | `ACME_STATE_BACKUP` 已设、`ACME_INFLIGHT_BACKUP` 未设 → 恢复点原样保留 |
| 处理器恢复「进行中的操作」 | 两个变量相等 → 恢复点被消费 |

## 回滚点

改动全部落在 `src/`，`sb.sh` 由构建器重新生成。任何一步失败可
`git checkout -- src/ && bash scripts/build.sh` 回到当前可用状态。
