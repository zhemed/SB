# sb-module: 50-client-output
save_server_ip(){
  local ip=$1 server_value client_value
  if valid_ipv4 "$ip"; then
    server_value=$ip
    client_value=$ip
  elif valid_ipv6 "$ip"; then
    server_value="[$ip]"
    client_value=$ip
  else
    return 1
  fi
  atomic_write_private_text "$SB_DIR/server_ip.log" "$server_value" &&
    atomic_write_private_text "$SB_DIR/server_ipcl.log" "$client_value"
}

ipuuid(){
  local menu
  v4v6_bg
  if [[ -n $v4 && -n $v6 ]]; then
    green "调整IPv4/IPV6配置输出"
    yellow "1：刷新本地IP，使用IPV4配置输出 (回车默认) "
    yellow "2：刷新本地IP，使用IPV6配置输出"
    while true; do
      readp "请选择【1-2】：" menu || return 1
      case "$menu" in
        ""|1)
          v4v6_refresh >/dev/null 2>&1 || true
          # 探测失败就用缓存兜底（原来会把缓存里的值清掉，然后原地打转）
          [[ -n $v4 ]] || { read_ip_cache || true; }
          if [[ -z $v4 ]]; then
            red "未能获取公网IPv4地址，请检查本机网络后重试"
            readp "按回车返回主菜单..."
            return 1
          fi
          save_server_ip "$v4" || return 1
          break
          ;;
        2)
          v4v6_refresh >/dev/null 2>&1 || true
          [[ -n $v6 ]] || { read_ip_cache || true; }
          if [[ -z $v6 ]]; then
            red "未能获取公网IPv6地址，请检查本机网络后重试"
            readp "按回车返回主菜单..."
            return 1
          fi
          save_server_ip "$v6" || return 1
          break
          ;;
        *) red "请输入1或2" ;;
      esac
    done
  elif [[ -n $v4 ]]; then
    save_server_ip "$v4"
  elif [[ -n $v6 ]]; then
    save_server_ip "$v6"
  else
    red "未能检测到公网IPv4或IPv6地址"
    return 1
  fi
}

refresh_saved_ip(){
  local previous
  previous=
  if managed_regular_file_is_trusted "$SB_DIR/server_ipcl.log"; then
    previous=$(cat "$SB_DIR/server_ipcl.log" 2>/dev/null)
  fi
  v4v6_bg
  if valid_ipv6 "$previous" && [[ -n $v6 ]]; then
    save_server_ip "$v6"
  elif valid_ipv4 "$previous" && [[ -n $v4 ]]; then
    save_server_ip "$v4"
  elif [[ -n $v4 ]]; then
    save_server_ip "$v4"
  elif [[ -n $v6 ]]; then
    save_server_ip "$v6"
  else
    [[ -s $SB_DIR/server_ip.log && -s $SB_DIR/server_ipcl.log ]] &&
      managed_regular_file_is_trusted "$SB_DIR/server_ip.log" &&
      managed_regular_file_is_trusted "$SB_DIR/server_ipcl.log"
  fi
}

