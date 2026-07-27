# sb-module: 50-client-output
# IP detection for share links
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
  v4v6_refresh || true
  if [[ -n $v4 && -n $v6 ]]; then
    green "调整IPv4/IPV6配置输出"
    yellow "1：刷新本地IP，使用IPV4配置输出 (回车默认) "
    yellow "2：刷新本地IP，使用IPV6配置输出"
    while true; do
      readp "请选择【1-2】：" menu
      case "$menu" in
        ""|1) save_server_ip "$v4"; break ;;
        2) save_server_ip "$v6"; break ;;
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
  v4v6_refresh || true
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

# Read config from sb.json for share outputs
result(){
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
    [[ $server_ip == "$server_ipcl" ]] || return 1
  elif valid_ipv6 "$server_ipcl"; then
    [[ $server_ip == "[$server_ipcl]" ]] || return 1
  else
    red "保存的公网IP格式无效"
    return 1
  fi
  uuid=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .users[0].uuid' "$SB_CONFIG" 2>/dev/null) || return 1
  vl_port=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null) || return 1
  vl_name=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.server_name' "$SB_CONFIG" 2>/dev/null) || return 1
  managed_regular_file_is_trusted "$SB_DIR/public.key" || return 1
  public_key=$(cat "$SB_DIR/public.key" 2>/dev/null)
  short_id=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.reality.short_id[0]' "$SB_CONFIG" 2>/dev/null) || return 1
  socks_port=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null) || return 1
  socks_username=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .users[0].username' "$SB_CONFIG" 2>/dev/null) || return 1
  socks_password=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .users[0].password' "$SB_CONFIG" 2>/dev/null) || return 1
  hy2_port=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .listen_port' "$SB_CONFIG" 2>/dev/null) || return 1
  hy2_sniname=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.key_path' "$SB_CONFIG" 2>/dev/null) || return 1
  if ! valid_uuid "$uuid" || ! valid_port "$vl_port" || ! valid_port "$socks_port" ||
     ! valid_port "$hy2_port" || [[ $socks_username != "$SOCKS_USERNAME" ]] ||
     ! valid_socks_password "$socks_password" || [[ ! $public_key =~ ^[A-Za-z0-9_-]{43}$ ]] ||
     [[ ! $short_id =~ ^[0-9A-Fa-f]{8}$ ]]; then
    red "服务端配置中的节点参数不完整或格式无效"
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
    [[ $SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    hy2_certificate_json=$(jq -Rs . < "$SB_DIR/cert.pem") || return 1
    [[ -n $hy2_certificate_json ]] || return 1
    hy2_clash_ca="  ca-str: |"$'\n'"$(sed 's/^/    /' "$SB_DIR/cert.pem")"
    atomic_write_private_text "$SB_DIR/SHA256.txt" "$SHA256" || return 1
    hy2_name=www.bing.com
    sb_hy2_ip=$server_ip
    cl_hy2_ip=$server_ipcl
  else
    SHA256=""
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

resvless(){
  local output=${1:-$SB_DIR/vl_reality.txt}
  echo
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  vl_link="vless://$uuid@$server_ip:$vl_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$vl_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#vl-reality-$hostname"
  printf '%s\n' "$vl_link" > "$output" || return 1
  red "🚀【 vless-reality-vision 】节点信息如下：" && sleep 2
  echo
  echo "分享链接【v2rayn(切换singbox内核)、nekobox、小火箭shadowrocket】"
  echo -e "${yellow}$vl_link${plain}"
  echo
  echo "二维码"
  qrencode -o - -t ANSIUTF8 "$vl_link" || return 1
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
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
  socks5_link="socks5://$socks_username:$socks_password@$server_ip:$socks_port#socks5-$hostname"
  printf '%s\n' "$socks5_link" > "$output" || return 1
  red "🚀【 SOCKS5 】节点信息如下：" && sleep 2
  echo
  echo "分享链接【sing-box、Clash、Shadowrocket、Nekobox】"
  echo -e "${yellow}$socks5_link${plain}"
  echo
  echo "二维码"
  qrencode -o - -t ANSIUTF8 "$socks5_link" || return 1
  white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo
}

# Client config generation (kept compatible with sing-box 1.10.7)
sb_client(){
  local sbox_candidate clash_candidate hy2_certificate_field=
  sbox_candidate=$(mktemp "$SB_DIR/.sbox.json.XXXXXX") || return 1
  clash_candidate=$(mktemp "$SB_DIR/.clash.yaml.XXXXXX") || { rm -f "$sbox_candidate"; return 1; }
  if [[ -n $hy2_certificate_json ]]; then
    hy2_certificate_field=$(printf ',\n        "certificate": %s' "$hy2_certificate_json")
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
    {
      "type": "vless",
      "tag": "vless-$hostname",
      "server": "$server_ipcl",
      "server_port": $vl_port,
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$vl_name",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$public_key",
          "short_id": "$short_id"
        }
      }
    },
    {
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
      "type": "socks",
      "tag": "socks5-$hostname",
      "server": "$server_ipcl",
      "server_port": $socks_port,
      "version": "5",
      "username": "$socks_username",
      "password": "$socks_password",
      "network": "tcp"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    },
    {
      "tag": "proxy",
      "type": "selector",
      "default": "auto",
      "outbounds": [
        "auto",
        "vless-$hostname",
        "hy2-$hostname",
        "socks5-$hostname"
      ]
    },
    {
      "tag": "auto",
      "type": "urltest",
      "outbounds": [
        "vless-$hostname",
        "hy2-$hostname"
      ],
      "url": "http://www.gstatic.com/generate_204",
      "interval": "10m",
      "tolerance": 50
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
- name: vless-reality-vision-$hostname
  type: vless
  server: $server_ipcl
  port: $vl_port
  uuid: $uuid
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $vl_name
  reality-opts:
    public-key: $public_key
    short-id: $short_id
  client-fingerprint: chrome

- name: hysteria2-$hostname
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

- name: socks5-$hostname
  type: socks5
  server: $server_ipcl
  port: $socks_port
  username: $socks_username
  password: $socks_password
  udp: false

proxy-groups:
- name: 负载均衡
  type: load-balance
  url: https://www.gstatic.com/generate_204
  interval: 300
  strategy: round-robin
  proxies:
    - vless-reality-vision-$hostname
    - hysteria2-$hostname

- name: 自动选择
  type: url-test
  url: https://www.gstatic.com/generate_204
  interval: 300
  tolerance: 50
  proxies:
    - vless-reality-vision-$hostname
    - hysteria2-$hostname

- name: 🌍选择代理节点
  type: select
  proxies:
    - 负载均衡
    - 自动选择
    - DIRECT
    - vless-reality-vision-$hostname
    - hysteria2-$hostname
    - socks5-$hostname

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

sbshare(){
  local aggregate_tmp vl_tmp hy2_tmp socks_tmp
  vl_tmp=$(mktemp "$SB_DIR/.vl_reality.XXXXXX") || return 1
  hy2_tmp=$(mktemp "$SB_DIR/.hy2.XXXXXX") || { rm -f "$vl_tmp"; return 1; }
  socks_tmp=$(mktemp "$SB_DIR/.socks5.XXXXXX") || { rm -f "$vl_tmp" "$hy2_tmp"; return 1; }
  if ! result || ! resvless "$vl_tmp" || ! reshy2 "$hy2_tmp" || ! ressocks5 "$socks_tmp"; then
    rm -f "$vl_tmp" "$hy2_tmp" "$socks_tmp"
    return 1
  fi
  aggregate_tmp=$(mktemp "$SB_DIR/.jhdy.XXXXXX") || {
    rm -f "$vl_tmp" "$hy2_tmp" "$socks_tmp"
    return 1
  }
  if ! { cat "$vl_tmp" && cat "$hy2_tmp" && cat "$socks_tmp"; } > "$aggregate_tmp"; then
    rm -f "$vl_tmp" "$hy2_tmp" "$socks_tmp" "$aggregate_tmp"
    return 1
  fi
  chmod 600 "$vl_tmp" "$hy2_tmp" "$socks_tmp" "$aggregate_tmp" || {
    rm -f "$vl_tmp" "$hy2_tmp" "$socks_tmp" "$aggregate_tmp"
    return 1
  }
  if ! sb_client; then
    rm -f "$vl_tmp" "$hy2_tmp" "$socks_tmp" "$aggregate_tmp"
    return 1
  fi
  mv -fT -- "$vl_tmp" "$SB_DIR/vl_reality.txt" || { rm -f "$vl_tmp" "$hy2_tmp" "$socks_tmp" "$aggregate_tmp"; return 1; }
  mv -fT -- "$hy2_tmp" "$SB_DIR/hy2.txt" || { rm -f "$hy2_tmp" "$socks_tmp" "$aggregate_tmp"; return 1; }
  mv -fT -- "$socks_tmp" "$SB_DIR/socks5.txt" || { rm -f "$socks_tmp" "$aggregate_tmp"; return 1; }
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

# Switch IP priority for server outbound domain_strategy (like original sb.sh)
switch_ip_priority(){
  local current new choose candidate retry commit_status
  if ! sbactive; then
    readp "按回车返回主菜单..."
    return 1
  fi
  v4v6_refresh || true
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
    [[ -n $v4 ]] && green "1：IPV4优先 (prefer_ipv4)"
    [[ -n $v6 ]] && green "2：IPV6优先 (prefer_ipv6)"
    [[ -n $v4 ]] && green "3：仅IPV4 (ipv4_only)"
    [[ -n $v6 ]] && green "4：仅IPV6 (ipv6_only)"
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
