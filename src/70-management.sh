# sb-module: 70-management
# Certificate management
current_certificate_mode(){
  if config_uses_acme_certificate; then
    printf '%s\n' acme
  elif config_uses_self_signed_certificate; then
    printf '%s\n' self_signed
  else
    printf '%s\n' unknown
  fi
}

certificate_action_service_ready(){
  if [[ -x $SB_BIN && -s $SB_CONFIG ]]; then
    return 0
  fi
  red "Sing-box 内核或配置文件不完整，无法安全修改证书；请先使用菜单[2]修复"
  return 1
}

activate_managed_certificate(){
  local cert=$1 key=$2 candidate commit_status
  CERT_ACTIVATION_MAINTENANCE_OK=1
  if ! load_certificate_metadata "$cert" "$key" || [[ $CERT_META_STATE != valid ]]; then
    red "目标证书无效、已过期或与私钥不匹配，拒绝切换"
    return 1
  fi
  candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX") || return 1
  if ! jq --arg cert "$cert" --arg key "$key" '
    if ([.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb")] | length) != 1
    then error("hy2 inbound missing or duplicated")
    else (.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.certificate_path) = $cert |
         (.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.key_path) = $key
    end
  ' "$SB_CONFIG" > "$candidate" ||
     ! jq -e --arg cert "$cert" --arg key "$key" '
       [.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb" and
       .tls.certificate_path == $cert and .tls.key_path == $key)] | length == 1
     ' "$candidate" >/dev/null; then
    rm -f "$candidate"
    red "生成证书候选配置失败，原配置未修改"
    return 1
  fi
  if commit_config "$candidate"; then
    :
  else
    commit_status=$?
    if [[ $commit_status -eq 2 ]]; then
      red "证书切换失败且自动回滚失败，请立即检查服务和配置备份"
      return 2
    fi
    red "证书切换失败，原配置未修改或已恢复"
    return 1
  fi
  if [[ $key == "$ACME_KEY" ]]; then
    if ! setup_acme_renew_cron; then
      CERT_ACTIVATION_MAINTENANCE_OK=0
      yellow "证书已切换，但自动续期任务异常，请使用本菜单修复"
    fi
  elif ! remove_acme_renew_cron; then
    CERT_ACTIVATION_MAINTENANCE_OK=0
    yellow "证书已切换，但 ACME 自动续期任务清理失败"
  fi
  refresh_share_files_after_change || true
  green "证书模式切换成功"
}

show_certificate_metadata(){
  local label=$1 cert=$2 key=$3 identity=${4:-}
  green "证书类型: $label"
  if ! load_certificate_metadata "$cert" "$key"; then
    red "证书状态: 无法读取或文件不完整"
    return 1
  fi
  case $CERT_META_STATE in
    valid) green "证书状态: 有效" ;;
    expired) red "证书状态: 已过期" ;;
    not_yet_valid) red "证书状态: 尚未生效" ;;
    key_mismatch) red "证书状态: 证书与私钥不匹配" ;;
    *) red "证书状态: 无效" ;;
  esac
  printf '覆盖域名: %s\n' "${CERT_META_DNS_NAMES:-未提供 SAN}"
  printf '签发机构: %s\n' "$CERT_META_ISSUER"
  printf '生效时间: %s\n' "$CERT_META_NOT_BEFORE"
  printf '到期时间: %s\n' "$CERT_META_NOT_AFTER"
  if ((CERT_META_REMAINING_DAYS < 0)); then
    red "剩余有效期: 已过期 $((-CERT_META_REMAINING_DAYS)) 天"
  elif ((CERT_META_REMAINING_DAYS <= 30)); then
    yellow "剩余有效期: ${CERT_META_REMAINING_DAYS} 天"
  else
    green "剩余有效期: ${CERT_META_REMAINING_DAYS} 天"
  fi
  if [[ $CERT_META_KEY_MATCH -eq 1 ]]; then
    green "证书/私钥: 匹配"
  else
    red "证书/私钥: 不匹配"
  fi
  if [[ -n $identity ]]; then
    if certificate_identity_matches "$cert" "$identity"; then
      green "TLS 身份: $identity（证书已覆盖）"
    else
      red "TLS 身份: $identity（证书未覆盖）"
    fi
  fi
  printf 'SHA-256 指纹: %s\n' "$CERT_META_FINGERPRINT"
}

show_acme_certificate_schedule(){
  local identity=$1
  if load_acme_certificate_schedule "$identity"; then
    printf 'ACME 服务: %s\n' "$ACME_META_CA"
    printf '最近签发/续期: %s\n' "$ACME_META_CREATED"
    printf '当前计划续期: %s\n' "$ACME_META_NEXT_RENEW"
    printf '最近部署成功: %s\n' "${ACME_META_DEPLOYED:-暂无记录}"
  else
    yellow "ACME 时间记录: 无法安全读取"
    return 1
  fi
}

