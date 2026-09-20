# sb-module: 30-server-config
# Generate server config JSON
render_server_config(){
  local output=$1 listen_addr relay_outbound_suffix route_final
  local entry_inbounds=
  local entry_rules=
  [[ -n $output ]] || return 1
  relay_outbound_suffix=
  route_final=direct
  listen_addr=$(server_listen_address "$IPV6_SYSCTL_ROOT") || return 1
  [[ -n $listen_addr ]] || return 1
  # The optional TCP entry is absent by default: a new install creates only
  # hysteria2, and the operator enables the entry from menu [8].
  if [[ ${socks_entry_enabled:-0} -eq 1 ]]; then
    entry_inbounds=$(printf ',\n    {\n      "type": "socks",\n      "sniff": true,\n      "sniff_override_destination": true,\n      "tag": "socks5-sb",\n      "listen": "%s",\n      "listen_port": %s,\n      "users": [\n        {\n          "username": "%s",\n          "password": "%s"\n        }\n      ]\n    }' \
      "$listen_addr" "${port_socks5:-}" "$SOCKS_USERNAME" "${socks_password:-}") || return 1
    entry_inbounds+=$'\n'
    entry_rules=$(printf '      {\n        "inbound": [\n          "socks5-sb"\n        ],\n        "network": "udp",\n        "outbound": "block"\n      },\n') || return 1
  fi
  # A Shadowsocks-2022 entry created by 3.0.0-3.1.4 is preserved verbatim instead
  # of being converted or dropped (operator decision 2026-09-20): the raw inbound
  # object comes from the source config and is re-emitted unchanged.
  if [[ -n ${legacy_entry_inbound:-} ]]; then
    entry_inbounds+=$(printf ',\n    %s' "$legacy_entry_inbound") || return 1
    entry_inbounds+=$'\n'
    entry_rules+=$(printf '      {\n        "inbound": [\n          "ss-sb"\n        ],\n        "network": "udp",\n        "outbound": "block"\n      },\n') || return 1
  fi
  # The optional upstream is re-read from relay.conf on every render, so a
  # rewritten config keeps the relay instead of silently falling back to a
  # direct exit. An unreadable state file is reported, not guessed at.
  if relay_settings_present; then
    if load_relay_settings; then
      route_final=relay
      relay_outbound_suffix=$(printf ',\n    {\n      "type": "shadowsocks",\n      "tag": "relay",\n      "server": "%s",\n      "server_port": %s,\n      "method": "%s",\n      "password": "%s"\n    }' \
        "$relay_server" "$relay_port" "$RELAY_METHOD" "$relay_password") || return 1
    else
      red "上游配置 $(relay_config_path) 无效，本次未启用上游（仍按直连出网）"
    fi
  elif [[ -s $SB_CONFIG ]] &&
       jq -e '[.outbounds[]? | select(.type == "shadowsocks")] | length > 0' "$SB_CONFIG" >/dev/null 2>&1; then
    # A hand-edited upstream outbound is not a state file we know about; say so
    # rather than letting the rewrite silently send traffic out directly again.
    yellow "当前配置里有一条上游出站，但 $(relay_config_path) 不存在，本次重写不会保留它"
    yellow "如需继续中转，请在菜单[8]上游/中转里重新设置一次"
  fi
  cat > "$output" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "sniff": true,
      "sniff_override_destination": true,
      "tag": "hy2-sb",
      "listen": "${listen_addr}",
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
    }${entry_inbounds}
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
    }${relay_outbound_suffix}
  ],
  "route": {
    "final": "${route_final}",
    "rules": [
${entry_rules}      {
        "protocol": [
          "quic",
          "stun"
        ],
        "outbound": "block"
      }
    ]
  }
}
EOF
}

inssbjson(){
  local candidate
  candidate=$(mktemp "$SB_DIR/.sb.json.install.XXXXXX") || return 1
  if ! render_server_config "$candidate"; then
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
  mv -fT -- "$candidate" "$SB_CONFIG"
}
