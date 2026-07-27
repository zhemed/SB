# sb-module: 70-management
# Certificate management
change_cert_mode(){
  local current_key c_c d_d candidate acme_name menu retry commit_status
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  echo
  green "证书管理"
  if ! current_key=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.key_path' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前证书失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi

  while true; do
    c_c=
    d_d=
    if [[ $current_key == "$SB_DIR/private.key" ]]; then
      echo "当前证书: 自签bing证书"
      if acme_name=$(detect_acme_identity); then
        while true; do
          green "1：切换为已有 ACME 域名证书 ($acme_name)"
          green "2：通过 Cloudflare 重新申请并切换 ACME 证书"
          yellow "   重新申请会删除旧 ACME 状态，请避免频繁签发"
          green "0：返回主菜单"
          readp "请选择【0-2】：" menu || return 1
          case "$menu" in
            1)
              if cert_acme; then
                c_c="$ACME_CERT"
                d_d="$ACME_KEY"
                break
              fi
              red "已有ACME证书不可用，请重新选择"
              ;;
            2)
              if issue_cloudflare_certificate; then
                c_c="$ACME_CERT"
                d_d="$ACME_KEY"
                break
              fi
              red "ACME证书申请失败，请重新选择"
              ;;
            ""|0) return 0 ;;
            *) red "请输入0、1或2" ;;
          esac
        done
      else
        while true; do
          green "1：通过 Cloudflare 申请并切换 ACME 域名证书"
          green "0：返回主菜单"
          readp "请选择【0-1】：" menu || return 1
          case "$menu" in
            1)
              if issue_cloudflare_certificate; then
                c_c="$ACME_CERT"
                d_d="$ACME_KEY"
                break
              fi
              red "ACME证书申请失败，请重新选择"
              ;;
            ""|0) return 0 ;;
            *) red "请输入0或1" ;;
          esac
        done
      fi
    elif [[ $current_key == "$ACME_KEY" ]]; then
      acme_name=$(detect_acme_identity 2>/dev/null || echo "身份校验失败")
      echo "当前证书: ACME 域名证书 ($acme_name)"
      while true; do
        green "1：切换为自签bing证书"
        green "0：返回主菜单"
        yellow "如需更换域名或 Token，请先切换为自签证书，再进入本菜单重新申请"
        readp "请选择【0-1】：" menu || return 1
        case "$menu" in
          1)
            c_c="$SB_DIR/cert.pem"
            d_d="$SB_DIR/private.key"
            break
            ;;
          ""|0) return 0 ;;
          *) red "请输入0或1" ;;
        esac
      done
    else
      yellow "当前配置使用未知证书路径：$current_key"
      while true; do
        green "1：切换为自签bing证书"
        green "2：申请并切换为 Cloudflare ACME 证书"
        green "0：返回主菜单"
        readp "请选择【0-2】：" menu || return 1
        case "$menu" in
          1)
            c_c="$SB_DIR/cert.pem"
            d_d="$SB_DIR/private.key"
            break
            ;;
          2)
            if issue_cloudflare_certificate; then
              c_c="$ACME_CERT"
              d_d="$ACME_KEY"
              break
            fi
            red "ACME证书申请失败，请重新选择"
            ;;
          ""|0) return 0 ;;
          *) red "请输入0、1或2" ;;
        esac
      done
    fi

    if [[ ! -s $c_c || ! -s $d_d ]]; then
      red "目标证书或私钥不存在，原配置未修改"
      readp "按回车重新选择，输入0返回主菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
      red "创建证书候选配置失败，原配置未修改"
      readp "按回车重试，输入0返回主菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if ! jq --arg cert "$c_c" --arg key "$d_d" '
      if ([.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb")] | length) != 1
      then error("hy2 inbound missing or duplicated")
      else (.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.certificate_path) = $cert |
           (.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.key_path) = $key
      end
    ' "$SB_CONFIG" > "$candidate" || \
      ! jq -e --arg cert "$c_c" --arg key "$d_d" '[.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb" and .tls.certificate_path == $cert and .tls.key_path == $key)] | length == 1' "$candidate" >/dev/null; then
      rm -f "$candidate"
      red "生成证书候选配置失败，原配置未修改"
      readp "按回车重新选择，输入0返回主菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      if [[ $d_d == "$ACME_KEY" ]]; then
        setup_acme_renew_cron || yellow "证书已切换，但自动续期任务设置失败，请手动检查 root crontab"
      elif ! remove_acme_renew_cron; then
        yellow "证书已切换，但 ACME 自动续期任务清理失败，请手动检查 root crontab"
      fi
      refresh_share_files_after_change || true
      green "证书模式切换成功"
      readp "按回车返回主菜单..."
      return 0
    else
      commit_status=$?
    fi
    if [[ $commit_status -eq 2 ]]; then
      red "证书切换失败且自动回滚失败，请先检查服务和备份配置"
      readp "按回车返回主菜单..."
      return 2
    fi
    red "证书切换失败，原配置未修改或已恢复"
    readp "按回车重新选择，输入0返回主菜单：" retry || return 1
    [[ $retry == 0 ]] && return 1
  done
}

# Change VL reality SNI
change_vl_sni(){
  local current_sni new_sni candidate retry commit_status
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  echo
  if ! current_sni=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.server_name' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前SNI失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  green "当前VL reality SNI域名: $current_sni"
  while true; do
    readp "请输入新的SNI域名 (回车使用apple.com，输入0返回主菜单): " new_sni || return 1
    [[ $new_sni == 0 ]] && return 0
    new_sni=${new_sni:-apple.com}
    if ! valid_hostname "$new_sni"; then
      red "SNI必须是合法域名，例如 apple.com"
      yellow "请重新输入SNI域名"
      continue
    fi
    if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
      red "创建SNI候选配置失败，原配置未修改"
      readp "按回车重试，输入0返回主菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if ! jq --arg sni "$new_sni" '
      if ([.inbounds[] | select(.type == "vless" and .tag == "vless-sb")] | length) != 1
      then error("vless inbound missing or duplicated")
      else (.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.server_name) = $sni |
           (.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.reality.handshake.server) = $sni
      end
    ' "$SB_CONFIG" > "$candidate" || \
      ! jq -e --arg sni "$new_sni" '[.inbounds[] | select(.type == "vless" and .tag == "vless-sb" and .tls.server_name == $sni and .tls.reality.handshake.server == $sni)] | length == 1' "$candidate" >/dev/null; then
      rm -f "$candidate"
      red "生成SNI候选配置失败，原配置未修改"
      readp "按回车重新输入，输入0返回主菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      refresh_share_files_after_change || true
      green "VL reality SNI域名修改成功：$new_sni"
      readp "按回车返回主菜单..."
      return 0
    fi
    commit_status=$?
    if [[ $commit_status -eq 2 ]]; then
      red "SNI修改失败且自动回滚失败，请先检查服务和备份配置"
      readp "按回车返回主菜单..."
      return 2
    fi
    red "SNI修改失败，原配置未修改或已恢复"
    readp "按回车重新输入，输入0返回主菜单：" retry || return 1
    [[ $retry == 0 ]] && return 1
  done
}

# Change ports
change_ports(){
  local nport port candidate menu retry commit_status vl_port socks_port hy2_port port_vl_re port_socks5 port_hy2
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! vl_port=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null) || \
     ! socks_port=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null) || \
     ! hy2_port=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前端口失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  port_vl_re=$vl_port
  port_socks5=$socks_port
  port_hy2=$hy2_port
  echo
  while true; do
    green "更改端口"
    green "1：Vless-reality端口 ${yellow}当前: $vl_port${plain}"
    green "2：Hysteria2主端口 ${yellow}当前: $hy2_port${plain}"
    green "3：SOCKS5端口 ${yellow}当前: $socks_port${plain}"
    green "0：返回主菜单"
    readp "请选择【0-3】：" menu || return 1
    case "$menu" in
      ""|0) return 0 ;;
      1)
        readp "请输入新端口 (1-65535，留空随机10000-65535): " nport || return 1
        port="$nport"
        chooseport tcp "$socks_port" || continue
        if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
          red "创建端口候选配置失败，原配置未修改"
          readp "按回车重试，输入0返回主菜单：" retry || return 1
          [[ $retry == 0 ]] && return 1
          continue
        fi
        if ! jq --argjson p "$port" '
          if ([.inbounds[] | select(.type == "vless" and .tag == "vless-sb")] | length) != 1
          then error("vless inbound missing or duplicated")
          else (.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .listen_port) = $p end
        ' "$SB_CONFIG" > "$candidate" || \
          ! jq -e --argjson p "$port" '[.inbounds[] | select(.type == "vless" and .tag == "vless-sb" and .listen_port == $p)] | length == 1' "$candidate" >/dev/null; then
          rm -f "$candidate"
          red "生成端口候选配置失败，原配置未修改"
          readp "按回车重新输入，输入0返回主菜单：" retry || return 1
          [[ $retry == 0 ]] && return 1
          continue
        fi
        if commit_config "$candidate"; then
          refresh_share_files_after_change || true
          green "Vless-reality端口修改成功：$port"
          yellow "请自行在系统防火墙和VPS厂商安全组放行 ${port}/tcp"
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
      2)
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
      3)
        readp "请输入新SOCKS5端口 (1-65535，留空随机10000-65535): " nport || return 1
        port="$nport"
        chooseport tcp "$vl_port" || continue
        if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
          red "创建端口候选配置失败，原配置未修改"
          readp "按回车重试，输入0返回主菜单：" retry || return 1
          [[ $retry == 0 ]] && return 1
          continue
        fi
        if ! jq --argjson p "$port" '
          if ([.inbounds[] | select(.type == "socks" and .tag == "socks5-sb")] | length) != 1
          then error("socks5 inbound missing or duplicated")
          else (.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .listen_port) = $p end
        ' "$SB_CONFIG" > "$candidate" || \
          ! jq -e --argjson p "$port" '[.inbounds[] | select(.type == "socks" and .tag == "socks5-sb" and .listen_port == $p)] | length == 1' "$candidate" >/dev/null; then
          rm -f "$candidate"
          red "生成端口候选配置失败，原配置未修改"
          readp "按回车重新输入，输入0返回主菜单：" retry || return 1
          [[ $retry == 0 ]] && return 1
          continue
        fi
        if commit_config "$candidate"; then
          refresh_share_files_after_change || true
          green "SOCKS5端口修改成功：$port"
          yellow "请自行在系统防火墙和VPS厂商安全组放行 ${port}/tcp"
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
        red "请输入0、1、2或3"
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
  if ! olduuid=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .users[0].uuid' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前UUID失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  echo
  green "当前VLESS/Hysteria2 UUID（密码）：$olduuid"
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
      if ([.inbounds[] | select(.type == "vless" and .tag == "vless-sb")] | length) != 1 or
         ([.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb")] | length) != 1
      then error("required inbound missing or duplicated")
      else (.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .users[0].uuid) = $uuid |
           (.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .users[0].password) = $uuid
      end
    ' "$SB_CONFIG" > "$candidate" || \
      ! jq -e --arg uuid "$uuid" '([.inbounds[] | select(.type == "vless" and .tag == "vless-sb" and .users[0].uuid == $uuid)] | length == 1) and ([.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb" and .users[0].password == $uuid)] | length == 1)' "$candidate" >/dev/null; then
      rm -f "$candidate"
      red "生成UUID候选配置失败，原配置未修改"
      readp "按回车重新输入，输入0返回凭据菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      refresh_share_files_after_change || true
      green "VLESS/Hysteria2 UUID（密码）修改成功：${uuid}"
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

change_socks_password(){
  local current_password new_password candidate choice retry commit_status
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! current_password=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .users[0].password' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前SOCKS5密码失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  echo
  green "当前SOCKS5用户名：$SOCKS_USERNAME"
  green "当前SOCKS5独立密码：$current_password"
  while true; do
    readp "输入新密码（16-128位安全字符，回车随机生成，输入0返回凭据菜单）：" choice || return 1
    [[ $choice == 0 ]] && return 0
    if [[ -z $choice ]]; then
      new_password=$(openssl rand -hex 24 2>/dev/null || true)
    else
      new_password=$choice
    fi
    if ! valid_socks_password "$new_password"; then
      red "SOCKS5密码必须为16-128位，仅可使用字母、数字、点、下划线、波浪号和连字符"
      continue
    fi
    if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
      red "创建SOCKS5密码候选配置失败，原配置未修改"
      readp "按回车重试，输入0返回凭据菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if ! jq --arg password "$new_password" --arg username "$SOCKS_USERNAME" '
      if ([.inbounds[] | select(.type == "socks" and .tag == "socks5-sb")] | length) != 1
      then error("socks5 inbound missing or duplicated")
      else (.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .users[0].username) = $username |
           (.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .users[0].password) = $password
      end
    ' "$SB_CONFIG" > "$candidate" || \
      ! jq -e --arg password "$new_password" --arg username "$SOCKS_USERNAME" '([.inbounds[] | select(.type == "socks" and .tag == "socks5-sb" and .users[0].username == $username and .users[0].password == $password)] | length) == 1' "$candidate" >/dev/null; then
      rm -f "$candidate"
      red "生成SOCKS5密码候选配置失败，原配置未修改"
      readp "按回车重新输入，输入0返回凭据菜单：" retry || return 1
      [[ $retry == 0 ]] && return 1
      continue
    fi
    if commit_config "$candidate"; then
      refresh_share_files_after_change || true
      green "SOCKS5独立密码修改成功：${new_password}"
      readp "按回车返回凭据菜单..."
      return 0
    else
      commit_status=$?
    fi
    if [[ $commit_status -eq 2 ]]; then
      red "SOCKS5密码修改失败且自动回滚失败，请先检查服务和备份配置"
      readp "按回车返回凭据菜单..."
      return 2
    fi
    red "SOCKS5密码修改失败，原配置未修改或已恢复"
    readp "按回车重新输入，输入0返回凭据菜单：" retry || return 1
    [[ $retry == 0 ]] && return 1
  done
}

change_credentials(){
  local choice
  while true; do
    echo
    green "凭据管理"
    green "1：更改VLESS/Hysteria2 UUID（密码）"
    green "2：更改SOCKS5独立密码"
    green "0：返回主菜单"
    readp "请选择【0-2】：" choice || return 1
    case "$choice" in
      1) changeuuid ;;
      2) change_socks_password ;;
      ""|0) return 0 ;;
      *) red "请输入0、1或2" ;;
    esac
  done
}
