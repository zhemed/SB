#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly ROOT_DIR
hook_candidate=

cleanup(){
  [[ -z $hook_candidate ]] || rm -f -- "$hook_candidate"
}
trap cleanup EXIT

fail(){
  printf 'verify: %s\n' "$1" >&2
  exit 1
}

bash "$ROOT_DIR/scripts/build.sh" --check
bash -n "$ROOT_DIR/sb.sh"
bash -n "$ROOT_DIR/scripts/build.sh"
bash -n "$ROOT_DIR/tests/unit.sh"
bash -n "$ROOT_DIR/tests/repair.sh"
bash -n "$ROOT_DIR/tests/replay.sh"
bash -n "$ROOT_DIR/tests/verify.sh"

[[ $(grep -Fxc 'CORE_VERSION="1.10.7"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "Sing-box version is not pinned to 1.10.7"
[[ $(grep -Fxc 'ACME_VERSION="3.1.4"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "acme.sh version is not pinned to 3.1.4"
for digest_line in \
  'CORE_SHA256_AMD64="1951a0785c8b4e1e21e0640227a49528ca772aec3d680061652e3d6b687e00fe"' \
  'CORE_SHA256_ARM64="15b43a0a50b4e6962aca819d4f3055aaac75ca7481350d4aaebe93ed06b7af49"' \
  'CORE_SHA256_ARMV7="691882d609c877f97bc8d6f8645b97d12de81b6f7b89651df66489ef11b4c5d0"' \
  'ACME_ARCHIVE_SHA256="e5f8e187bbf5251e0cd8891f2622daab9850366bd17bea9f92c2fe2ee091fd32"'; do
  [[ $(grep -Fxc "$digest_line" "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
    fail "pinned download digest is missing: $digest_line"
done
grep -Fq -- "--proto '=https' --proto-redir '=https'" "$ROOT_DIR/sb.sh" ||
  fail "HTTPS-only download policy is missing"
grep -Fq -- 'https://codeload.github.com/acmesh-official/acme.sh/tar.gz/refs/tags/' \
  "$ROOT_DIR/sb.sh" || fail "verified acme.sh source archive download is missing"
if grep -Fq -- '--install-online' "$ROOT_DIR/sb.sh"; then
  fail "unverified acme.sh online installer remains"
fi
[[ $(grep -Fxc 'SOCKS_USERNAME="sb"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "SOCKS5 username is not fixed to sb"
[[ $(grep -Fxc 'sb_version="v5.6.1"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "script version is not 5.6.1"
[[ $(tr -d '\r\n' < "$ROOT_DIR/VERSION") == '5.6.1' ]] ||
  fail "VERSION file is not 5.6.1"
grep -Fq -- "当前项目版本：\`5.6.1\`" "$ROOT_DIR/README.md" ||
  fail "README project version is not 5.6.1"
for lifecycle_pattern in \
  'INSTALL_TRANSACTION_ACTIVE=0' \
  'cleanup_install_transaction()' \
  'cleanup_incomplete_install()' \
  'abort_install_transaction()' \
  'repair_singbox_locked()' \
  'save_last_good_config()' \
  'trap handle_install_interrupt INT TERM HUP' \
  'green " 1. 安装"' \
  'green " 2. 修复"' \
  'green " 8. 可选功能"' \
  'green " 9. 卸载"' \
  'readp "请输入数字 [0-9]: " Input' \
  'manage_optional_features()' \
  'manage_socks_entry()' \
  'enable_socks_entry()' \
  'disable_socks_entry()' \
  'change_socks_port()' \
  '请选择【0-4】'; do
  grep -Fq -- "$lifecycle_pattern" "$ROOT_DIR/sb.sh" ||
    fail "missing installation lifecycle behavior: $lifecycle_pattern"
done
if grep -Fq -- 'green " 1. 安装/修复"' "$ROOT_DIR/sb.sh"; then
  fail "combined install/repair menu remains"
fi
[[ $(grep -Fxc 'SHORTCUT="/usr/bin/sb"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "formal shortcut identity is invalid"
[[ $(grep -Fxc '  readp "请输入 Cloudflare API Token：" cf_token || return 3' \
  "$ROOT_DIR/sb.sh" || true) -eq 1 ]] || fail "Cloudflare Token input is not visible"
if grep -Fq 'API Token 已读取' "$ROOT_DIR/sb.sh" ||
   grep -Fq '输入不回显' "$ROOT_DIR/sb.sh" ||
   grep -Eq 'read[^[:cntrl:]]+-s[^[:cntrl:]]+cf_token' "$ROOT_DIR/sb.sh"; then
  fail "hidden Cloudflare Token interaction remains"
fi
# 华为云走 AK/SK（自写 acme.sh dnsapi 插件），凭据同样必须是可见输入。
for huawei_pattern in \
  '请选择 DNS 供应商' \
  'readp "请输入华为云 Access Key ID：' \
  'readp "请输入华为云 Secret Access Key：' \
  '请选择华为云 Region' \
  '北京 cn-north-4' \
  '上海 cn-east-3' \
  '广州 cn-south-1' \
  '香港 ap-southeast-1' \
  '手动输入 Region ID' \
  'readp "请输入华为云 Region ID（如 cn-north-4）：' \
  'dns_huaweicloud_aksk' \
  'SDK-HMAC-SHA256'; do
  grep -Fq -- "$huawei_pattern" "$ROOT_DIR/sb.sh" ||
    fail "missing Huawei Cloud DNS support: $huawei_pattern"
done
[[ $(grep -Fxc -- '# sb-huaweicloud-aksk: v1' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "Huawei Cloud DNS plugin marker is missing or duplicated"
if grep -Fq -- 'HUAWEICLOUD_PASSWORD' "$ROOT_DIR/sb.sh"; then
  fail "deprecated Huawei Cloud IAM password credentials remain"
fi
if grep -Eq 'read[^[:cntrl:]]+-s[^[:cntrl:]]+(hw_access_key|hw_secret_key)' "$ROOT_DIR/sb.sh"; then
  fail "hidden Huawei Cloud credential interaction remains"
fi
# 与第二个消费者（nginx）共用证书：README 必须给出稳定路径与后置钩子示例。
for shared_cert_pattern in \
  '/etc/sb/acme-cert.pem' \
  '/etc/sb/acme-private.key' \
  'acme_post_reload.sh' \
  'systemctl reload nginx' \
  '/etc/cert-store' \
  '使用共享证书库中的证书' \
  '发布当前证书到共享证书库'; do
  grep -Fq -- "$shared_cert_pattern" "$ROOT_DIR/README.md" ||
    fail "README does not document sharing the certificate with a second consumer: $shared_cert_pattern"
done
# 交互签发路径没有端到端测试，这里静态钉住 provider 选择与凭据传递方式。
# shellcheck disable=SC2016  # the pattern is literal generated-script text
grep -Fq -- '--dns "${plugin%.sh}"' "$ROOT_DIR/sb.sh" ||
  fail "ACME issuance does not select the DNS plugin from the provider"
# shellcheck disable=SC2016  # the patterns are literal generated-script text
for huawei_env in \
  'HUAWEICLOUD_ACCESS_KEY_ID="$hw_access_key"' \
  'HUAWEICLOUD_SECRET_ACCESS_KEY="$hw_secret_key"' \
  'HUAWEICLOUD_REGION="$hw_region"'; do
  grep -Fq -- "$huawei_env" "$ROOT_DIR/sb.sh" ||
    fail "Huawei Cloud credentials are not passed through the environment: $huawei_env"
done

# 共享证书库契约（/etc/cert-store）：常量与核心原语必须存在于发布物中。
[[ $(grep -Fxc 'CERT_STORE="/etc/cert-store"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "shared certificate store root is not pinned"
[[ $(grep -Fxc 'CERT_STORE_VERSION=1' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "shared certificate store contract version is not pinned"
for store_pattern in \
  'cert_store_publish(){' \
  'cert_store_publish_locked(){' \
  'cert_store_can_adopt(){' \
  'cert_store_certificate_state(){' \
  'cert_store_with_lock(){' \
  'cert_store_take_ownership(){' \
  'cert_store_owner(){'; do
  grep -Fq -- "$store_pattern" "$ROOT_DIR/sb.sh" ||
    fail "shared certificate store helper is missing: $store_pattern"
done
# 共享证书模式（consumer）：菜单/健康检查/修复必须接上 store。
for shared_mode_pattern in \
  'cert_shared(){' \
  'config_uses_shared_certificate(){' \
  'shared_certificate_domain(){' \
  'shared_certificate_is_valid(){' \
  'choose_shared_certificate(){' \
  'publish_acme_certificate_to_store(){' \
  'cert_store_list_adoptable(){'; do
  grep -Fq -- "$shared_mode_pattern" "$ROOT_DIR/sb.sh" ||
    fail "shared certificate mode helper is missing: $shared_mode_pattern"
done
for shared_mode_text in \
  '使用共享证书库中的证书（领养，不再申请）' \
  '发布当前证书到共享证书库' \
  '共享证书库中的可用证书' \
  '续期负责人(owner)' \
  '共享证书库证书'; do
  grep -Fq -- "$shared_mode_text" "$ROOT_DIR/sb.sh" ||
    fail "shared certificate mode UI text is missing: $shared_mode_text"
done

grep -Fq -- 'example.com 默认同时申请 example.com + *.example.com' "$ROOT_DIR/sb.sh" ||
  fail "domain prompt does not default to apex + wildcard"
grep -Fq -- '检测到共享证书库证书，已自动领养' "$ROOT_DIR/sb.sh" ||
  fail "sb does not auto-adopt a single shared certificate"
grep -Fq -- 'ensure_nginx_shared_cert_reload_hook(){' "$ROOT_DIR/sb.sh" ||
  fail "sb does not auto-create the nginx reload hook"
grep -Fq -- 'nginx -t >/dev/null 2>&1 && systemctl reload nginx' "$ROOT_DIR/sb.sh" ||
  fail "auto-created nginx reload hook content is missing"
grep -Fq -- 'ensure_acme_nginx_sb_restart_hook(){' "$ROOT_DIR/sb.sh" ||
  fail "sb does not auto-create the acme-nginx sb restart hook"

for success_message in \
  '证书模式切换成功' \
  'Hysteria2主端口修改成功' \
  'SOCKS5端口修改成功' \
  'IP优先级修改成功' \
  'Hysteria2 UUID（密码）修改成功' \
  'SOCKS5密码修改成功'; do
  grep -Fq -- "$success_message" "$ROOT_DIR/sb.sh" ||
    fail "missing modification success message: $success_message"
done
# shellcheck disable=SC2016
for socks_pattern in \
  'SOCKS_USERNAME="sb"' \
  '"tag": "relay"' \
  '"type": "socks"' \
  '"tag": "socks5-sb"' \
  '"username": "%s"' \
  'socks_entry_is_enabled()' \
  'socks_entry_candidate_with_inbound()' \
  'socks_entry_candidate_without_inbound()' \
  'socks_entry_enabled' \
  'retired_ss_entry_port()' \
  'choose_socks_port()' \
  'generate_socks_password()' \
  'valid_socks_password()' \
  'server_listen_address()' \
  'IPV6_SYSCTL_ROOT="/proc/sys/net/ipv6"' \
  'local root=$1 disabled=' \
  "printf '%s\\n' 0.0.0.0" \
  'relay_settings_present()' \
  'load_relay_settings()' \
  'save_relay_settings()' \
  '"tag": "relay"' \
  '"final": "${route_final}"' \
  'relay.conf' \
  'ressocks5()' \
  '"tag": "socks5-%s"' \
  'type: socks5' \
  'udp: false' \
  '"version": "5"' \
  'socks5.txt' \
  'remove_saved_socks_link()' \
  'print_socks_entry_share()' \
  '用户名/密码：' \
  'remove_saved_ss_link()' \
  '本版本已不再生成' \
  'manage_relay()' \
  '当前配置里有一条上游出站，但' \
  'set_relay_upstream()' \
  'clear_relay_upstream()' \
  '输入0取消' \
  '已取消，端口未修改'; do
  grep -Fq -- "$socks_pattern" "$ROOT_DIR/sb.sh" ||
    fail "missing SOCKS5 integration: $socks_pattern"
done
if grep -Eq '^(ss_entry_is_enabled|ss_entry_candidate_with_inbound|ss_entry_candidate_without_inbound|enable_ss_entry|disable_ss_entry|change_ss_password|change_ss_port|choose_ss_port|generate_ss_password|print_ss_entry_share|preserved_ss_entry_is_enabled|preserved_ss_entry_port|preserved_ss_candidate_without_inbound|remove_preserved_ss_entry|resss)\(\)\{' \
  "$ROOT_DIR/sb.sh"; then
  fail "a retired Shadowsocks-2022-entry function is still defined"
fi
for retired_protocol_pattern in \
  'RELAY_METHOD' \
  '2022-blake3' \
  'valid_ss_password' \
  'shadowsocks' \
  'Shadowsocks'; do
  if grep -Fiq -- "$retired_protocol_pattern" "$ROOT_DIR/sb.sh" ||
     grep -rFiq -- "$retired_protocol_pattern" "$ROOT_DIR/src"; then
    fail "the retired protocol is still present: $retired_protocol_pattern"
  fi
done
grep -Fq -- '"type": "socks"' "$ROOT_DIR/sb.sh" ||
  fail "the upstream hop no longer uses the landing machine's SOCKS5 entry"
grep -Fq -- '"tag": "relay"' "$ROOT_DIR/sb.sh" ||
  fail "the upstream outbound tag is missing"
for removed_pattern in \
  'REPAIR_SS_ENABLED' \
  'REPAIR_SS_PASSWORD' \
  'REPAIR_PRESERVED_' \
  'ss_entry_enabled' \
  'preserved_entry_inbound' \
  'preserved_ss_candidate' \
  '"network": "udp,tcp"'; do
  if grep -Fq -- "$removed_pattern" "$ROOT_DIR/sb.sh"; then
    fail "retired integration remains: $removed_pattern"
  fi
done
# shellcheck disable=SC2016
grep -Fq -- 'local ipv=$REPAIR_STRATEGY' "$ROOT_DIR/sb.sh" ||
  fail "repair render no longer reads the IP strategy through dynamic scope"
# shellcheck disable=SC2016
if grep -Fq -- 'entry_inbounds+=$(printf' "$ROOT_DIR/sb.sh"; then
  fail "server render still appends a preserved inbound"
fi
grep -Fq -- '请选择【0-1】' "$ROOT_DIR/sb.sh" ||
  fail "port management menu is missing"
install_function=$(awk '/^insport\(\)\{/{inside=1} /^render_server_config\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $install_function ]] || fail "cannot extract insport"
for optional_pattern in 'socks_password' 'port_socks5' 'socks5-sb' 'generate_socks_password' 'ss-sb'; do
  if printf '%s\n' "$install_function" | grep -Fq -- "$optional_pattern"; then
    fail "install flow still creates an optional entry: $optional_pattern"
  fi
done
credential_flow=$(awk '/^changeuuid\(\)\{/{inside=1} /^change_socks_password\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
socks_branch_flow=$(awk '/^enable_socks_entry\(\)\{/{inside=1} /^manage_socks_entry\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
relay_branch_flow=$(awk '/^set_relay_upstream\(\)\{/{inside=1} /^manage_relay\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
credential_menu=$(awk '/^change_credentials\(\)\{/{inside=1} /^set_relay_upstream\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $credential_flow && -n $socks_branch_flow && -n $relay_branch_flow && -n $credential_menu ]] ||
  fail "cannot extract the menu flows for the return-label check"
if printf '%s\n' "$credential_flow" | grep -Fq '返回主菜单'; then
  fail "the UUID flow returns to 凭据管理 but tells the operator it returns to 主菜单"
fi
if printf '%s\n' "$socks_branch_flow" | grep -Fq -- '返回可选功能'; then
  fail "the SOCKS5 entry actions land in the sub-menu but say 返回可选功能"
fi
if printf '%s\n' "$relay_branch_flow" | grep -Fq -- '返回主菜单' ||
   printf '%s\n' "$relay_branch_flow" | grep -Fq -- '返回可选功能'; then
  fail "the upstream actions land in the 上游/中转 menu but name another menu"
fi
if printf '%s\n' "$credential_menu" | grep -Fq -- 'Shadowsocks'; then
  fail "the credentials menu still advertises the removed Shadowsocks entry"
fi

for ip_option in \
  '1：IPV4优先 (prefer_ipv4)' \
  '2：IPV6优先 (prefer_ipv6)' \
  '3：仅IPV4 (ipv4_only)' \
  '4：仅IPV6 (ipv6_only)'; do
  grep -Fq -- "green \"$ip_option\"" "$ROOT_DIR/sb.sh" ||
    fail "the IP-priority menu does not list every option: $ip_option"
done
dollar=$(printf '%s' '$')
if grep -Fq -- "[[ -n ${dollar}v4 ]] && green" "$ROOT_DIR/sb.sh" ||
   grep -Fq -- "[[ -n ${dollar}v6 ]] && green" "$ROOT_DIR/sb.sh"; then
  fail "the IP-priority menu hides options again"
fi
grep -Fq -- '当前VPS不存在对应的IP地址' "$ROOT_DIR/sb.sh" ||
  fail "an unusable IP family is no longer rejected with a message"
if grep -Fq -- '这是一个可选的 TCP 备用入口' "$ROOT_DIR/sb.sh"; then
  fail "the optional-entry menu carries the standing hint block again"
fi

grep -Fq -- 'choose_socks_port()' "$ROOT_DIR/sb.sh" ||
  fail "optional entry port selection is missing"
# A port retry loop must always be escapable, and the hostname is interpolated into
# JSON/YAML/link text, so it cannot be trusted as-is.
grep -Fq -- '输入0取消): " port || return 2' "$ROOT_DIR/sb.sh" ||
  fail "the port retry prompt no longer offers a cancel"
# shellcheck disable=SC2016
[[ $(grep -Fxc -- '# Managed by sb.sh' "$ROOT_DIR/sb.sh" || true) -eq 2 ]] ||
  fail "the two unit generators no longer both emit the ownership marker"
# shellcheck disable=SC2016
grep -Fq -- 'hostname=$(hostname 2>/dev/null)' "$ROOT_DIR/sb.sh" ||
  fail "the hostname is used without a guarded read"
grep -Fq -- '|| hostname=sb' "$ROOT_DIR/sb.sh" ||
  fail "an invalid hostname is no longer replaced by a safe tag prefix"

[[ $(grep -Fc -- '按回车返回主菜单...' "$ROOT_DIR/sb.sh" || true) -ge 5 ]] ||
  fail "modification flows do not consistently wait before returning"

uuid_function=$(awk '/^changeuuid\(\)\{/{inside=1} /^change_socks_password\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $uuid_function ]] || fail "cannot extract UUID management function"
if printf '%s\n' "$uuid_function" | grep -Fq -- 'socks5-sb'; then
  fail "UUID management still touches the optional SOCKS5 entry"
fi

client_function=$(awk '/^sb_client\(\)\{/{inside=1} /^sbshare\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $client_function ]] || fail "cannot extract client configuration generator"
for auto_pattern in '"type": "urltest"' '"tag": "auto"' \
  'type: load-balance' 'type: url-test' '负载均衡' '自动选择'; do
  if printf '%s\n' "$client_function" | grep -Fq -- "$auto_pattern"; then
    fail "client configuration still contains an automatic selection group: $auto_pattern"
  fi
done
grep -Fq -- '"tag": "proxy"' <<< "$client_function" ||
  fail "cannot extract Sing-box proxy selector"
if printf '%s\n' "$client_function" | grep -Fq -- '"default": "auto"'; then
  fail "Sing-box proxy selector still defaults to the removed automatic group"
fi

share_function=$(awk '/^sbshare\(\)\{/{inside=1} inside' "$ROOT_DIR/sb.sh")
[[ -n $share_function ]] || fail "cannot extract share generator"
socks_share_off=$(printf '%s\n' "$share_function" | grep -bo 'ressocks5 ' | head -1 | cut -d: -f1 || true)
hy2_share_off=$(printf '%s\n' "$share_function" | grep -bo 'reshy2' | head -1 | cut -d: -f1 || true)
[[ -n $socks_share_off && -n $hy2_share_off ]] ||
  fail "cannot locate share generators in sbshare"
[[ $socks_share_off -lt $hy2_share_off ]] ||
  fail "share output lists Hysteria2 before the optional SOCKS5 entry"
# shellcheck disable=SC2016
socks_out_off=$(printf '%s\n' "$client_function" | grep -bo 'socks5-%s' | head -1 | cut -d: -f1 || true)
# shellcheck disable=SC2016
hy2_out_off=$(printf '%s\n' "$client_function" | grep -bo 'hy2-\$hostname' | head -1 | cut -d: -f1 || true)
[[ -n $socks_out_off && -n $hy2_out_off && $socks_out_off -lt $hy2_out_off ]] ||
  fail "client configuration lists Hysteria2 before the optional SOCKS5 entry"
# shellcheck disable=SC2016
grep -Fq -- '${socks_outbound_field}    {' "$ROOT_DIR/sb.sh" ||
  fail "client configuration emits the optional outbound in a different place"
# shellcheck disable=SC2016
grep -Fq -- '${socks_selector_member}        "hy2-$hostname"' "$ROOT_DIR/sb.sh" ||
  fail "client configuration emits the optional selector member in a different place"
# shellcheck disable=SC2016
grep -Fq -- '${socks_clash_proxy}- name: hysteria2-$hostname' "$ROOT_DIR/sb.sh" ||
  fail "clash proxies no longer list the optional entry before Hysteria2"
# shellcheck disable=SC2016
grep -Fq -- '${socks_clash_member}    - DIRECT' "$ROOT_DIR/sb.sh" ||
  fail "clash group no longer lists the optional entry first"
# shellcheck disable=SC2016
grep -Fq -- '"default": "hy2-$hostname"' <<< "$client_function" ||
  fail "Sing-box proxy selector does not default to Hysteria2"
clash_group=$(printf '%s\n' "$client_function" |
  awk '/^- name: 🌍选择代理节点/{inside=1} inside{print} inside && /^rules:/{exit}')
[[ -n $clash_group ]] || fail "cannot extract Clash proxy group"
clash_first_proxy=$(printf '%s\n' "$clash_group" | awk '/proxies:/{getline; print; exit}')
[[ -n $clash_first_proxy ]] || fail "cannot read the Clash group default proxy"
if [[ $clash_first_proxy == *DIRECT* ]]; then
  fail "Clash select group defaults to DIRECT, so no traffic is proxied"
fi
# shellcheck disable=SC2016
[[ $clash_first_proxy == *'hysteria2-$hostname'* ]] ||
  fail "Clash select group does not default to the encrypted Hysteria2 proxy"

for secure_pattern in \
  'allow-lan: false' \
  'listen: "127.0.0.1:1053"' \
  '"insecure": false' \
  'skip-cert-verify: false' \
  "hy2_certificate_json=\$(jq -Rs . < \"\$SB_DIR/cert.pem\")" \
  'hy2_clash_ca="  ca-str: |"' \
  'insecure=0&allowInsecure=0'; do
  grep -Fq -- "$secure_pattern" "$ROOT_DIR/sb.sh" ||
    fail "secure client setting is missing: $secure_pattern"
done
if grep -Fq -- '"insecure": true' "$ROOT_DIR/sb.sh" ||
   grep -Fq -- 'skip-cert-verify: true' "$ROOT_DIR/sb.sh"; then
  fail "insecure Hysteria2 client setting remains"
fi

grep -Fq -- '"socks5-sb"\n        ],\n        "network": "udp",\n        "outbound": "block"' \
  "$ROOT_DIR/sb.sh" ||
  fail "the optional SOCKS5 entry no longer blocks inbound UDP"
grep -Fq -- '落地机要已启用 SOCKS5 入口' "$ROOT_DIR/sb.sh" ||
  fail "the upstream flow does not explain which entry it uses"
grep -Fq -- '请输入落地机 SOCKS5 入口的密码' "$ROOT_DIR/sb.sh" ||
  fail "the upstream credential prompt does not name the SOCKS5 password"
grep -Fq -- '本版本已不再支持' "$ROOT_DIR/sb.sh" ||
  fail "the retired entry is dropped without a warning"
grep -Fq -- '本次重写会移除该入口' "$ROOT_DIR/sb.sh" ||
  fail "the rewrite does not say that the retired entry is being removed"

retired_name="sb$(printf '%s' 2)"
retired_patterns=(
  "$retired_name"
  "LEG""ACY_"
  "mig""ration"
  "mig""rate_"
)
for pattern in "${retired_patterns[@]}"; do
  if grep -RFi -- "$pattern" "$ROOT_DIR/src" "$ROOT_DIR/sb.sh" >/dev/null; then
    fail "retired identity found in production sources"
  fi
done

hook_candidate=$(mktemp "${TMPDIR:-/tmp}/sb-verify-hook.XXXXXX") ||
  fail "cannot create hook candidate"
awk '/<<'\''ACMERELOAD'\''/{inside=1; next} /^ACMERELOAD$/{inside=0} inside' \
  "$ROOT_DIR/sb.sh" > "$hook_candidate"
[[ -s $hook_candidate ]] || fail "ACME reload hook extraction failed"
bash -n "$hook_candidate"
awk '
  $0 == "if [[ ! -s $config ]]; then" {
    getline initial_if
    getline initial_commit
    getline initial_post
    getline initial_exit
    getline initial_end
    getline rollback
    getline normal_exit
    getline block_end
    valid = initial_if == "  if [[ ${SB_INITIAL_INSTALL:-0} == 1 ]]; then" &&
      initial_commit == "    commit_deployment" &&
      initial_post == "    finalize_deployment" && initial_exit == "    exit 0" &&
      initial_end == "  fi" && rollback == "  rollback_deployment || true" &&
      normal_exit == "  exit 1" && block_end == "fi"
    exit
  }
  END { exit !valid }
' "$hook_candidate" || fail "ACME reload hook does not limit the missing-config bypass to initial install"
grep -Fqx "source_cert=\"\$source_dir/fullchain.pem\"" "$hook_candidate" ||
  fail "ACME reload hook does not read the staged full chain"
grep -Fqx "source_key=\"\$source_dir/private.key\"" "$hook_candidate" ||
  fail "ACME reload hook does not read the staged private key"
grep -Fqx "     ! mv -Tf -- \"\$pointer_tmp\" \"\$base/acme-live/current\"; then" "$hook_candidate" ||
  fail "ACME reload hook does not atomically switch the certificate generation"
grep -Fqx "     ! install_managed_link \"\$cert\" 'acme-live/current/fullchain.pem'; then" \
  "$hook_candidate" || fail "ACME certificate compatibility link is missing"
grep -Fqx "     ! install_managed_link \"\$key\" 'acme-live/current/private.key'; then" \
  "$hook_candidate" || fail "ACME private-key compatibility link is missing"
grep -Fqx '    restore_managed_links=1' "$hook_candidate" ||
  fail "ACME compatibility-link rollback marker is missing"
grep -Fqx 'post_reload="/etc/sb/acme_post_reload.sh"' "$hook_candidate" ||
  fail "ACME post-reload hook path is missing"
grep -Fqx 'run_post_reload_hook(){' "$hook_candidate" ||
  fail "ACME post-reload hook runner is missing"
grep -Fqx '    finalize_deployment' "$hook_candidate" ||
  fail "ACME initial-install path does not finalize the deployment"
grep -Fqx 'store_root="/etc/cert-store"' "$hook_candidate" ||
  fail "ACME reload hook does not know the shared certificate store"
grep -Fqx 'store_publish(){' "$hook_candidate" ||
  fail "ACME reload hook does not publish to the shared certificate store"
grep -Fqx 'finalize_deployment(){' "$hook_candidate" ||
  fail "ACME reload hook finalization wrapper is missing"
[[ $(grep -Fxc '  finalize_deployment' "$hook_candidate" || true) -eq 4 ]] ||
  fail "ACME reload hook does not finalize every renewal success path"
[[ $(grep -Fxc '  run_post_reload_hook' "$hook_candidate" || true) -eq 1 ]] ||
  fail "ACME reload hook post-reload wrapper is not called exactly once"
grep -Fqx 'warn_post_reload(){' "$hook_candidate" ||
  fail "ACME post-reload failure reporting is missing"
# shellcheck disable=SC2016  # the pattern is literal generated-hook text
grep -Fqx '    logger -t sb "acme post-reload: $1" 2>/dev/null || true' "$hook_candidate" ||
  fail "ACME post-reload failures are not logged to syslog"

issue_function=$(awk '/^issue_acme_certificate\(\)\{/{inside=1} /^inscertificate\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $issue_function ]] || fail "cannot extract ACME issue function"
grep -Fq -- "register_acme_certificate_deployment \"\$ACME_PRIMARY_DOMAIN\" \"\$initial_install\"" \
  <<< "$issue_function" || fail "ACME issuance does not use the managed deployment registration"
register_function=$(awk '/^register_acme_certificate_deployment\(\)\{/{inside=1} /^config_uses_acme_certificate\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $register_function ]] || fail "cannot extract ACME deployment registration"
# shellcheck disable=SC2016
grep -Fq -- 'SB_INITIAL_INSTALL="$initial_install" HOME="$SB_DIR" "$ACME_BIN"' \
  <<< "$register_function" || fail "ACME deployment does not mark initial-install hooks explicitly"
# shellcheck disable=SC2016
grep -Fq -- '--key-file "$ACME_STAGE_KEY" --fullchain-file "$ACME_STAGE_CERT"' \
  <<< "$register_function" || fail "acme.sh still writes certificate files outside the staging directory"
grep -Fq -- 'ACME_LOCK="/run/sb-acme.lock"' "$ROOT_DIR/sb.sh" ||
  fail "ACME lock is not independent from the removable sb directory"
# shellcheck disable=SC2016
grep -Fq -- 'ACME_COMPAT_LOCK="$SB_DIR/acme.lock"' "$ROOT_DIR/sb.sh" ||
  fail "v1.8.0 ACME lock compatibility is missing"
grep -Fq -- 'with_acme_lock resolve_orphaned_acme_state_backup || return 1' "$ROOT_DIR/sb.sh" ||
  fail "startup ACME recovery-point handling is missing"
inscertificate_function=$(awk '/^inscertificate\(\)\{/{inside=1} inside' "$ROOT_DIR/sb.sh")
[[ $(printf '%s\n' "$inscertificate_function" | grep -Fc -- 'issue_acme_certificate 1' || true) -eq 2 ]] ||
  fail "only initial installation may mark ACME install hooks as initial"

if command -v shellcheck >/dev/null 2>&1; then
  printf 'verify: shellcheck %s\n' "$(shellcheck --version | awk '/^version:/{print $2}')"
  shellcheck --shell=bash --severity=info "$ROOT_DIR/sb.sh"
  shellcheck --shell=bash --severity=info "$hook_candidate"
  shellcheck --shell=bash --severity=info \
    "$ROOT_DIR/scripts/build.sh" "$ROOT_DIR/scripts/check-version-bump.sh" \
    "$ROOT_DIR/tests/unit.sh" "$ROOT_DIR/tests/repair.sh" "$ROOT_DIR/tests/verify.sh"
else
  printf 'verify: shellcheck not found; static lint skipped\n' >&2
fi

bash "$ROOT_DIR/tests/unit.sh"
bash "$ROOT_DIR/tests/repair.sh"
# 行为回放：单测与修复测试把 commit_config、归属判定、安装入口都打桩了，
# 所以它们全绿并不代表菜单流程还能用。17 条菜单流程的落地结果在这里比对。
bash "$ROOT_DIR/tests/replay.sh"

digest=$(sha256sum "$ROOT_DIR/sb.sh" | awk '{print $1}')
printf 'verification passed: %s\n' "$digest"