inspect_acme_renewal_health(){
  local current state now identity reference_epoch
  ACME_RENEW_HEALTH=normal
  ACME_RENEW_HEALTH_DETAIL=正常
  if [[ ! -x $ACME_BIN || ! -f $ACME_HOME/dnsapi/dns_cf.sh || ! -s $ACME_IDENTITY ]]; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="acme.sh 组件不完整"
  elif ! cloudflare_acme_credentials_present; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="Cloudflare 凭据缺失或格式异常"
  elif ! identity=$(read_acme_identity 2>/dev/null); then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="ACME 身份文件损坏"
  elif ! load_certificate_metadata "$ACME_CERT" "$ACME_KEY" ||
       [[ $CERT_META_STATE != valid ]] ||
       ! certificate_identity_matches "$ACME_CERT" "$identity"; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="当前证书无效或未覆盖 ACME 身份"
  elif ! load_acme_certificate_schedule "$identity"; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="ACME 域名配置或续期时间记录异常"
  elif ! managed_acme_live_layout_is_valid; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="证书原子部署目录或 current 指针异常"
  elif ! acme_deployment_config_is_current "$identity"; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="acme.sh 部署目标不是受管暂存目录"
  elif ! cron_daemon_is_active; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="cron/crond 未运行"
  elif ! acme_reload_hook_is_current; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="证书生效回调缺失或过期"
  elif ! acme_renew_runner_is_current; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="续期检查器缺失或过期"
  elif ! load_current_crontab; then
    ACME_RENEW_HEALTH=error
    ACME_RENEW_HEALTH_DETAIL="无法读取 root crontab"
  else
    current=$CURRENT_CRONTAB
    if ! acme_renew_cron_is_current "$current"; then
      ACME_RENEW_HEALTH=error
      ACME_RENEW_HEALTH_DETAIL="定时任务缺失或不规范"
    fi
  fi
  if [[ $ACME_RENEW_HEALTH == normal ]]; then
    state=$(acme_renew_state_path)
    if load_acme_renew_state; then
      now=$(date +%s 2>/dev/null || true)
      if [[ $ACME_RENEW_LAST_RESULT == failed ]]; then
        ACME_RENEW_HEALTH=error
        ACME_RENEW_HEALTH_DETAIL="最近一次检查失败，退出码 $ACME_RENEW_LAST_EXIT_CODE"
      elif [[ $now =~ ^[0-9]+$ ]] && ((now - ACME_RENEW_LAST_CHECK_EPOCH > 86400)); then
        ACME_RENEW_HEALTH=error
        ACME_RENEW_HEALTH_DETAIL="超过 24 小时没有成功检查"
      elif [[ $now =~ ^[0-9]+$ ]] && ((ACME_RENEW_LAST_CHECK_EPOCH > now + 300)); then
        ACME_RENEW_HEALTH=error
        ACME_RENEW_HEALTH_DETAIL="最近检查时间晚于系统时间"
      fi
    elif [[ -e $state || -L $state ]]; then
      ACME_RENEW_HEALTH=error
      ACME_RENEW_HEALTH_DETAIL="续期状态记录损坏或权限异常"
    else
      now=$(date +%s 2>/dev/null || true)
      reference_epoch=${ACME_META_DEPLOYED_EPOCH:-$ACME_META_CREATED_EPOCH}
      if [[ $now =~ ^[0-9]+$ && $reference_epoch =~ ^[0-9]+$ ]] &&
         ((now - reference_epoch > 28800)); then
        ACME_RENEW_HEALTH=error
        ACME_RENEW_HEALTH_DETAIL="证书部署超过 8 小时但没有续期检查记录"
      fi
    fi
  fi
}

show_acme_renewal_status(){
  local identity=$1 state
  show_acme_certificate_schedule "$identity" || true
  printf '定时检查: 每天 03:17 / 09:17 / 15:17 / 21:17（服务器时间）\n'
  inspect_acme_renewal_health
  if [[ $ACME_RENEW_HEALTH == normal ]]; then
    green "自动续期: 正常"
  else
    red "自动续期: 异常（$ACME_RENEW_HEALTH_DETAIL）"
  fi
  if load_acme_renew_state; then
    printf '最近自动检查: %s\n' "$ACME_RENEW_LAST_CHECK"
    case $ACME_RENEW_LAST_RESULT in
      renewed) green "最近检查结果: 已续期并执行证书生效回调" ;;
      unchanged) green "最近检查结果: 成功，暂不需要续期" ;;
      failed) red "最近检查结果: 失败（退出码 $ACME_RENEW_LAST_EXIT_CODE）" ;;
    esac
    if [[ $ACME_RENEW_LAST_RENEWAL_EPOCH != 0 ]]; then
      printf '最近自动续期: %s\n' "$ACME_RENEW_LAST_RENEWAL"
    fi
  else
    state=$(acme_renew_state_path)
    if [[ -e $state || -L $state ]]; then
      red "最近自动检查: 状态记录损坏或权限异常"
    else
      yellow "最近自动检查: 暂无记录"
    fi
  fi
  if service_is_active; then
    green "续期生效方式: 成功续期后自动重启 sb"
  else
    yellow "续期生效方式: 服务当前未运行，续期不会强制启动服务"
  fi
}

show_certificate_dashboard(){
  local mode identity='' current_cert current_key standby_identity
  mode=$(current_certificate_mode)
  current_cert=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.certificate_path' "$SB_CONFIG" 2>/dev/null || true)
  current_key=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.key_path' "$SB_CONFIG" 2>/dev/null || true)
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "证书管理"
  if service_is_active; then
    green "服务状态: 运行中"
  else
    yellow "服务状态: 未运行"
  fi
  case $mode in
    acme)
      identity=$(read_acme_identity 2>/dev/null || true)
      show_certificate_metadata "ACME 域名证书" "$ACME_CERT" "$ACME_KEY" "$identity" || true
      if [[ -n $identity ]]; then
        show_acme_renewal_status "$identity"
      else
        red "ACME 身份文件与证书不一致"
      fi
      ;;
    self_signed)
      show_certificate_metadata "自签 bing 证书" "$SB_DIR/cert.pem" "$SB_DIR/private.key" www.bing.com || true
      yellow "自动续期: 不适用（自签证书不会通过 ACME 续期）"
      if standby_identity=$(read_acme_identity 2>/dev/null); then
        echo
        yellow "备用 ACME 证书（当前未使用）"
        show_certificate_metadata "备用 ACME 域名证书" "$ACME_CERT" "$ACME_KEY" "$standby_identity" || true
        show_acme_certificate_schedule "$standby_identity" || true
        yellow "备用证书自动续期: 已暂停；切换为该证书后会自动恢复"
      fi
      ;;
    *)
      red "当前模式: 未知或配置不完整"
      printf '证书路径: %s\n私钥路径: %s\n' "${current_cert:-无法读取}" "${current_key:-无法读取}"
      ;;
  esac
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  CURRENT_CERT_MODE=$mode
}

