# sb-module: 30-server-config
# Generate server config JSON
inssbjson(){
  local candidate
  candidate=$(mktemp "$SB_DIR/.sb.json.install.XXXXXX") || return 1
  if ! cat > "$candidate" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "sniff": true,
      "sniff_override_destination": true,
      "tag": "vless-sb",
      "listen": "::",
      "listen_port": ${port_vl_re},
      "users": [
        {
          "uuid": "${uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${ym_vl_re}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${ym_vl_re}",
            "server_port": 443
          },
          "private_key": "${private_key}",
          "short_id": ["${short_id}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "sniff": true,
      "sniff_override_destination": true,
      "tag": "hy2-sb",
      "listen": "::",
      "listen_port": ${port_hy2},
      "users": [
        {
          "password": "${uuid}"
        }
      ],
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "${certificatec_hy2}",
        "key_path": "${certificatep_hy2}"
      }
    },
    {
      "type": "socks",
      "sniff": true,
      "sniff_override_destination": true,
      "tag": "socks5-sb",
      "listen": "::",
      "listen_port": ${port_socks5},
      "users": [
        {
          "username": "${SOCKS_USERNAME}",
          "password": "${socks_password}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "domain_strategy": "${ipv}"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "socks5-sb"
        ],
        "network": "udp",
        "outbound": "block"
      },
      {
        "protocol": [
          "quic",
          "stun"
        ],
        "outbound": "block"
      },
      {
        "outbound": "direct",
        "network": "udp,tcp"
      }
    ]
  }
}
EOF
  then
    rm -f "$candidate"
    red "写入Sing-box候选配置失败"
    return 1
  fi
  chmod 600 "$candidate" || { rm -f "$candidate"; return 1; }
  if ! "$SB_BIN" check -c "$candidate" >/dev/null 2>&1; then
    red "初始配置未通过Sing-box v${CORE_VERSION}检查"
    "$SB_BIN" check -c "$candidate"
    rm -f "$candidate"
    return 1
  fi
  mv -f "$candidate" "$SB_CONFIG"
}