result(){
  socks_keep_previous_share=0
  if [[ ! -s $SB_CONFIG ]]; then
    red "配置文件不存在，请先安装"
    return 1
  fi
  if ! refresh_saved_ip; then
    red "没有可用的公网IP，拒绝生成无效节点"
    return 1
  fi
  server_ip=$(cat "$SB_DIR/server_ip.log" 2>/dev/null)
  server_ipcl=$(cat "$SB_DIR/server_ipcl.log" 2>/dev/null)
  if valid_ipv4 "$server_ipcl"; then
    if [[ $server_ip != "$server_ipcl" ]]; then
      red "两个公网IP文件不一致，请用菜单[3]重新检测"
      return 1
    fi
  elif valid_ipv6 "$server_ipcl"; then
    if [[ $server_ip != "[$server_ipcl]" ]]; then
      red "公网IP文件的 IPv6 格式不一致，请用菜单[3]重新检测"
      return 1
    fi
  else
    red "保存的公网IP格式无效"
    return 1
  fi
  if ! uuid=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .users[0].password' "$SB_CONFIG" 2>/dev/null); then
    red "服务端配置里读不到 Hysteria2 口令，无法生成节点"
    return 1
  fi
  # 入口是否存在按入站本身判定（与菜单里的判定同口径）：口令读不到是配置被改坏，
  # 必须报出来，不能静默当"没启用"——那会把还能用的 socks5.txt 一起删掉。
  socks_enabled=0
  socks_port=
  socks_password=
  if jq -e '[.inbounds[] | select(.type == "socks" and .tag == "socks5-sb")] | length == 1' "$SB_CONFIG" >/dev/null 2>&1; then
    if ! socks_password=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .users[0].password' "$SB_CONFIG" 2>/dev/null) ||
       ! socks_port=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null); then
      # 入站还在、字段被改坏：保留已生成的 socks5.txt，只跳过它，Hysteria2 节点照常出。
      red "SOCKS5 入口缺少口令或端口，本次不生成它的节点；请用菜单[8]重设一次"
      socks_password=
      socks_port=
      socks_keep_previous_share=1
    else
      socks_enabled=1
    fi
  fi
  if ! hy2_port=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null); then
    red "服务端配置里读不到 Hysteria2 端口，无法生成节点"
    return 1
  fi
  if ! hy2_sniname=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.key_path' "$SB_CONFIG" 2>/dev/null); then
    red "服务端配置里读不到 Hysteria2 证书路径，无法生成节点"
    return 1
  fi
  if ! valid_uuid "$uuid" || ! valid_port "$hy2_port"; then
    red "服务端配置中的节点参数不完整或格式无效"
    return 1
  fi
  if [[ $socks_enabled -eq 1 ]] &&
     { ! valid_port "$socks_port" || ! valid_socks_password "$socks_password"; }; then
    red "服务端配置中的 SOCKS5 节点参数无效"
    return 1
  fi
  hy2_certificate_json=
  hy2_clash_ca=
  if [[ "$hy2_sniname" = "$SB_DIR/private.key" ]]; then
    if ! certificate_time_valid "$SB_DIR/cert.pem" ||
       ! certificate_key_matches "$SB_DIR/cert.pem" "$SB_DIR/private.key" ||
       ! certificate_identity_matches "$SB_DIR/cert.pem" www.bing.com; then
      red "自签证书校验失败，不能生成安全的Hysteria2客户端配置"
      return 1
    fi
    SHA256=$(openssl x509 -in "$SB_DIR/cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')
    if [[ ! $SHA256 =~ ^[0-9A-Fa-f]{64}$ ]]; then
      red "读取自签证书指纹失败，不能生成节点"
      return 1
    fi
    if ! hy2_certificate_json=$(jq -Rs . < "$SB_DIR/cert.pem") || [[ -z $hy2_certificate_json ]]; then
      red "读取自签证书内容失败，不能生成节点"
      return 1
    fi
    hy2_clash_ca="  ca-str: |"$'\n'"$(sed 's/^/    /' "$SB_DIR/cert.pem")"
    atomic_write_private_text "$SB_DIR/SHA256.txt" "$SHA256" || return 1
    hy2_name=www.bing.com
    sb_hy2_ip=$server_ip
    cl_hy2_ip=$server_ipcl
  else
    SHA256=""
    if [[ -e $SB_DIR/SHA256.txt ]]; then
      rm -f -- "$SB_DIR/SHA256.txt" || yellow "旧的指纹文件 $SB_DIR/SHA256.txt 无法删除，请手动检查"
    fi
    if ! ym=$(detect_acme_identity); then
      red "Acme证书身份无法确认，不能生成Hysteria2节点"
      return 1
    fi
    write_acme_identity "$ym" || return 1
    hy2_name=$ym
    sb_hy2_ip=$server_ip
    cl_hy2_ip=$server_ipcl
  fi
}


