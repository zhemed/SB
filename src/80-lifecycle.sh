# sb-module: 80-lifecycle
# Remove an incomplete installation only after its directory ownership has
# been proved. Service and cron cleanup must succeed before data is deleted.
running_from_managed_shortcut(){
  local source_path shortcut_path
  shortcut_is_owned || return 1
  [[ -f $0 && ! -L $0 ]] || return 1
  source_path=$(readlink -f "$0" 2>/dev/null) || return 1
  shortcut_path=$(readlink -f "$SHORTCUT" 2>/dev/null) || return 1
  [[ $source_path == "$shortcut_path" ]]
}

lifecycle_acme_state_exists(){
  local lock compat_lock path
  lock=$(acme_lock_path) || return 0
  compat_lock=$(acme_compat_lock_path) || return 0
  for path in "$lock" "$compat_lock" "${ACME_HOME:-$SB_DIR/acme}" \
    "${ACME_CERT:-$SB_DIR/acme-cert.pem}" "${ACME_KEY:-$SB_DIR/acme-private.key}" \
    "${ACME_IDENTITY:-$SB_DIR/acme_server_name}" "${ACME_RELOAD:-$SB_DIR/acme_reload.sh}" \
    "${ACME_LIVE:-$SB_DIR/acme-live}"; do
    [[ ! -e $path && ! -L $path ]] || return 0
  done
  acme_renew_artifacts_exist
}

with_lifecycle_acme_lock(){
  if [[ ${ACME_LOCK_HELD:-0} -eq 1 ]]; then
    with_acme_lock "$@"
    return
  fi
  if [[ ! -e $SB_DIR && ! -L $SB_DIR ]]; then
    "$@"
    return
  fi
  if command -v flock >/dev/null 2>&1; then
    with_acme_lock "$@"
    return
  fi
  if lifecycle_acme_state_exists; then
    red "检测到 ACME 续期状态，但系统缺少 flock，拒绝在无法防止并发续期时清理"
    return 1
  fi
  "$@"
}

cleanup_incomplete_install_locked(){
  local cleanup_failed=0

  if ! cleanup_service; then
    red "停止或移除 sb 服务失败，已保留安装残留以避免误删"
    return 1
  fi
  if command -v crontab >/dev/null 2>&1 && ! remove_all_managed_crons; then
    red "清理 sb 定时任务失败，已保留安装残留以避免误删"
    return 1
  fi

  if managed_directory_is_owned; then
    if ! rm -rf -- "$SB_DIR"; then
      red "删除 $SB_DIR 失败，请检查文件系统权限"
      cleanup_failed=1
    fi
  fi

  if shortcut_is_owned; then
    if running_from_managed_shortcut; then
      yellow "当前正通过 $SHORTCUT 运行，已保留该快捷命令用于继续修复"
    elif ! rm -f -- "$SHORTCUT"; then
      red "删除快捷方式 $SHORTCUT 失败"
      cleanup_failed=1
    fi
  elif [[ -e $SHORTCUT || -L $SHORTCUT ]]; then
    yellow "检测到非本脚本管理的 $SHORTCUT，已保留"
  fi

  return "$cleanup_failed"
}

cleanup_incomplete_install(){
  if service_name_conflict; then
    red "检测到不属于本脚本的同名 $SB_SERVICE 服务，拒绝清理安装残留"
    return 1
  fi
  if [[ -e $SB_DIR || -L $SB_DIR ]] && ! managed_directory_is_owned; then
    red "无法确认 $SB_DIR 属于本脚本，已保留该目录"
    return 1
  fi
  with_lifecycle_acme_lock cleanup_incomplete_install_locked
}

cleanup_install_transaction(){
  [[ ${INSTALL_TRANSACTION_ACTIVE:-0} -eq 1 ]] || return 0
  INSTALL_TRANSACTION_ACTIVE=0
  cleanup_incomplete_install
}

