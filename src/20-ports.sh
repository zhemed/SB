# sb-module: 20-ports
valid_port(){
  local value=$1 minimum=${2:-1}
  [[ $value =~ ^[0-9]{1,5}$ ]] || return 1
  ((10#$value >= minimum && 10#$value <= 65535))
}

valid_uuid(){
  [[ $1 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

valid_socks_password(){
  [[ ${#1} -ge 16 && ${#1} -le 128 && $1 != *[!A-Za-z0-9._~-]* ]]
}

valid_reality_key(){
  [[ $1 =~ ^[A-Za-z0-9_-]{43}$ ]]
}

valid_short_id(){
  [[ $1 =~ ^[0-9A-Fa-f]{8}$ ]]
}

valid_hostname(){
  local name=$1 label
  local -a labels
  [[ ${#name} -le 253 && $name == *.* && $name != .* && $name != *. ]] || return 1
  IFS='.' read -r -a labels <<< "$name"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

port_conflict(){
  local port_number=$1 network=$2
  local -a ss_args
  case "$network" in
    tcp) ss_args=(-H -lnt) ;;
    udp) ss_args=(-H -lnu) ;;
    *) return 2 ;;
  esac
  ss "${ss_args[@]}" 2>/dev/null | awk '{print $(NF-1)}' |
    sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | grep -qx -- "$port_number"
}

chooseport(){
  local network=$1 reserved=${2-}
  [[ $network == tcp || $network == udp ]] || return 1
  while true; do
    [[ -z $port ]] && port=$(shuf -i 10000-65535 -n 1)
    if ! valid_port "$port" 1; then
      red "端口必须是1-65535之间的整数"
    else
      port=$((10#$port))
    fi
    if valid_port "$port" 1 && [[ -n $reserved && $port == "$reserved" ]]; then
      red "端口 $port/$network 与已选择的TCP端口冲突"
      port=
    elif valid_port "$port" 1 && port_conflict "$port" "$network"; then
      red "端口 $port/$network 已被占用"
    elif valid_port "$port" 1; then
      break
    fi
    readp "请重新输入端口 (1-65535，留空随机10000-65535): " port
  done
  blue "确认的端口：$port" && sleep 2
}

random_available_port(){
  local network=$1 candidate
  [[ $network == tcp || $network == udp ]] || return 1
  while true; do
    candidate=$(shuf -i 10000-65535 -n 1) || return 1
    if ! port_conflict "$candidate" "$network"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

vlport(){
  readp "\n设置Vless-reality端口 (可输入1-65535，留空随机10000-65535)：" port
  chooseport tcp
  port_vl_re=$port
}

socksport(){
  readp "\n设置SOCKS5端口 (可输入1-65535，留空随机10000-65535)：" port
  chooseport tcp "$port_vl_re"
  port_socks5=$port
}

hy2port(){
  readp "\n设置Hysteria2主端口 (可输入1-65535，留空随机10000-65535)：" port
  chooseport udp
  port_hy2=$port
}

insport(){
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "三、设置各协议端口"
  yellow "1：自动生成随机端口 (10000-65535范围内)，回车默认。请确保VPS后台已开放所有端口"
  yellow "2：自定义每个协议端口。请确保VPS后台已开放指定的端口"
  while true; do
    readp "请输入【1-2】：" port
    case "$port" in
      ""|1)
        port_vl_re=$(random_available_port tcp) || return 1
        while true; do
          port_socks5=$(random_available_port tcp) || return 1
          [[ $port_socks5 != "$port_vl_re" ]] && break
        done
        port_hy2=$(random_available_port udp) || return 1
        break
        ;;
      2)
        port=
        vlport
        port=
        socksport
        port=
        hy2port
        break
        ;;
      *) red "请输入1或2" ;;
    esac
  done
  echo
  blue "各协议端口确认如下"
  blue "Vless-reality端口：$port_vl_re"
  blue "SOCKS5端口：$port_socks5"
  blue "Hysteria-2端口：$port_hy2"
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "四、自动生成协议凭据"
  uuid=$("$SB_BIN" generate uuid)
  if ! valid_uuid "$uuid"; then
    red "生成UUID失败"
    return 1
  fi
  socks_password=$(openssl rand -hex 24 2>/dev/null || true)
  if ! valid_socks_password "$socks_password"; then
    red "生成SOCKS5独立密码失败"
    return 1
  fi
  blue "VLESS/Hysteria2 UUID（密码）：${uuid}"
  blue "SOCKS5独立密码：${socks_password}"
}