reshy2(){
  local output=${1:-$SB_DIR/hy2.txt}
  echo
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  hy2_link="hysteria2://$uuid@$sb_hy2_ip:$hy2_port?security=tls&alpn=h3&insecure=0&allowInsecure=0&sni=$hy2_name${SHA256:+&pinSHA256=$SHA256}#hy2-$hostname"
  printf '%s\n' "$hy2_link" > "$output" || return 1
  red "🚀【 Hysteria-2 】节点信息如下：" && sleep 2
  echo
  echo "分享链接【v2rayn、v2rayng、nekobox、小火箭shadowrocket】"
  echo -e "${yellow}$hy2_link${plain}"
  echo
  echo "二维码"
  qrencode -o - -t ANSIUTF8 "$hy2_link" || return 1
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
}

ressocks5(){
  local output=${1:-$SB_DIR/socks5.txt}
  echo
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  socks5_link="socks5://$SOCKS_USERNAME:$socks_password@$server_ip:$socks_port#socks5-$hostname"
  printf '%s\n' "$socks5_link" > "$output" || return 1
  red "🚀【 SOCKS5 】节点信息如下：" && sleep 2
  echo
  echo "分享链接【任意支持 SOCKS5 的程序】"
  echo -e "${yellow}$socks5_link${plain}"
  echo
  echo "二维码"
  qrencode -o - -t ANSIUTF8 "$socks5_link" || return 1
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
}

print_socks_entry_share(){
  local password=$1 path="$SB_DIR/socks5.txt" port=
  echo
  if port=$(socks_entry_port) && [[ -n $port ]] &&
     managed_regular_file_is_trusted "$path" && [[ -s $path ]] &&
     [[ $(cat "$path" 2>/dev/null) == "socks5://$SOCKS_USERNAME:$password@$server_ip:$port#socks5-$hostname" ]]; then
    green "分享链接（已写入 $path，菜单[3]可重看并出二维码）"
    echo -e "${yellow}$(cat "$path" 2>/dev/null)${plain}"
  else
    yellow "分享文件尚未刷新或是旧的（里面可能还是上一个口令），请用菜单[3]重看链接与二维码"
  fi
  green "用户名/密码：$SOCKS_USERNAME / $password"
}

