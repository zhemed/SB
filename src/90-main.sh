# sb-module: 90-main
# Installation main flow
install_singbox(){
  local key_pair private_key public_key short_id shortcut_ready=0
  if service_name_conflict; then
    red "检测到不属于本脚本的同名 $SB_SERVICE 服务，请先自行处理服务名冲突"
    return 1
  fi
  if is_installed; then
    red "已安装sb，无需重复安装"
    return 1
  fi
  if managed_install_data_present; then
    red "检测到现有或残缺的sb配置数据，拒绝无备份覆盖"
    yellow "请使用菜单[2]修复；残缺安装可在确认后清理并重新安装"
    return 1
  fi
  if [[ -f /etc/systemd/system/sing-box.service || -f /etc/init.d/sing-box || -d /etc/s-box ]]; then
    yellow "检测到旧版或其他 sing-box 安装。sb将使用独立的 $SB_DIR 和 $SB_SERVICE 服务，不会修改旧实例。"
    yellow "请确保两套实例没有使用相同端口。"
    sleep 2
  fi
  if service_exists && ! cleanup_service; then
    red "清理残留的sb服务失败，请先手动检查"
    return 1
  fi
  INSTALL_TRANSACTION_ACTIVE=1
  prepare_managed_directory || { abort_install_transaction; return 1; }
  if [[ ! -f $SB_DIR/.deps_ok ]] || ! dependencies_ready; then
    install_dependencies || { abort_install_transaction; return 1; }
  fi
  v6only
  inssb || { abort_install_transaction; return 1; }
  inscertificate || { abort_install_transaction; return 1; }
  insport || { abort_install_transaction; return 1; }
  sleep 2
  echo
  blue "Vless-reality相关key与id将自动生成……"
  key_pair=$("$SB_BIN" generate reality-keypair 2>/dev/null)
  if [[ -z "$key_pair" ]]; then
    red "生成reality密钥失败，请检查sing-box内核是否正常"
    abort_install_transaction
    return 1
  fi
  private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
  public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
  if [[ -z $private_key || -z $public_key ]]; then
    red "解析Reality密钥失败"
    abort_install_transaction
    return 1
  fi
  if ! printf '%s\n' "$public_key" > "$SB_DIR/public.key" ||
     ! chmod 600 "$SB_DIR/public.key"; then
    red "保存Reality公钥失败"
    abort_install_transaction
    return 1
  fi
  short_id=$("$SB_BIN" generate rand --hex 4 2>/dev/null)
  if [[ ! $short_id =~ ^[0-9A-Fa-f]{8}$ ]]; then
    red "生成Reality short_id失败"
    abort_install_transaction
    return 1
  fi
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "五、生成配置文件和启动服务"
  inssbjson || { abort_install_transaction; return 1; }
  sbservice || { abort_install_transaction; return 1; }
  if ! sbactive; then
    abort_install_transaction
    return 1
  fi
  yellow "安全提示：SOCKS5本身不加密，仅适合可信链路；脚本已使用独立密码并禁止SOCKS5 UDP"
  yellow "请自行在系统防火墙和VPS厂商安全组放行 ${port_vl_re}/tcp、${port_socks5}/tcp 与 ${port_hy2}/udp"
  if [[ ${use_acme_cert:-0} -eq 1 ]]; then
    setup_acme_renew_cron || yellow "ACME 自动续期任务设置失败，请手动检查 root crontab"
  fi
  if update_shortcut; then
    shortcut_ready=1
  else
    yellow "当前运行方式没有可复制的本地脚本，未创建快捷方式 $SHORTCUT"
  fi
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  if [[ $shortcut_ready -eq 1 ]]; then
    blue "sb安装成功，Sing-box固定版本 v${CORE_VERSION}，快捷方式: sb"
  else
    blue "sb安装成功，Sing-box固定版本 v${CORE_VERSION}"
  fi
  cronsb || yellow "每日自动重启定时任务设置失败，请手动检查crontab"
  echo
  if ipuuid; then
    sbshare || yellow "节点文件生成失败，请通过菜单[3]重试"
  else
    yellow "公网IP检测失败，服务已启动，但暂未生成分享链接"
  fi
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  blue "可选择菜单 [3] 刷新并显示所有协议配置及分享链接"
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
  INSTALL_TRANSACTION_ACTIVE=0
}

repair_singbox(){
  local shortcut_ready=0 repair_choice reinstall_status
  if ! managed_directory_is_owned || ! managed_install_data_present; then
    red "未检测到可修复的sb安装数据"
    readp "按回车返回主菜单..."
    return 1
  fi
  if service_name_conflict; then
    red "检测到不属于sb.sh的同名服务，拒绝修复"
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! installed_config_is_valid; then
    red "现有内核或配置未通过 Sing-box v${CORE_VERSION} 检查，无法直接修复"
    if [[ -x $SB_BIN && -s $SB_CONFIG ]]; then
      "$SB_BIN" check -c "$SB_CONFIG" || true
    fi
    yellow "缺失或损坏的配置无法安全还原；继续会删除本脚本管理的 $SB_DIR 并重新安装"
    yellow "请先备份需要保留的数据"
    yellow "1：清理残缺安装并重新安装"
    yellow "0：取消"
    readp "请选择【0-1】：" repair_choice || return 1
    if [[ $repair_choice != 1 ]]; then
      return 1
    fi
    if ! cleanup_incomplete_install; then
      red "残缺安装清理失败，修复已中止"
      readp "按回车返回主菜单..."
      return 1
    fi
    green "残缺安装已清理，现在重新进入安装流程"
    install_singbox
    reinstall_status=$?
    readp "按回车返回主菜单..."
    return "$reinstall_status"
  fi
  if service_exists; then
    if ! restartsb >/dev/null 2>&1 || ! service_is_active; then
      cleanup_service || {
        red "清理损坏的服务定义失败，修复已中止"
        readp "按回车返回主菜单..."
        return 1
      }
      sbservice || {
        readp "按回车返回主菜单..."
        return 1
      }
    fi
  elif ! sbservice; then
    readp "按回车返回主菜单..."
    return 1
  fi
  if update_shortcut; then
    shortcut_ready=1
  else
    yellow "服务已恢复，但快捷方式 $SHORTCUT 更新失败"
  fi
  ensure_acme_renew_cron || yellow "服务已恢复，但ACME续期状态需要手动检查"
  cronsb || yellow "服务已恢复，但每日重启任务设置失败"
  if [[ $shortcut_ready -eq 1 ]]; then
    green "sb服务修复成功，快捷方式: sb"
  else
    green "sb服务修复成功"
  fi
  readp "按回车返回主菜单..."
}