finish_acme_replacement(){
  local backup_path
  if ! clear_acme_state_backup; then
    backup_path=$ACME_STATE_BACKUP
    ACME_STATE_BACKUP=
    ACME_RESTORE_ACTIVE_ON_INTERRUPT=0
    yellow "新证书已生效，但旧状态临时备份未能删除：$backup_path"
    return 1
  fi
  ACME_RESTORE_ACTIVE_ON_INTERRUPT=0
}

rollback_new_acme_state(){
  local had_backup=0
  [[ -n ${ACME_STATE_BACKUP:-} ]] && had_backup=1
  discard_acme_state || yellow "清理未生效的新 ACME 状态不完整"
  if [[ $had_backup -eq 1 ]]; then
    restore_acme_state_backup || {
      red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
      ACME_RESTORE_ACTIVE_ON_INTERRUPT=0
      return 1
    }
  fi
}

restore_previous_active_acme(){
  local old_identity=$1 restored_identity
  [[ -n $old_identity ]] || return 1
  yellow "正在恢复原 ACME 证书和自动续期……"
  restored_identity=$(detect_acme_identity 2>/dev/null) || return 1
  if [[ $restored_identity == "$old_identity" ]] && cert_acme &&
     activate_managed_certificate "$ACME_CERT" "$ACME_KEY"; then
    if [[ $CERT_ACTIVATION_MAINTENANCE_OK -eq 1 ]]; then
      green "原 ACME 证书和自动续期已恢复"
    else
      yellow "原 ACME 证书已恢复，但自动续期仍需修复"
    fi
    return 0
  fi
  red "原 ACME 证书自动恢复失败，请立即检查证书状态"
  return 1
}

apply_new_cloudflare_certificate(){
  local activation_status backup_path
  certificate_action_service_ready || return 1
  if ! issue_cloudflare_certificate 0 1; then
    red "新证书申请失败，当前证书未改变"
    return 1
  fi
  if cert_acme; then
    if activate_managed_certificate "$ACME_CERT" "$ACME_KEY"; then
      finish_acme_replacement || true
      if [[ $CERT_ACTIVATION_MAINTENANCE_OK -eq 1 ]]; then
        green "新 ACME 证书已切换并启用自动续期"
      else
        yellow "新 ACME 证书已切换，但自动续期配置异常，请使用修复功能"
      fi
      return 0
    else
      activation_status=$?
    fi
  else
    activation_status=1
  fi
  if [[ $activation_status -eq 2 ]]; then
    backup_path=$ACME_STATE_BACKUP
    ACME_STATE_BACKUP=
    ACME_RESTORE_ACTIVE_ON_INTERRUPT=0
    red "配置切换与自动回滚均失败；为避免删除当前配置可能引用的证书，已保留新 ACME 状态"
    yellow "申请前的 ACME 状态备份保留在：$backup_path"
    return 2
  fi
  red "新证书已签发，但服务切换失败，正在恢复申请前的 ACME 状态"
  rollback_new_acme_state || true
  return 1
}

replace_active_acme_certificate(){
  local choice old_identity activation_status backup_path
  if ! old_identity=$(detect_acme_identity 2>/dev/null); then
    red "当前 ACME 证书无效，无法建立可靠的恢复点；请先修复证书状态"
    return 1
  fi
  yellow "更换期间服务保持运行，成功后重启 1 次加载新证书；失败自动恢复原证书（全程持有 ACME 锁）"
  readp "输入1继续，输入0取消：" choice || return 1
  [[ $choice == 1 ]] || return 0
  certificate_action_service_ready || return 1
  if ! begin_acme_state_backup; then
    red "无法安全备份原 ACME 状态，已取消更换"
    return 1
  fi
  ACME_RESTORE_ACTIVE_ON_INTERRUPT=1
  if issue_cloudflare_certificate 0 1 1; then
    if cert_acme; then
      if activate_managed_certificate "$ACME_CERT" "$ACME_KEY"; then
        finish_acme_replacement || true
        if [[ $CERT_ACTIVATION_MAINTENANCE_OK -eq 1 ]]; then
          green "ACME 证书与 Cloudflare 凭据更换完成"
        else
          yellow "新 ACME 证书已生效，但自动续期配置异常，请使用修复功能"
        fi
        return 0
      else
        activation_status=$?
      fi
    else
      activation_status=1
    fi
    if [[ $activation_status -eq 2 ]]; then
      backup_path=$ACME_STATE_BACKUP
      ACME_STATE_BACKUP=
      ACME_RESTORE_ACTIVE_ON_INTERRUPT=0
      red "配置切换与自动回滚均失败；已保留新 ACME 状态，避免破坏当前配置引用"
      yellow "更换前的 ACME 状态备份保留在：$backup_path"
      return 2
    fi
    red "新证书已签发，但服务切换失败"
    rollback_new_acme_state || true
  elif [[ -n ${ACME_STATE_BACKUP:-} ]]; then
    rollback_new_acme_state || true
  fi
  ACME_RESTORE_ACTIVE_ON_INTERRUPT=0
  red "新证书申请或切换失败"
  restore_previous_active_acme "$old_identity" || true
  return 1
}

