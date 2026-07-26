# sb-module: 60-cron
# Manage only sb-owned crontab entries.
load_current_crontab(){
  local error_file error_text temp_base=$SB_DIR
  CURRENT_CRONTAB=
  [[ -d $temp_base ]] || temp_base=/tmp
  error_file=$(mktemp "$temp_base/.crontab-error.XXXXXX") || return 1
  if CURRENT_CRONTAB=$(crontab -l 2>"$error_file"); then
    rm -f "$error_file"
    return 0
  fi
  error_text=$(cat "$error_file" 2>/dev/null)
  rm -f "$error_file"
  if printf '%s\n' "$error_text" | grep -qi 'no crontab for'; then
    return 0
  fi
  if printf '%s\n' "$error_text" | grep -qi 'no such file or directory' && \
     [[ ! -e /var/spool/cron/crontabs/root && ! -e /var/spool/cron/root ]]; then
    return 0
  fi
  red "读取root crontab失败，拒绝覆盖现有定时任务"
  return 1
}

crontab_has_acme_entries(){
  local content=$1
  printf '%s\n' "$content" | grep -Fq "$ACME_CRON_MARKER" ||
    printf '%s\n' "$content" | grep -Fq "$ACME_BIN --cron" ||
    printf '%s\n' "$content" | grep -Fq "$SB_DIR/cert_renew.sh"
}

acme_renew_cron_entry(){
  printf '%s\n' "17 3,9,15,21 * * * HOME=$SB_DIR $ACME_BIN --cron --home $ACME_HOME --config-home $ACME_HOME > /dev/null 2>&1 $ACME_CRON_MARKER"
}

acme_renew_cron_is_current(){
  local content=$1 entry exact_count marker_count command_count
  entry=$(acme_renew_cron_entry)
  exact_count=$(printf '%s\n' "$content" | grep -Fxc -- "$entry" || true)
  marker_count=$(printf '%s\n' "$content" | grep -Fc -- "$ACME_CRON_MARKER" || true)
  command_count=$(printf '%s\n' "$content" | grep -Fc -- "$ACME_BIN --cron" || true)
  [[ $exact_count -eq 1 && $marker_count -eq 1 && $command_count -eq 1 ]] &&
    ! printf '%s\n' "$content" | grep -Fq "$SB_DIR/cert_renew.sh"
}

filter_acme_cron_entries(){
  grep -Fv "$ACME_CRON_MARKER" |
    grep -Fv "$ACME_BIN --cron" |
    grep -Fv "$SB_DIR/cert_renew.sh"
}

crontab_has_restart_entries(){
  local content=$1
  printf '%s\n' "$content" | grep -Fq "$RESTART_CRON_MARKER"
}

filter_restart_cron_entries(){
  grep -Fv "$RESTART_CRON_MARKER"
}

remove_acme_renew_cron(){
  local current filtered
  load_current_crontab || return 1
  current=$CURRENT_CRONTAB
  if ! crontab_has_acme_entries "$current"; then
    rm -f "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
    return
  fi
  filtered=$(printf '%s\n' "$current" | filter_acme_cron_entries || true)
  printf '%s\n' "$filtered" | crontab - >/dev/null 2>&1 || return 1
  load_current_crontab || return 1
  if crontab_has_acme_entries "$CURRENT_CRONTAB"; then
    return 1
  fi
  rm -f "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
}

remove_current_acme_cron(){
  local current filtered
  load_current_crontab || return 1
  current=$CURRENT_CRONTAB
  if ! crontab_has_acme_entries "$current"; then
    return 0
  fi
  filtered=$(printf '%s\n' "$current" | filter_acme_cron_entries || true)
  printf '%s\n' "$filtered" | crontab - >/dev/null 2>&1 || return 1
  load_current_crontab || return 1
  ! crontab_has_acme_entries "$CURRENT_CRONTAB"
}

remove_all_managed_crons(){
  local current filtered
  load_current_crontab || return 1
  current=$CURRENT_CRONTAB
  if ! crontab_has_acme_entries "$current" && ! crontab_has_restart_entries "$current"; then
    rm -f "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
    return
  fi
  filtered=$(printf '%s\n' "$current" | filter_acme_cron_entries | filter_restart_cron_entries || true)
  printf '%s\n' "$filtered" | crontab - >/dev/null 2>&1 || return 1
  load_current_crontab || return 1
  if crontab_has_acme_entries "$CURRENT_CRONTAB" || crontab_has_restart_entries "$CURRENT_CRONTAB"; then
    return 1
  fi
  rm -f "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
}

setup_acme_renew_cron(){
  local current filtered entry
  if ! cron_daemon_is_active; then
    red "cron/crond 服务未运行，拒绝写入无法执行的 ACME 续期任务"
    return 1
  fi
  config_uses_acme_certificate || return 1
  [[ -x $ACME_BIN && -f $ACME_HOME/dnsapi/dns_cf.sh && -s $ACME_IDENTITY ]] || return 1
  write_acme_reload_hook || return 1
  load_current_crontab || return 1
  current=$CURRENT_CRONTAB
  filtered=$(printf '%s\n' "$current" | filter_acme_cron_entries || true)
  entry=$(acme_renew_cron_entry)
  { printf '%s\n' "$filtered"; printf '%s\n' "$entry"; } | crontab - >/dev/null 2>&1 || return 1
  load_current_crontab || return 1
  if ! acme_renew_cron_is_current "$CURRENT_CRONTAB"; then
    return 1
  fi
  rm -f "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
}

ensure_acme_renew_cron(){
  local current
  if ! cron_daemon_is_active; then
    red "cron/crond 服务未运行，ACME 自动续期当前不可用"
    return 1
  fi
  load_current_crontab || return 1
  current=$CURRENT_CRONTAB
  if config_uses_acme_certificate; then
    if [[ ! -x $ACME_BIN || ! -f $ACME_HOME/dnsapi/dns_cf.sh || ! -s $ACME_IDENTITY ]]; then
      red "当前配置正在使用 ACME 证书，但续期组件不完整；已保留现有 cron，请立即修复"
      return 1
    fi
    if ! acme_reload_hook_is_current || ! acme_renew_cron_is_current "$current"; then
      setup_acme_renew_cron
    fi
  elif config_uses_self_signed_certificate && { \
       crontab_has_acme_entries "$current"; }; then
    remove_acme_renew_cron
  elif crontab_has_acme_entries "$current"; then
    red "无法确认当前证书模式；为避免中断续期，已保留现有 ACME cron"
    return 1
  fi
}