# Management menu
menu(){
  local Input insV sb_ver status_text status_color
  while true; do
    clear
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "${bblue} ░██     ░██      ░██ ██ ██         ░█${plain}█   ░██     ░██   ░██     ░█${red}█   ░██${plain}  "
    echo -e "${bblue}  ░██   ░██      ░██    ░░██${plain}        ░██  ░██      ░██  ░██${red}      ░██  ░██${plain}   "
    echo -e "${bblue}   ░██ ░██      ░██ ${plain}                ░██ ██        ░██ █${red}█        ░██ ██  ${plain}   "
    echo -e "${bblue}     ░██        ░${plain}██    ░██ ██       ░██ ██        ░█${red}█ ██        ░██ ██  ${plain}  "
    echo -e "${bblue}     ░██ ${plain}        ░██    ░░██        ░██ ░██       ░${red}██ ░██       ░██ ░██ ${plain}  "
    echo -e "${bblue}     ░█${plain}█          ░██ ██ ██         ░██  ░░${red}██     ░██  ░░██     ░██  ░░██ ${plain}  "
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    insV="$sb_version"
    sb_ver=$([[ -x $SB_BIN ]] && "$SB_BIN" version 2>/dev/null | awk '/version/{print $NF}')
    [[ -z $sb_ver ]] && sb_ver="未安装"
    status_text=$(service_is_active && [[ -s $SB_CONFIG ]] && echo "运行中" || echo "未运行")
    status_color=$([[ "$status_text" = "运行中" ]] && echo "$green" || echo "$yellow")
    echo -e "  版本: ${green}${insV}${plain}  |  Sing-box: ${green}${sb_ver}${plain}  |  状态: ${status_color}${status_text}${plain}"
    v4v6
    [[ -n $v4 ]] && echo -e "  IPV4: ${blue}${v4}${plain}${v4dq:+ (${v4dq})}"
    [[ -n $v6 ]] && echo -e "  IPV6: ${blue}${v6}${plain}${v6dq:+ (${v6dq})}"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green " 1. 安装"
    green " 2. 修复"
    green " 3. 查看节点配置"
    green " 4. 证书管理"
    green " 5. 更改SNI域名"
    green " 6. 更改端口"
    green " 7. 更改协议凭据"
    green " 8. 切换IP优先级"
    green " 9. 卸载"
    green " 0. 退出脚本"
    echo
    readp "请输入数字 [0-9]: " Input || exit 0
    case "$Input" in
      1)
        if is_installed; then
          red "sb已安装，请使用菜单[2]检查或修复服务"
          readp "按回车返回主菜单..."
        elif managed_install_data_present; then
          red "检测到残缺安装，请使用菜单[2]修复"
          readp "按回车返回主菜单..."
        else
          install_singbox
          readp "按回车返回主菜单..."
        fi
        ;;
      2)
        repair_singbox
        ;;
      3)
        if is_installed; then
          sbshare || red "节点配置生成失败，请检查上方错误"
          readp "按回车返回主菜单..."
        else
          red "请先安装 Sing-box"
          sleep 1
        fi
        ;;
      4|5|6|7|8)
        if ! is_installed; then
          red "请先安装或修复 Sing-box"
          sleep 1
        else
          case "$Input" in
            4) change_cert_mode ;;
            5) change_vl_sni ;;
            6) change_ports ;;
            7) change_credentials ;;
            8) switch_ip_priority ;;
          esac
        fi
        ;;
      9)
        if is_installed || service_exists || managed_directory_is_owned || [[ -x $SB_BIN || -s $SB_CONFIG ]]; then
          uninstall
        else
          red "未检测到 sb 安装"
          sleep 1
        fi
        ;;
      0|"") exit 0 ;;
      *) red "请输入正确数字"; sleep 1 ;;
    esac
  done
}

# Make/update shortcut
# sb-entrypoint
prepare_runtime_state || exit 1

handle_install_interrupt(){
  echo
  if [[ ${INSTALL_TRANSACTION_ACTIVE:-0} -eq 1 ]]; then
    abort_install_transaction || true
  fi
  exit 130
}
trap handle_install_interrupt INT TERM HUP

if is_installed; then
  update_shortcut >/dev/null 2>&1 || true
  ensure_acme_renew_cron || yellow "ACME续期自检未通过，请处理上方提示"
fi

# Start
menu