run_acme_renewal_check(){
  local runner
  config_uses_acme_certificate || { red "当前未使用 ACME 证书"; return 1; }
  if ! with_acme_lock setup_acme_renew_cron; then
    red "自动续期组件修复失败，无法执行检查"
    return 1
  fi
  runner=$(acme_renew_runner_path) || return 1
  green "正在执行 ACME 续期检查；未到计划时间时不会重复签发……"
  if "$runner"; then
    green "续期检查完成"
  else
    red "续期检查失败，请查看上方 acme.sh 输出"
    return 1
  fi
}

force_acme_reissue(){
  local runner choice
  config_uses_acme_certificate || { red "当前未使用 ACME 证书"; return 1; }
  yellow "强制重签会立即联系 Let's Encrypt，并计入证书签发频率限制"
  readp "输入1确认强制重签，输入0取消：" choice || return 1
  [[ $choice == 1 ]] || return 0
  if ! with_acme_lock setup_acme_renew_cron; then
    red "自动续期组件修复失败，无法执行强制重签"
    return 1
  fi
  runner=$(acme_renew_runner_path) || return 1
  green "正在强制重新签发当前 ACME 证书……"
  if "$runner" --force; then
    if ! load_acme_renew_state || [[ $ACME_RENEW_LAST_RESULT != renewed ]]; then
      red "重签命令已结束，但托管证书没有发生变化，不能确认重签成功"
      return 1
    fi
    if service_is_active; then
      green "证书已重新签发，sb 已通过回调重启并加载新证书"
    else
      yellow "证书已重新签发；sb 当前未运行，下次启动时会加载新证书"
    fi
  else
    red "强制重签失败，请查看上方 acme.sh 输出"
    return 1
  fi
}

change_cert_mode(){
  local menu acme_name
  while true; do
    echo
    show_certificate_dashboard
    case $CURRENT_CERT_MODE in
      acme)
        green "1：立即执行计划续期检查"
        green "2：强制重新签发当前证书"
        green "3：修复自动续期"
        green "4：更换域名、Account ID 或 Token"
        green "5：切换为自签 bing 证书"
        green "0：返回主菜单"
        readp "请选择【0-5】：" menu || return 1
        case $menu in
          1) run_acme_renewal_check; readp "按回车返回证书管理..." ;;
          2) force_acme_reissue; readp "按回车返回证书管理..." ;;
          3)
            if with_acme_lock setup_acme_renew_cron; then green "自动续期修复成功"; else red "自动续期修复失败"; fi
            readp "按回车返回证书管理..."
            ;;
          4) with_acme_lock replace_active_acme_certificate; readp "按回车返回证书管理..." ;;
          5)
            certificate_action_service_ready &&
              with_acme_lock activate_managed_certificate "$SB_DIR/cert.pem" "$SB_DIR/private.key"
            readp "按回车返回证书管理..."
            ;;
          ""|0) return 0 ;;
          *) red "请输入0、1、2、3、4或5"; sleep 1 ;;
        esac
        ;;
      self_signed)
        if acme_name=$(detect_acme_identity 2>/dev/null); then
          green "1：切换为已有 ACME 证书 ($acme_name)"
          green "2：申请新的 Cloudflare ACME 证书"
          green "0：返回主菜单"
          readp "请选择【0-2】：" menu || return 1
          case $menu in
            1)
              certificate_action_service_ready && cert_acme &&
                with_acme_lock activate_managed_certificate "$ACME_CERT" "$ACME_KEY"
              readp "按回车返回证书管理..."
              ;;
            2)
              with_acme_lock apply_new_cloudflare_certificate
              readp "按回车返回证书管理..."
              ;;
            ""|0) return 0 ;;
            *) red "请输入0、1或2"; sleep 1 ;;
          esac
        else
          green "1：申请 Cloudflare ACME 证书"
          green "0：返回主菜单"
          readp "请选择【0-1】：" menu || return 1
          case $menu in
            1)
              with_acme_lock apply_new_cloudflare_certificate
              readp "按回车返回证书管理..."
              ;;
            ""|0) return 0 ;;
            *) red "请输入0或1"; sleep 1 ;;
          esac
        fi
        ;;
      *)
        green "1：切换为自签 bing 证书"
        green "2：申请并切换为 Cloudflare ACME 证书"
        green "0：返回主菜单"
        readp "请选择【0-2】：" menu || return 1
        case $menu in
          1)
            certificate_action_service_ready &&
              with_acme_lock activate_managed_certificate "$SB_DIR/cert.pem" "$SB_DIR/private.key"
            readp "按回车返回证书管理..."
            ;;
          2)
            with_acme_lock apply_new_cloudflare_certificate
            readp "按回车返回证书管理..."
            ;;
          ""|0) return 0 ;;
          *) red "请输入0、1或2"; sleep 1 ;;
        esac
        ;;
    esac
  done
}