abort_install_transaction(){
  red "安装未完成，正在清理本次安装产生的文件和服务……"
  if cleanup_install_transaction; then
    green "本次安装残留已清理"
  else
    red "自动清理未完整完成，请检查上方错误后再使用菜单[2]修复"
  fi
  return 1
}

uninstall_locked(){
  if ! cleanup_service; then
    red "停止或移除sb服务失败，卸载已中止；配置与定时任务均保留"
    return 1
  fi
  if ! remove_all_managed_crons; then
    red "服务已停止，但清理sb定时任务失败；配置文件仍保留，可通过菜单[2]修复"
    return 1
  fi
  if ! rm -rf "$SB_DIR"; then
    red "删除sb文件失败，请检查文件系统权限"
    return 1
  fi
  if shortcut_is_owned; then
    if ! rm -f "$SHORTCUT"; then
      red "删除快捷方式 $SHORTCUT 失败，请检查文件系统权限"
      return 1
    fi
  elif [[ -e $SHORTCUT || -L $SHORTCUT ]]; then
    yellow "检测到非本脚本管理的 $SHORTCUT，已保留"
  fi
}

# Uninstall
uninstall(){
  local menu
  if service_name_conflict; then
    red "检测到不属于本脚本的同名 $SB_SERVICE 服务，拒绝执行卸载"
    return 1
  fi
  if [[ -e $SB_DIR || -L $SB_DIR ]] && ! managed_directory_is_owned; then
    red "无法确认 $SB_DIR 属于本脚本，拒绝执行卸载"
    return 1
  fi
  red "确认卸载sb? sb的配置和数据将被删除!"
  yellow "1：确认卸载"
  yellow "0：取消"
  readp "请选择【0-1】：" menu
  if [[ $menu == 1 ]]; then
    with_lifecycle_acme_lock uninstall_locked || return 1
    green "sb卸载完成！"
    echo
    exit 0
  fi
}
cronsb(){
  local current filtered entry
  if ! cron_daemon_is_active; then
    red "cron/crond 服务未运行，拒绝写入无法执行的每日重启任务"
    return 1
  fi
  load_current_crontab || return 1
  current=$CURRENT_CRONTAB
  filtered=$(printf '%s\n' "$current" | filter_restart_cron_entries || true)
  if command -v apk >/dev/null 2>&1; then
    entry="0 1 * * * rc-service $SB_SERVICE restart > /dev/null 2>&1 $RESTART_CRON_MARKER"
  else
    entry="0 1 * * * systemctl restart $SB_SERVICE > /dev/null 2>&1 $RESTART_CRON_MARKER"
  fi
  { printf '%s\n' "$filtered"; printf '%s\n' "$entry"; } | crontab - >/dev/null 2>&1 || return 1
  load_current_crontab || return 1
  printf '%s\n' "$CURRENT_CRONTAB" | grep -Fq "$RESTART_CRON_MARKER"
}

script_copy_has_identity(){
  local path=$1
  [[ -f $path && ! -L $path ]] || return 1
  grep -Fqx '#!/bin/bash' "$path" 2>/dev/null &&
    grep -Fqx '# sb-generated-artifact: v1' "$path" 2>/dev/null &&
    grep -Fqx 'CORE_VERSION="1.10.7"' "$path" 2>/dev/null &&
    grep -Fqx 'ACME_VERSION="3.1.4"' "$path" 2>/dev/null &&
    grep -Fqx 'SB_DIR="/etc/sb"' "$path" 2>/dev/null &&
    grep -Fqx 'SB_SERVICE="sb"' "$path" 2>/dev/null &&
    grep -Fqx 'SHORTCUT="/usr/bin/sb"' "$path" 2>/dev/null &&
    grep -Eq '^sb_version="v[0-9]+\.[0-9]+\.[0-9]+"$' "$path" 2>/dev/null
}

