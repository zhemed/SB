# sb-module: 20-ports
valid_port(){
  local value=$1 minimum=${2:-1}
  [[ $value =~ ^[0-9]{1,5}$ ]] || return 1
  ((10#$value >= minimum && 10#$value <= 65535))
}

valid_uuid(){
  [[ $1 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

# Shadowsocks-2022 pre-shared key: exactly 44 base64 characters = 32 raw bytes,
# padded. Since 4.0.0 this is only used by the *upstream* hop (server-to-server),
# which stays SS-2022; the client-facing entry is SOCKS5.
valid_ss_password(){
  [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# SOCKS5 password: 16-128 characters from a shell-safe set. This is a plain
# shared secret and the protocol sends it in the clear — see the warning the
# enable flow prints, and the note in README.
valid_socks_password(){
  [[ ${#1} -ge 16 && ${#1} -le 128 && $1 != *[!A-Za-z0-9._~-]* ]]
}

generate_socks_password(){
  local key
  key=$(openssl rand -hex 24 2>/dev/null) || return 1
  key=${key//$'\n'/}
  valid_socks_password "$key" || return 1
  printf '%s\n' "$key"
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
  local network=$1
  [[ $network == tcp || $network == udp ]] || return 1
  while true; do
    [[ -z $port ]] && port=$(shuf -i 10000-65535 -n 1)
    if ! valid_port "$port" 1; then
      red "端口必须是1-65535之间的整数"
    else
      port=$((10#$port))
    fi
    if valid_port "$port" 1 && port_conflict "$port" "$network"; then
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

# Port selection for the optional SOCKS5 entry (menu [8]).
# Empty/1 = random, 2 = custom — the same shape the installer uses for its own
# port question. The result is returned in the global `port`.
# Returns 0 with `port` set, or 2 when the operator cancelled: a prompt that
# precedes a live change must always offer a way out.
choose_socks_port(){
  local choice
  while true; do
    yellow "1：自动生成随机端口 (10000-65535范围内)，回车默认"
    yellow "2：自定义端口"
    yellow "0：取消"
    readp "请输入【0-2】：" choice || return 1
    case "$choice" in
      ""|1)
        port=$(random_available_port tcp) || return 1
        return 0
        ;;
      2)
        readp "\n设置SOCKS5端口 (可输入1-65535，留空随机10000-65535，输入0取消)：" port || return 1
        [[ $port == 0 ]] && return 2
        chooseport tcp
        return $?
        ;;
      0) return 2 ;;
      *) red "请输入0、1或2" ;;
    esac
  done
}

hy2port(){
  readp "\n设置Hysteria2主端口 (可输入1-65535，留空随机10000-65535)：" port
  chooseport udp
  port_hy2=$port
}

insport(){
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "三、设置Hysteria2端口"
  yellow "1：自动生成随机端口 (10000-65535范围内)，回车默认。请确保VPS后台已开放所有端口"
  yellow "2：自定义端口。请确保VPS后台已开放指定的端口"
  while true; do
    readp "请输入【1-2】：" port
    case "$port" in
      ""|1)
        port_hy2=$(random_available_port udp) || return 1
        break
        ;;
      2)
        port=
        hy2port
        break
        ;;
      *) red "请输入1或2" ;;
    esac
  done
  echo
  blue "端口确认如下"
  blue "Hysteria-2端口：$port_hy2"
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "四、自动生成协议凭据"
  uuid=$("$SB_BIN" generate uuid)
  if ! valid_uuid "$uuid"; then
    red "生成UUID失败"
    return 1
  fi
  blue "Hysteria2 UUID（密码）：${uuid}"
  yellow "Shadowsocks-2022 入口默认不安装，需要时在菜单[8]可选功能里启用"
}