# Change ports
change_ports(){
  local nport port candidate menu retry commit_status hy2_port port_hy2
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! hy2_port=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前端口失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  port_hy2=$hy2_port
  echo
  while true; do
    green "更改端口"
    green "1：Hysteria2主端口 ${yellow}当前: $hy2_port${plain}"
    green "0：返回主菜单"
    readp "请选择【0-1】：" menu || return 1
    case "$menu" in
      ""|0) return 0 ;;
      1)
        readp "请输入新主端口 (1-65535，留空随机10000-65535): " nport || return 1
        port="$nport"
        chooseport udp || continue
        if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
          red "创建端口候选配置失败，原配置未修改"
          readp "按回车重试，输入0返回主菜单：" retry || return 1
          [[ $retry == 0 ]] && return 1
          continue
        fi
        if ! jq --argjson p "$port" '
          if ([.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb")] | length) != 1
          then error("hy2 inbound missing or duplicated")
          else (.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .listen_port) = $p end
        ' "$SB_CONFIG" > "$candidate" || \
          ! jq -e --argjson p "$port" '[.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb" and .listen_port == $p)] | length == 1' "$candidate" >/dev/null; then
          rm -f "$candidate"
          red "生成端口候选配置失败，原配置未修改"
          readp "按回车重新输入，输入0返回主菜单：" retry || return 1
          [[ $retry == 0 ]] && return 1
          continue
        fi
        if commit_config "$candidate"; then
          refresh_share_files_after_change || true
          green "Hysteria2主端口修改成功：$port"
          yellow "请自行在系统防火墙和VPS厂商安全组放行 ${port}/udp"
          readp "按回车返回主菜单..."
          return 0
        else
          commit_status=$?
        fi
        if [[ $commit_status -eq 2 ]]; then
          red "端口修改失败且自动回滚失败，请先检查服务和备份配置"
          readp "按回车返回主菜单..."
          return 2
        fi
        red "端口修改失败，原配置未修改或已恢复"
        readp "按回车重新输入，输入0返回主菜单：" retry || return 1
        [[ $retry == 0 ]] && return 1
        ;;
      *)
        red "请输入0或1"
        ;;
    esac
  done
}

# Credential management
refresh_share_files_after_change(){
  if ! sbshare >/dev/null 2>&1; then
    yellow "服务端修改成功，但节点文件刷新失败，请稍后通过菜单[3]重试"
    return 1
  fi
}

changeuuid(){
  local olduuid uuid candidate choice retry commit_status
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! olduuid=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .users[0].password' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前UUID失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  echo
  green "当前Hysteria2 UUID（密码）：$olduuid"
  while true; do
    readp "输入新UUID（回车随机生成，输入0返回凭据菜单）：" choice || return 1
    [[ $choice == 0 ]] && return 0
    if [[ -z $choice ]]; then
      uuid=$("$SB_BIN" generate uuid 2>/dev/null || true)
    else
      uuid=$choice
    fi
    if ! valid_uuid "$uuid"; then
      red "UUID格式错误，应为8-4-4-4-12十六进制格式"
      yellow "请重新输入UUID"
      continue
    fi
    if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
      red "创建UUID候选配置失败，原配置未修改"
      readp "按回车重试，输入0返回凭据菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if ! jq --arg uuid "$uuid" '
      if ([.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb")] | length) != 1
      then error("required inbound missing or duplicated")
      else (.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .users[0].password) = $uuid
      end
    ' "$SB_CONFIG" > "$candidate" || \
      ! jq -e --arg uuid "$uuid" '([.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb" and .users[0].password == $uuid)] | length == 1)' "$candidate" >/dev/null; then
      rm -f "$candidate"
      red "生成UUID候选配置失败，原配置未修改"
      readp "按回车重新输入，输入0返回凭据菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      refresh_share_files_after_change || true
      green "Hysteria2 UUID（密码）修改成功：${uuid}"
      readp "按回车返回凭据菜单..."
      return 0
    else
      commit_status=$?
    fi
    if [[ $commit_status -eq 2 ]]; then
      red "UUID修改失败且自动回滚失败，请先检查服务和备份配置"
      readp "按回车返回凭据菜单..."
      return 2
    fi
    red "UUID修改失败，原配置未修改或已恢复"
    readp "按回车重新输入，输入0返回凭据菜单：" retry || return 1
    [[ $retry == 0 ]] && return 1
  done
}

change_ss_password(){
  local current_password new_password candidate choice retry commit_status
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! current_password=$(jq -er '.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb") | .password' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前Shadowsocks-2022密钥失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  echo
  green "当前Shadowsocks-2022密钥：$current_password"
  yellow "密钥不可推导：改完必须同步更新所有客户端，否则会全部连不上"
  while true; do
    readp "输入新密钥（44位标准base64，回车随机生成，输入0返回凭据菜单）：" choice || return 1
    [[ $choice == 0 ]] && return 0
    if [[ -z $choice ]]; then
      new_password=$(generate_ss_password) || new_password=
    else
      new_password=$choice
    fi
    if ! valid_ss_password "$new_password"; then
      red "Shadowsocks-2022密钥必须是44位标准base64（32字节密钥，末尾一个=号）"
      continue
    fi
    if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
      red "创建Shadowsocks-2022密钥候选配置失败，原配置未修改"
      readp "按回车重试，输入0返回凭据菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if ! jq --arg password "$new_password" '
      if ([.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb")] | length) != 1
      then error("ss inbound missing or duplicated")
      else (.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb") | .password) = $password
      end
    ' "$SB_CONFIG" > "$candidate" || \
      ! jq -e --arg password "$new_password" '([.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb" and .password == $password)] | length) == 1' "$candidate" >/dev/null; then
      rm -f "$candidate"
      red "生成Shadowsocks-2022密钥候选配置失败，原配置未修改"
      readp "按回车重新输入，输入0返回凭据菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      refresh_share_files_after_change || true
      green "Shadowsocks-2022密钥修改成功：${new_password}"
      readp "按回车返回凭据菜单..."
      return 0
    else
      commit_status=$?
    fi
    if [[ $commit_status -eq 2 ]]; then
      red "Shadowsocks-2022密钥修改失败且自动回滚失败，请先检查服务和备份配置"
      readp "按回车返回凭据菜单..."
      return 2
    fi
    red "Shadowsocks-2022密钥修改失败，原配置未修改或已恢复"
    readp "按回车重新输入，输入0返回凭据菜单：" retry || return 1
    [[ $retry == 0 ]] && return 1
  done
}
change_credentials(){
  local choice
  while true; do
    echo
    green "凭据管理"
    green "1：更改Hysteria2 UUID（密码）"
    green "0：返回主菜单"
    yellow "Shadowsocks-2022 的密钥在菜单[8]可选功能里管理"
    readp "请选择【0-1】：" choice || return 1
    case "$choice" in
      1) changeuuid ;;
      ""|0) return 0 ;;
      *) red "请输入0或1" ;;
    esac
  done
}

# Upstream / relay ("线路机 -> 落地机")
relay_upstream_reachable(){
  local server=$1 port=$2 target
  target=$server
  valid_ipv6 "$server" && target="[$server]"
  timeout 3 bash -c "exec 3<>/dev/tcp/$target/$port" >/dev/null 2>&1
}

relay_candidate_with_upstream(){
  local output=$1 server=$2 port=$3 password=$4
  jq --arg server "$server" --argjson port "$port" --arg password "$password" --arg method "$SS_METHOD" '
    if ([.outbounds[] | select(.tag == "relay")] | length) > 1 then
      error("duplicated relay outbound")
    else
      .outbounds = ([.outbounds[] | select(.tag != "relay")] +
        [{type: "shadowsocks", tag: "relay", server: $server, server_port: $port,
          method: $method, password: $password}]) |
      .route.final = "relay"
    end
  ' "$SB_CONFIG" > "$output" || return 1
  jq -e --arg server "$server" --argjson port "$port" --arg password "$password" '
    ([.outbounds[] | select(.tag == "relay" and .server == $server and .server_port == $port and .password == $password)] | length) == 1 and
    .route.final == "relay"
  ' "$output" >/dev/null
}

relay_candidate_without_upstream(){
  local output=$1
  jq '
    .outbounds = [.outbounds[] | select(.tag != "relay")] |
    .route.final = "direct"
  ' "$SB_CONFIG" > "$output" || return 1
  jq -e '([.outbounds[] | select(.tag == "relay")] | length) == 0 and .route.final == "direct"' "$output" >/dev/null
}

set_relay_upstream(){
  local server port password candidate commit_status retry
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  echo
  while true; do
    readp "请输入落地机地址（IPv4/IPv6/域名，输入0返回主菜单）：" server || return 1
    [[ $server == 0 ]] && return 0
    if ! relay_server_is_valid "$server"; then
      red "地址格式无效"
      continue
    fi
    readp "请输入落地机端口（1-65535，输入0返回主菜单）：" port || return 1
    [[ $port == 0 ]] && return 0
    if ! valid_port "$port"; then
      red "端口必须是1-65535之间的整数"
      continue
    fi
    readp "请输入落地机的Shadowsocks-2022密钥（44位base64，输入0返回主菜单）：" password || return 1
    [[ $password == 0 ]] && return 0
    if ! valid_ss_password "$password"; then
      red "密钥必须是44位标准base64（32字节密钥，末尾一个=号）"
      continue
    fi
    if ! relay_upstream_reachable "$server" "$port"; then
      yellow "上游 $server:$port 的TCP端口连不上（未放行、未启动或地址填错）"
      yellow "启用后所有出网流量都会走它，上游不通等于断网；清除上游可立即恢复直连"
      if ! confirm_yes "确认仍要保存？输入 YES/y 继续（其他输入取消）："; then
        yellow "已取消，未做任何修改"
        readp "按回车返回可选功能..."
        return 0
      fi
    fi
    if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
      red "创建上游候选配置失败，原配置未修改"
      readp "按回车返回主菜单..."
      return 1
    fi
    if ! relay_candidate_with_upstream "$candidate" "$server" "$port" "$password" || ! chmod 600 "$candidate"; then
      rm -f "$candidate"
      red "生成上游候选配置失败，原配置未修改"
      readp "按回车重新输入，输入0返回主菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      if save_relay_settings "$server" "$port" "$password"; then
        green "上游已启用：${server}:${port}"
        yellow "出网流量已交给落地机；清除上游可恢复直连"
      else
        red "服务端已切换，但上游状态文件写入失败！修复或重建配置后上游会丢失，请重新设置一次"
      fi
      readp "按回车返回主菜单..."
      return 0
    else
      commit_status=$?
    fi
    if [[ $commit_status -eq 2 ]]; then
      red "上游设置失败且自动回滚失败，请先检查服务和备份配置"
      readp "按回车返回主菜单..."
      return 2
    fi
    red "上游设置失败，原配置未修改或已恢复"
    readp "按回车重新输入，输入0返回主菜单：" retry || return 1
    [[ $retry == 0 ]] && return 1
  done
}

clear_relay_upstream(){
  local candidate commit_status
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! relay_settings_present &&
     ! jq -e '[.outbounds[]? | select(.tag == "relay")] | length > 0' "$SB_CONFIG" >/dev/null 2>&1; then
    yellow "当前没有配置上游，无需清除"
    readp "按回车返回主菜单..."
    return 0
  fi
  echo
  if ! confirm_yes "确认清除上游并恢复直连出网？输入 YES/y 确认（其他输入取消）："; then
    yellow "已取消，未做任何修改"
    readp "按回车返回可选功能..."
    return 0
  fi
  if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
    red "创建上游候选配置失败，原配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! relay_candidate_without_upstream "$candidate" || ! chmod 600 "$candidate"; then
    rm -f "$candidate"
    red "生成上游候选配置失败，原配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  if commit_config "$candidate"; then
    if clear_relay_settings; then
      green "上游已清除，出网恢复直连"
    else
      red "服务端已恢复直连，但上游状态文件删除失败，请手动检查 $(relay_config_path)"
    fi
    readp "按回车返回主菜单..."
    return 0
  else
    commit_status=$?
  fi
  if [[ $commit_status -eq 2 ]]; then
    red "清除上游失败且自动回滚失败，请先检查服务和备份配置"
    readp "按回车返回主菜单..."
    return 2
  fi
  red "清除上游失败，原配置未修改或已恢复"
  readp "按回车返回主菜单..."
  return 1
}

manage_relay(){
  local choice
  while true; do
    echo
    green "上游/中转管理"
    if ! relay_settings_present; then
      green "当前上游：${yellow}未配置${green}（全部直连出网）"
    elif load_relay_settings; then
      green "当前上游：${yellow}${relay_server}:${relay_port}${green}（$SS_METHOD）"
    else
      red "上游状态文件存在但无法解析：$(relay_config_path)"
    fi
    yellow "启用上游后本机所有出网流量都交给落地机，上游不可达等于断网"
    green "1：设置/更换上游（落地机）"
    green "2：清除上游（恢复直连）"
    green "0：返回主菜单"
    readp "请选择【0-2】：" choice || return 1
    case "$choice" in
      1) set_relay_upstream ;;
      2) clear_relay_upstream ;;
      ""|0) return 0 ;;
      *) red "请输入0、1或2" ;;
    esac
  done
}

# Optional features (menu [8])
ss_entry_is_enabled(){
  [[ -s $SB_CONFIG ]] &&
    jq -e '([.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb")] | length) == 1' \
      "$SB_CONFIG" >/dev/null 2>&1
}

ss_entry_port(){
  jq -er '.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb") | .listen_port' \
    "$SB_CONFIG" 2>/dev/null
}

# Candidate builders for the optional entry. Both are idempotent: the inbound and
# its UDP-block rule are removed before being (re)inserted, so applying them twice
# yields the same configuration. They patch the live config with jq rather than
# re-rendering, because a render would need every dynamic-scope node parameter.
ss_entry_candidate_with_inbound(){
  local output=$1 port=$2 password=$3 listen=$4
  jq --argjson port "$port" --arg password "$password" --arg method "$SS_METHOD" --arg listen "$listen" '
    if ([.inbounds[] | select(.tag == "ss-sb")] | length) > 1 then
      error("duplicated ss-sb inbound")
    else
      .inbounds = ([.inbounds[] | select(.tag != "ss-sb")] +
        [{type: "shadowsocks", sniff: true, sniff_override_destination: true, tag: "ss-sb",
          listen: $listen, listen_port: $port, network: "tcp",
          method: $method, password: $password}]) |
      .route.rules = ([{inbound: ["ss-sb"], network: "udp", outbound: "block"}] +
        [.route.rules[]? | select(((.inbound // []) | index("ss-sb")) == null)]) |
      .route.final = (.route.final // "direct")
    end
  ' "$SB_CONFIG" > "$output" || return 1
  jq -e --argjson port "$port" --arg password "$password" '
    ([.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb" and .network == "tcp" and
                           .listen_port == $port and .password == $password)] | length) == 1 and
    ([.route.rules[] | select(((.inbound // []) | index("ss-sb")) != null)] | length) == 1
  ' "$output" >/dev/null
}

ss_entry_candidate_without_inbound(){
  local output=$1
  jq '
    .inbounds = [.inbounds[] | select(.tag != "ss-sb")] |
    .route.rules = [.route.rules[]? | select(((.inbound // []) | index("ss-sb")) == null)]
  ' "$SB_CONFIG" > "$output" || return 1
  jq -e '([.inbounds[] | select(.tag == "ss-sb")] | length) == 0 and
         ([.route.rules[]? | select(((.inbound // []) | index("ss-sb")) != null)] | length) == 0' \
    "$output" >/dev/null
}

enable_ss_entry(){
  local port password listen_addr candidate commit_status retry
  if ! sbactive; then
    readp "按回车返回可选功能..."
    return 1
  fi
  if ss_entry_is_enabled; then
    yellow "Shadowsocks-2022 入口已经启用；改端口用【3】，改密钥用【4】"
    readp "按回车返回可选功能..."
    return 0
  fi
  if ! listen_addr=$(jq -er '.inbounds[] | select(.tag == "hy2-sb") | .listen' "$SB_CONFIG" 2>/dev/null); then
    red "读取现有监听地址失败，本次未启用"
    readp "按回车返回可选功能..."
    return 1
  fi
  echo
  green "启用 Shadowsocks-2022 入口（TCP 备用入口，需自行放行其 TCP 端口）"
  while true; do
    choose_ss_port || return 1
    password=$(generate_ss_password) || password=
    if ! valid_ss_password "$password"; then
      red "生成Shadowsocks-2022密钥失败"
      readp "按回车返回可选功能..."
      return 1
    fi
    if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
      red "创建候选配置失败，原配置未修改"
      readp "按回车返回可选功能..."
      return 1
    fi
    if ! ss_entry_candidate_with_inbound "$candidate" "$port" "$password" "$listen_addr" ||
       ! chmod 600 "$candidate"; then
      rm -f "$candidate"
      red "生成候选配置失败，原配置未修改"
      readp "按回车重新输入，输入0返回可选功能：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      refresh_share_files_after_change || true
      green "Shadowsocks-2022 入口已启用：端口 ${port}/tcp"
      yellow "密钥不可推导，丢失只能重签；协议用时间戳抗重放，请确保本机 NTP 正常"
      yellow "请自行在系统防火墙和VPS厂商安全组放行 ${port}/tcp"
      readp "按回车返回可选功能..."
      return 0
    else
      commit_status=$?
    fi
    if [[ $commit_status -eq 2 ]]; then
      red "启用失败且自动回滚失败，请先检查服务和备份配置"
      readp "按回车返回可选功能..."
      return 2
    fi
    red "启用失败，原配置未修改或已恢复"
    readp "按回车重新输入，输入0返回可选功能：" retry || return 1
    [[ $retry == 0 ]] && return 1
  done
}

disable_ss_entry(){
  local candidate commit_status
  if ! sbactive; then
    readp "按回车返回可选功能..."
    return 1
  fi
  if ! ss_entry_is_enabled; then
    yellow "Shadowsocks-2022 入口当前未启用，无需停用"
    readp "按回车返回可选功能..."
    return 0
  fi
  echo
  yellow "停用后使用这个入口的客户端会立即连不上，分享文件与客户端配置也会去掉它"
  if ! confirm_yes "确认停用 Shadowsocks-2022 入口？输入 YES/y 确认（其他输入取消）："; then
    yellow "已取消，未做任何修改"
    readp "按回车返回可选功能..."
    return 0
  fi
  if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
    red "创建候选配置失败，原配置未修改"
    readp "按回车返回可选功能..."
    return 1
  fi
  if ! ss_entry_candidate_without_inbound "$candidate" || ! chmod 600 "$candidate"; then
    rm -f "$candidate"
    red "生成候选配置失败，原配置未修改"
    readp "按回车返回可选功能..."
    return 1
  fi
  if commit_config "$candidate"; then
    refresh_share_files_after_change || true
    green "Shadowsocks-2022 入口已停用"
    readp "按回车返回可选功能..."
    return 0
  else
    commit_status=$?
  fi
  if [[ $commit_status -eq 2 ]]; then
    red "停用失败且自动回滚失败，请先检查服务和备份配置"
    readp "按回车返回可选功能..."
    return 2
  fi
  red "停用失败，原配置未修改或已恢复"
  readp "按回车返回可选功能..."
  return 1
}

change_ss_port(){
  local current nport port candidate retry commit_status
  if ! sbactive; then
    readp "按回车返回可选功能..."
    return 1
  fi
  if ! current=$(ss_entry_port); then
    yellow "Shadowsocks-2022 入口当前未启用，请先用【1】启用"
    readp "按回车返回可选功能..."
    return 0
  fi
  echo
  green "当前 Shadowsocks-2022 端口：$current/tcp"
  while true; do
    readp "请输入新Shadowsocks-2022端口 (1-65535，留空随机10000-65535): " nport || return 1
    port="$nport"
    chooseport tcp || continue
    if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
      red "创建端口候选配置失败，原配置未修改"
      readp "按回车返回可选功能..."
      return 1
    fi
    if ! jq --argjson p "$port" '
      if ([.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb")] | length) != 1
      then error("ss-sb inbound missing or duplicated")
      else (.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb") | .listen_port) = $p end
    ' "$SB_CONFIG" > "$candidate" || \
      ! jq -e --argjson p "$port" '[.inbounds[] | select(.type == "shadowsocks" and .tag == "ss-sb" and .listen_port == $p)] | length == 1' "$candidate" >/dev/null; then
      rm -f "$candidate"
      red "生成端口候选配置失败，原配置未修改"
      readp "按回车重新输入，输入0返回可选功能：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      refresh_share_files_after_change || true
      green "Shadowsocks-2022端口修改成功：$port"
      yellow "请自行在系统防火墙和VPS厂商安全组放行 ${port}/tcp"
      readp "按回车返回可选功能..."
      return 0
    else
      commit_status=$?
    fi
    if [[ $commit_status -eq 2 ]]; then
      red "端口修改失败且自动回滚失败，请先检查服务和备份配置"
      readp "按回车返回可选功能..."
      return 2
    fi
    red "端口修改失败，原配置未修改或已恢复"
    readp "按回车重新输入，输入0返回可选功能：" retry || return 1
    [[ $retry == 0 ]] && return 1
  done
}

manage_ss_entry(){
  local choice port
  while true; do
    echo
    green "Shadowsocks-2022 入口"
    if port=$(ss_entry_port); then
      green "当前状态：${yellow}已启用${green}（TCP 端口 ${port}）"
    else
      green "当前状态：${yellow}未启用${green}"
    fi
    yellow "这是一个可选的 TCP 备用入口；默认不安装，启用后需自行放行其 TCP 端口"
    green "1：启用（默认随机端口，可选自定义）"
    green "2：停用"
    green "3：更改端口"
    green "4：更改密钥"
    green "0：返回可选功能"
    readp "请选择【0-4】：" choice || return 1
    case "$choice" in
      1) enable_ss_entry ;;
      2) disable_ss_entry ;;
      3) change_ss_port ;;
      4) change_ss_password ;;
      ""|0) return 0 ;;
      *) red "请输入0、1、2、3或4" ;;
    esac
  done
}

manage_optional_features(){
  local choice port
  while true; do
    echo
    green "可选功能"
    if port=$(ss_entry_port); then
      green "1：Shadowsocks-2022 入口 ${yellow}已启用（端口 $port）${plain}"
    else
      green "1：Shadowsocks-2022 入口 ${yellow}未启用${plain}"
    fi
    if load_relay_settings; then
      green "2：上游/中转 ${yellow}${relay_server}:${relay_port}${plain}"
    else
      green "2：上游/中转 ${yellow}未配置${plain}"
    fi
    green "0：返回主菜单"
    readp "请选择【0-2】：" choice || return 1
    case "$choice" in
      1) manage_ss_entry ;;
      2) manage_relay ;;
      ""|0) return 0 ;;
      *) red "请输入0、1或2" ;;
    esac
  done
}