script_copy_version(){
  local path=$1
  script_copy_has_identity "$path" || return 1
  sed -n 's/^sb_version="v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' "$path" | head -n 1
}

version_is_older(){
  local candidate=$1 installed=$2
  local c_major c_minor c_patch i_major i_minor i_patch
  IFS=. read -r c_major c_minor c_patch <<< "$candidate"
  IFS=. read -r i_major i_minor i_patch <<< "$installed"
  ((10#$c_major < 10#$i_major)) ||
    ((10#$c_major == 10#$i_major && 10#$c_minor < 10#$i_minor)) ||
    ((10#$c_major == 10#$i_major && 10#$c_minor == 10#$i_minor && 10#$c_patch < 10#$i_patch))
}

shortcut_is_owned(){
  script_copy_has_identity "$SHORTCUT"
}

script_source_is_valid(){
  local path=$1
  script_copy_has_identity "$path"
}

atomic_install_shortcut(){
  local source=$1 mode=$2 shortcut_tmp
  [[ -f $source && ! -L $source && $mode =~ ^[0-7]{3,4}$ ]] || return 1
  shortcut_tmp=$(mktemp "${SHORTCUT}.tmp.XXXXXX") || return 1
  if ! install -m "$mode" "$source" "$shortcut_tmp" ||
     ! mv -fT -- "$shortcut_tmp" "$SHORTCUT"; then
    rm -f "$shortcut_tmp"
    return 1
  fi
}

update_shortcut(){
  local source_path bash_path source_version shortcut_version tmp_src=""
  if [[ -f $0 ]]; then
    if [[ $0 == "/dev/fd/"* ]]; then
      tmp_src=$(mktemp /tmp/sb-src.XXXXXX) || return 1
      if ! curl -fsSL https://raw.githubusercontent.com/zhemed/SB/main/sb.sh -o "$tmp_src" 2>/dev/null && ! wget -qO "$tmp_src" https://raw.githubusercontent.com/zhemed/SB/main/sb.sh 2>/dev/null; then
        rm -f "$tmp_src"
        return 1
      fi
      if ! script_source_is_valid "$tmp_src"; then
        rm -f "$tmp_src"
        return 1
      fi
      source_path="$tmp_src"
    elif [[ $0 == "bash" ]]; then
      return 1
    else
      source_path=$(readlink -f "$0" 2>/dev/null) || { [[ -z $tmp_src ]] || rm -f "$tmp_src"; return 1; }
      if ! script_source_is_valid "$source_path"; then
        [[ -z $tmp_src ]] || rm -f "$tmp_src"
        red "当前运行源不是完整的 sb.sh 文件，拒绝创建快捷方式 $SHORTCUT"
        return 1
      fi
    fi
  else
    [[ -z $tmp_src ]] || rm -f "$tmp_src"
    return 1
  fi
  bash_path=$(readlink -f "$(command -v bash)" 2>/dev/null || true)
  if [[ -n $bash_path && $source_path == "$bash_path" ]]; then
    [[ -z $tmp_src ]] || rm -f "$tmp_src"
    red "当前运行源不是完整的 sb.sh 文件，拒绝创建快捷方式 $SHORTCUT"
    return 1
  fi
  if [[ $source_path != "$SHORTCUT" ]]; then
    if [[ -e $SHORTCUT || -L $SHORTCUT ]] && ! shortcut_is_owned; then
      [[ -z $tmp_src ]] || rm -f "$tmp_src"
      red "检测到非本脚本管理的 $SHORTCUT，拒绝覆盖；请先处理该命令冲突"
      return 1
    fi
    if shortcut_is_owned; then
      source_version=$(script_copy_version "$source_path") || { [[ -z $tmp_src ]] || rm -f "$tmp_src"; return 1; }
      shortcut_version=$(script_copy_version "$SHORTCUT") || { [[ -z $tmp_src ]] || rm -f "$tmp_src"; return 1; }
      if version_is_older "$source_version" "$shortcut_version"; then
        [[ -z $tmp_src ]] || rm -f "$tmp_src"
        red "当前脚本 v${source_version} 旧于快捷命令 v${shortcut_version}，拒绝降级覆盖"
        return 1
      fi
    fi
    if ! atomic_install_shortcut "$source_path" 755; then
      [[ -z $tmp_src ]] || rm -f "$tmp_src"
      return 1
    fi
  elif ! shortcut_is_owned; then
    [[ -z $tmp_src ]] || rm -f "$tmp_src"
    red "$SHORTCUT 归属校验失败，拒绝更新快捷方式"
    return 1
  fi
  [[ -z $tmp_src ]] || rm -f "$tmp_src"
  return 0
}

prepare_runtime_state(){
  if formal_service_present && ! service_is_owned && ! service_definition_is_repairable; then
    red "检测到不属于本脚本的 $SB_SERVICE 服务，拒绝继续"
    return 1
  fi
  prepare_managed_directory || return 1
  if acme_state_backup_candidates_exist; then
    if ! command -v flock >/dev/null 2>&1; then
      red "检测到 ACME 恢复点，但系统缺少 flock，无法安全恢复或清理"
      return 1
    fi
    with_acme_lock resolve_orphaned_acme_state_backup || return 1
  fi
}

cron_daemon_is_active(){
  if command -v apk >/dev/null 2>&1; then
    rc-service crond status >/dev/null 2>&1
  else
    systemctl is-active --quiet cron 2>/dev/null ||
      systemctl is-active --quiet crond 2>/dev/null
  fi
}

enable_cron_daemon(){
  local cron_service
  if command -v apk >/dev/null 2>&1; then
    rc-update add crond default >/dev/null 2>&1 ||
      rc-update show default 2>/dev/null | grep -qE '(^|[[:space:]])crond([[:space:]]|$)' || return 1
    rc-service crond start >/dev/null 2>&1 || cron_daemon_is_active || return 1
  else
    if systemctl cat cron.service >/dev/null 2>&1; then
      cron_service=cron
    elif systemctl cat crond.service >/dev/null 2>&1; then
      cron_service=crond
    else
      return 1
    fi
    systemctl enable --now "$cron_service" >/dev/null 2>&1 || return 1
  fi
  cron_daemon_is_active
}

core_dependencies_ready(){
  local cmd
  for cmd in awk base64 bash cmp cp curl cut date flock grep install ip jq mktemp mv \
    openssl rm sed sha256sum shuf ss stat tail tar tr; do
    command -v "$cmd" >/dev/null 2>&1 || return 1
  done
  if command -v apk >/dev/null 2>&1; then
    command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 || return 1
  else
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || return 1
  fi
}

dependencies_ready(){
  local cmd
  core_dependencies_ready || return 1
  for cmd in crontab flock qrencode; do
    command -v "$cmd" >/dev/null 2>&1 || return 1
  done
  cron_daemon_is_active
}

install_dependencies(){
  green "安装依赖……"
  if command -v apk >/dev/null 2>&1; then
    apk update && apk add bash jq openssl iproute2 coreutils grep tar tzdata util-linux curl qrencode || return 1
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq cron coreutils util-linux curl openssl iproute2 tar qrencode || return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release && dnf install -y jq cronie coreutils util-linux curl openssl iproute tar qrencode || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release && yum install -y jq cronie coreutils util-linux curl openssl iproute tar qrencode || return 1
  else
    red "未找到受支持的包管理器"
    return 1
  fi
  if ! enable_cron_daemon; then
    red "cron/crond 服务启动失败，无法保证证书自动续期"
    return 1
  fi
  if ! dependencies_ready; then
    red "依赖安装不完整，请检查上方包管理器错误"
    return 1
  fi
  atomic_write_private_text "$SB_DIR/.deps_ok" ready
}