sb_client(){
  local sbox_candidate clash_candidate hy2_certificate_field=
  local socks_outbound_field=
  local socks_selector_member=
  local socks_clash_proxy=
  local socks_clash_member=
  sbox_candidate=$(mktemp "$SB_DIR/.sbox.json.XXXXXX") || return 1
  clash_candidate=$(mktemp "$SB_DIR/.clash.yaml.XXXXXX") || { rm -f "$sbox_candidate"; return 1; }
  if [[ -n $hy2_certificate_json ]]; then
    hy2_certificate_field=$(printf ',\n        "certificate": %s' "$hy2_certificate_json")
  fi
  if [[ $socks_enabled -eq 1 ]]; then
    socks_outbound_field=$(printf '    {\n      "type": "socks",\n      "tag": "socks5-%s",\n      "server": "%s",\n      "server_port": %s,\n      "version": "5",\n      "username": "%s",\n      "password": "%s",\n      "network": "tcp"\n    },\n' \
      "$hostname" "$server_ipcl" "$socks_port" "$SOCKS_USERNAME" "$socks_password") || return 1
    socks_selector_member=$(printf '        "socks5-%s",\n' "$hostname") || return 1
    socks_clash_proxy=$(printf -- '- name: socks5-%s\n  type: socks5\n  server: %s\n  port: %s\n  username: "%s"\n  password: "%s"\n  udp: false\n\n' \
      "$hostname" "$server_ipcl" "$socks_port" "$SOCKS_USERNAME" "$socks_password") || return 1
    socks_clash_member=$(printf '    - socks5-%s\n' "$hostname") || return 1
    socks_outbound_field+=$'\n'
    socks_selector_member+=$'\n'
    socks_clash_proxy+=$'\n\n'
    socks_clash_member+=$'\n'
  fi
  if ! cat > "$sbox_candidate" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "./cache.db",
      "store_fakeip": true
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "ui",
      "default_mode": "Rule"
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "aliDns",
        "address": "https://dns.alidns.com/dns-query",
        "address_resolver": "local"
      },
      {
        "tag": "local",
        "address": "223.5.5.5"
      },
      {
        "tag": "proxyDns",
        "address": "https://dns.google/dns-query",
        "address_resolver": "aliDns",
        "detour": "proxy"
      },
      {
        "tag": "fakeip",
        "address": "fakeip"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-cn",
        "clash_mode": "Rule",
        "server": "aliDns"
      },
      {
        "clash_mode": "Direct",
        "server": "local"
      },
      {
        "clash_mode": "Global",
        "server": "proxyDns"
      },
      {
        "query_type": ["A", "AAAA"],
        "server": "fakeip"
      }
    ],
    "final": "proxyDns",
    "strategy": "prefer_ipv4",
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15",
      "inet6_range": "fc00::/18"
    }
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fd00::1/126"],
      "auto_route": true,
      "strict_route": true,
      "sniff": true,
      "sniff_override_destination": true
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "clash_mode": "Global",
        "outbound": "proxy"
      },
      {
        "rule_set": "geosite-cn",
        "clash_mode": "Rule",
        "outbound": "direct"
      },
      {
        "rule_set": "geoip-cn",
        "clash_mode": "Rule",
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "clash_mode": "Rule",
        "outbound": "direct"
      },
      {
        "clash_mode": "Direct",
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-cn.srs"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  },
  "outbounds": [
${socks_outbound_field}    {
      "type": "hysteria2",
      "tag": "hy2-$hostname",
      "server": "$cl_hy2_ip",
      "server_port": $hy2_port,
      "password": "$uuid",
      "tls": {
        "enabled": true,
        "server_name": "$hy2_name",
        "insecure": false,
        "alpn": ["h3"]$hy2_certificate_field
      }
    },
    {
      "type": "dns",
      "tag": "dns-out"
    },
    {
      "tag": "proxy",
      "type": "selector",
      "default": "hy2-$hostname",
      "outbounds": [
${socks_selector_member}        "hy2-$hostname"
      ]
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  then
    rm -f "$sbox_candidate" "$clash_candidate"
    return 1
  fi
  if ! "$SB_BIN" check -c "$sbox_candidate" >/dev/null 2>&1; then
    red "生成的sing-box客户端配置未通过v${CORE_VERSION}检查"
    "$SB_BIN" check -c "$sbox_candidate"
    rm -f "$sbox_candidate" "$clash_candidate"
    return 1
  fi

  if ! cat > "$clash_candidate" <<EOF
port: 7890
allow-lan: false
mode: rule
log-level: info
unified-delay: true
dns:
  enable: true
  listen: "127.0.0.1:1053"
  ipv6: true
  prefer-h3: false
  respect-rules: true
  use-system-hosts: false
  cache-algorithm: "arc"
  enhanced-mode: "fake-ip"
  fake-ip-range: "198.18.0.1/16"
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "localhost.ptlogin2.qq.com"
    - "localhost.sec.qq.com"
    - "+.in-addr.arpa"
    - "+.ip6.arpa"
    - "time.*.com"
    - "time.*.gov"
    - "pool.ntp.org"
    - "localhost.work.weixin.qq.com"
  default-nameserver: ["223.5.5.5", "119.29.29.29"]
  nameserver:
    - "https://1.1.1.1/dns-query"
    - "https://8.8.8.8/dns-query"
  proxy-server-nameserver:
    - "https://223.5.5.5/dns-query"
    - "https://doh.pub/dns-query"

proxies:
${socks_clash_proxy}- name: hysteria2-$hostname
  type: hysteria2
  server: $cl_hy2_ip
  port: $hy2_port
  password: $uuid
  alpn:
    - h3
  sni: $hy2_name
  skip-cert-verify: false
$hy2_clash_ca
  fast-open: true

proxy-groups:
- name: 🌍选择代理节点
  type: select
  proxies:
    - hysteria2-$hostname
${socks_clash_member}    - DIRECT

rules:
  - GEOIP,LAN,DIRECT
  - GEOSITE,CN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,🌍选择代理节点
EOF
  then
    rm -f "$sbox_candidate" "$clash_candidate"
    return 1
  fi
  chmod 600 "$sbox_candidate" "$clash_candidate" || { rm -f "$sbox_candidate" "$clash_candidate"; return 1; }
  mv -fT -- "$sbox_candidate" "$SB_DIR/sbox.json" || { rm -f "$sbox_candidate" "$clash_candidate"; return 1; }
  mv -fT -- "$clash_candidate" "$SB_DIR/clash.yaml" || { rm -f "$clash_candidate"; return 1; }
}

remove_saved_ss_link(){
  local path="$SB_DIR/ss.txt"
  [[ -e $path || -L $path ]] || return 0
  managed_regular_file_is_trusted "$path" || return 1
  rm -f -- "$path"
}

remove_saved_socks_link(){
  local path="$SB_DIR/socks5.txt"
  [[ -e $path || -L $path ]] || return 0
  managed_regular_file_is_trusted "$path" || return 1
  rm -f -- "$path"
}

sbshare(){
  local aggregate_tmp hy2_tmp socks_tmp=
  if ! result; then
    return 1
  fi
  if [[ $socks_enabled -eq 1 ]]; then
    socks_tmp=$(mktemp "$SB_DIR/.socks5.txt.XXXXXX") || return 1
    if ! ressocks5 "$socks_tmp"; then
      rm -f "$socks_tmp"
      return 1
    fi
  fi
  hy2_tmp=$(mktemp "$SB_DIR/.hy2.txt.XXXXXX") || { rm -f ${socks_tmp:+"$socks_tmp"}; return 1; }
  if ! reshy2 "$hy2_tmp"; then
    rm -f "$hy2_tmp" ${socks_tmp:+"$socks_tmp"}
    return 1
  fi
  aggregate_tmp=$(mktemp "$SB_DIR/.jhdy.txt.XXXXXX") || {
    rm -f "$hy2_tmp" ${socks_tmp:+"$socks_tmp"}
    return 1
  }
  if ! {
    [[ -z $socks_tmp ]] || cat "$socks_tmp"
    cat "$hy2_tmp"
  } > "$aggregate_tmp"; then
    rm -f "$hy2_tmp" ${socks_tmp:+"$socks_tmp"} "$aggregate_tmp"
    return 1
  fi
  if ! chmod 600 "$hy2_tmp" "$aggregate_tmp" ${socks_tmp:+"$socks_tmp"}; then
    rm -f "$hy2_tmp" ${socks_tmp:+"$socks_tmp"} "$aggregate_tmp"
    return 1
  fi
  if ! sb_client; then
    rm -f "$hy2_tmp" ${socks_tmp:+"$socks_tmp"} "$aggregate_tmp"
    return 1
  fi
  if [[ -n $socks_tmp ]]; then
    mv -fT -- "$socks_tmp" "$SB_DIR/socks5.txt" || {
      rm -f "$socks_tmp" "$hy2_tmp" "$aggregate_tmp"
      return 1
    }
  elif [[ ${socks_keep_previous_share:-0} -eq 1 ]]; then
    yellow "本次未重写 $SB_DIR/socks5.txt（入口配置异常，保留原文件）"
  elif ! remove_saved_socks_link; then
    yellow "SOCKS5 入口未启用，但遗留的 $SB_DIR/socks5.txt 无法删除，请手动检查"
  fi
  if ! remove_saved_ss_link; then
    yellow "本版本已不再生成 $SB_DIR/ss.txt，但遗留文件无法删除，请手动检查"
  fi
  mv -fT -- "$hy2_tmp" "$SB_DIR/hy2.txt" || { rm -f "$hy2_tmp" "$aggregate_tmp"; return 1; }
  mv -fT -- "$aggregate_tmp" "$SB_DIR/jhdy.txt" || { rm -f "$aggregate_tmp"; return 1; }
  atomic_copy_private_file "$SB_DIR/jhdy.txt" "$SB_DIR/jhsub.txt" || return 1
  v2sub=$(cat "$SB_DIR/jhdy.txt" 2>/dev/null) || return 1
  echo
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  red "🚀【 聚合节点 】节点信息如下：" && sleep 2
  echo
  echo "分享链接"
  echo -e "${yellow}$v2sub${plain}"
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
}

switch_ip_priority(){
  local current new choose candidate retry commit_status
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  v4v6_bg
  if ! current=$(jq -er '.outbounds[] | select(.type == "direct" and .tag == "direct") | .domain_strategy // "prefer_ipv4"' "$SB_CONFIG" 2>/dev/null); then
    red "读取当前IP优先级失败，配置未修改"
    readp "按回车返回主菜单..."
    return 1
  fi
  echo
  while true; do
    green "切换IP优先级 (控制VPS出站时IPv4/IPv6的偏好)"
    echo -e "当前: ${yellow}$current${plain}"
    echo
    green "1：IPV4优先 (prefer_ipv4)"
    green "2：IPV6优先 (prefer_ipv6)"
    green "3：仅IPV4 (ipv4_only)"
    green "4：仅IPV6 (ipv6_only)"
    green "0：返回主菜单"
    readp "请选择【0-4】：" choose || return 1
    case "$choose" in
      1|2|3|4)
        case "$choose" in
          1) new="prefer_ipv4";;
          2) new="prefer_ipv6";;
          3) new="ipv4_only";;
          4) new="ipv6_only";;
        esac
        if [[ "$new" =~ ipv4 && -z $v4 ]] || [[ "$new" =~ ipv6 && -z $v6 ]]; then
          red "当前VPS不存在对应的IP地址"
          continue
        fi
        if ! candidate=$(mktemp "$SB_DIR/.sb.json.XXXXXX"); then
          red "创建IP优先级候选配置失败，原配置未修改"
          readp "按回车重试，输入0返回主菜单：" retry || return 1
          [[ $retry == 0 ]] && return 1
          continue
        fi
        if ! jq --arg strategy "$new" '
          if ([.outbounds[] | select(.type == "direct" and .tag == "direct")] | length) != 1
          then error("direct outbound missing or duplicated")
          else (.outbounds[] | select(.type == "direct" and .tag == "direct") | .domain_strategy) = $strategy
          end
        ' "$SB_CONFIG" > "$candidate" || \
          ! jq -e --arg strategy "$new" '[.outbounds[] | select(.type == "direct" and .tag == "direct" and .domain_strategy == $strategy)] | length == 1' "$candidate" >/dev/null; then
          rm -f "$candidate"
          red "生成IP优先级候选配置失败，原配置未修改"
          readp "按回车重新输入，输入0返回主菜单：" retry || return 1
          [[ $retry == 0 ]] && return 1
          continue
        fi
        if commit_config "$candidate"; then
          refresh_share_files_after_change || true
          green "IP优先级修改成功：$new"
          readp "按回车返回主菜单..."
          return 0
        else
          commit_status=$?
        fi
        if [[ $commit_status -eq 2 ]]; then
          red "IP优先级修改失败且自动回滚失败，请先检查服务和备份配置"
          readp "按回车返回主菜单..."
          return 2
        fi
        red "IP优先级修改失败，原配置未修改或已恢复"
        readp "按回车重新输入，输入0返回主菜单：" retry || return 1
        [[ $retry == 0 ]] && return 1
        ;;
      ""|0) return 0 ;;
      *)
        red "请输入0-4中的有效选项"
        ;;
    esac
  done
}
