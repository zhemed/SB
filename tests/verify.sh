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
[[ $(grep -Fxc 'SS_METHOD="2022-blake3-aes-256-gcm"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "Shadowsocks-2022 cipher is not pinned to 2022-blake3-aes-256-gcm"
[[ $(grep -Fxc 'sb_version="v3.1.0"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "script version is not 3.1.0"
[[ $(tr -d '\r\n' < "$ROOT_DIR/VERSION") == '3.1.0' ]] ||
  fail "VERSION file is not 3.1.0"
grep -Fq -- "当前项目版本：\`3.1.0\`" "$ROOT_DIR/README.md" ||
  fail "README project version is not 3.1.0"
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
  'manage_ss_entry()' \
  'enable_ss_entry()' \
  'disable_ss_entry()' \
  'change_ss_port()' \
  '请选择【0-4】'; do
  grep -Fq -- "$lifecycle_pattern" "$ROOT_DIR/sb.sh" ||
    fail "missing installation lifecycle behavior: $lifecycle_pattern"
done
if grep -Fq -- 'green " 1. 安装/修复"' "$ROOT_DIR/sb.sh"; then
  fail "combined install/repair menu remains"
fi
[[ $(grep -Fxc 'SHORTCUT="/usr/bin/sb"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "formal shortcut identity is invalid"
[[ $(grep -Fxc '  readp "请输入 Cloudflare API Token：" cf_token || return 1' \
  "$ROOT_DIR/sb.sh" || true) -eq 1 ]] || fail "Cloudflare Token input is not visible"
if grep -Fq 'API Token 已读取' "$ROOT_DIR/sb.sh" ||
   grep -Fq '输入不回显' "$ROOT_DIR/sb.sh" ||
   grep -Eq 'read[^[:cntrl:]]+-s[^[:cntrl:]]+cf_token' "$ROOT_DIR/sb.sh"; then
  fail "hidden Cloudflare Token interaction remains"
fi

for success_message in \
  '证书模式切换成功' \
  'Hysteria2主端口修改成功' \
  'Shadowsocks-2022端口修改成功' \
  'IP优先级修改成功' \
  'Hysteria2 UUID（密码）修改成功' \
  'Shadowsocks-2022密钥修改成功'; do
  grep -Fq -- "$success_message" "$ROOT_DIR/sb.sh" ||
    fail "missing modification success message: $success_message"
done
# The dollar-prefixed strings below are literal generated-configuration text.
# shellcheck disable=SC2016
for ss_pattern in \
  'SS_METHOD="2022-blake3-aes-256-gcm"' \
  '"type": "shadowsocks"' \
  '"tag": "ss-sb"' \
  '"listen": "${listen_addr}"' \
  '"network": "tcp"' \
  '"method": "%s"' \
  'ss_entry_is_enabled()' \
  'ss_entry_candidate_with_inbound()' \
  'ss_entry_candidate_without_inbound()' \
  'ss_entry_enabled' \
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
  'resss()' \
  'change_ss_password()' \
  'valid_ss_password()' \
  'generate_ss_password()' \
  'ss://$(printf' \
  "base64 | tr -d '\\r\\n')@" \
  'ss.txt' \
  '"tag": "ss-%s"' \
  'type: ss' \
  'cipher: %s' \
  'udp: false' \
  'manage_relay()' \
  '当前配置里有一条上游出站，但' \
  'set_relay_upstream()' \
  'clear_relay_upstream()' \
  'Shadowsocks-2022 入口默认不安装' \
  '本次只安装 Hysteria2' \
  'remove_saved_ss_link()'; do
  grep -Fq -- "$ss_pattern" "$ROOT_DIR/sb.sh" ||
    fail "missing Shadowsocks-2022 integration: $ss_pattern"
done
# The plaintext SOCKS5 inbound and the dead comma-joined route rule are gone.
for removed_pattern in \
  '"tag": "socks5-sb"' \
  '"type": "socks"' \
  'type: socks5' \
  'SOCKS_USERNAME' \
  'valid_socks_password' \
  'change_socks_password' \
  'ressocks5' \
  'socks5.txt' \
  '"network": "udp,tcp"'; do
  if grep -Fq -- "$removed_pattern" "$ROOT_DIR/sb.sh"; then
    fail "retired SOCKS5 integration remains: $removed_pattern"
  fi
done
grep -Fq -- '请选择【0-1】' "$ROOT_DIR/sb.sh" ||
  fail "port management menu is missing"
# The install path must not create the optional inbound: only hysteria2.
install_function=$(awk '/^insport\(\)\{/{inside=1} /^render_server_config\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $install_function ]] || fail "cannot extract insport"
for optional_pattern in 'ss_password' 'port_ss' 'ss-sb' 'generate_ss_password'; do
  if printf '%s\n' "$install_function" | grep -Fq -- "$optional_pattern"; then
    fail "install flow still creates the optional Shadowsocks-2022 entry: $optional_pattern"
  fi
done
grep -Fq -- 'choose_ss_port()' "$ROOT_DIR/sb.sh" ||
  fail "optional entry port selection is missing"
[[ $(grep -Fc -- '按回车返回主菜单...' "$ROOT_DIR/sb.sh" || true) -ge 5 ]] ||
  fail "modification flows do not consistently wait before returning"

uuid_function=$(awk '/^changeuuid\(\)\{/{inside=1} /^change_ss_password\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $uuid_function ]] || fail "cannot extract UUID management function"
if printf '%s\n' "$uuid_function" | grep -Fq -- 'ss-sb'; then
  fail "UUID management still touches the Shadowsocks-2022 inbound"
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

# Node presentation order is uniform: Shadowsocks-2022 is listed before Hysteria2.
share_function=$(awk '/^sbshare\(\)\{/{inside=1} inside' "$ROOT_DIR/sb.sh")
[[ -n $share_function ]] || fail "cannot extract share generator"
# Compare byte offsets: the two generators sit on the same source line, so
# line numbers would compare equal and silently pass.
# `|| true` keeps `set -o pipefail` from aborting before the guard can report.
ss_share_off=$(printf '%s\n' "$share_function" | grep -bo 'resss ' | head -1 | cut -d: -f1 || true)
hy2_share_off=$(printf '%s\n' "$share_function" | grep -bo 'reshy2' | head -1 | cut -d: -f1 || true)
[[ -n $ss_share_off && -n $hy2_share_off ]] ||
  fail "cannot locate share generators in sbshare"
[[ $ss_share_off -lt $hy2_share_off ]] ||
  fail "share output lists Hysteria2 before Shadowsocks-2022"
# The optional entry is emitted through a printf fragment, so the SS-2022 tag is
# the literal `ss-%s` here while Hysteria2 keeps its inline `hy2-$hostname`.
# shellcheck disable=SC2016
ss_out_off=$(printf '%s\n' "$client_function" | grep -bo 'ss-%s' | head -1 | cut -d: -f1 || true)
# shellcheck disable=SC2016
hy2_out_off=$(printf '%s\n' "$client_function" | grep -bo 'hy2-\$hostname' | head -1 | cut -d: -f1 || true)
[[ -n $ss_out_off && -n $hy2_out_off && $ss_out_off -lt $hy2_out_off ]] ||
  fail "client configuration lists Hysteria2 before Shadowsocks-2022"

# Ordering must never be bought by making the TCP fallback entry the default.
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

grep -Fq -- '"network": "udp"' "$ROOT_DIR/sb.sh" ||
  fail "Shadowsocks-2022 UDP blocking route is missing"
grep -Fq -- 'Shadowsocks-2022 入口默认不安装' "$ROOT_DIR/sb.sh" ||
  fail "install does not state that the Shadowsocks-2022 entry is optional"
grep -Fq -- '密钥不可推导' "$ROOT_DIR/sb.sh" ||
  fail "Shadowsocks-2022 key-loss warning is missing"
grep -Fq -- '时间戳抗重放' "$ROOT_DIR/sb.sh" ||
  fail "Shadowsocks-2022 clock-synchronisation warning is missing"

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
    getline initial_exit
    getline initial_end
    getline rollback
    getline normal_exit
    getline block_end
    valid = initial_if == "  if [[ ${SB_INITIAL_INSTALL:-0} == 1 ]]; then" &&
      initial_commit == "    commit_deployment" && initial_exit == "    exit 0" &&
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

issue_function=$(awk '/^issue_cloudflare_certificate\(\)\{/{inside=1} /^inscertificate\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $issue_function ]] || fail "cannot extract ACME issue function"
grep -Fq -- "register_acme_certificate_deployment \"\$ACME_PRIMARY_DOMAIN\" \"\$initial_install\"" \
  <<< "$issue_function" || fail "ACME issuance does not use the managed deployment registration"
register_function=$(awk '/^register_acme_certificate_deployment\(\)\{/{inside=1} /^config_uses_acme_certificate\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $register_function ]] || fail "cannot extract ACME deployment registration"
# The dollar-prefixed names below are literal generated-script text.
# shellcheck disable=SC2016
grep -Fq -- 'SB_INITIAL_INSTALL="$initial_install" HOME="$SB_DIR" "$ACME_BIN"' \
  <<< "$register_function" || fail "ACME deployment does not mark initial-install hooks explicitly"
# shellcheck disable=SC2016
grep -Fq -- '--key-file "$ACME_STAGE_KEY" --fullchain-file "$ACME_STAGE_CERT"' \
  <<< "$register_function" || fail "acme.sh still writes certificate files outside the staging directory"
grep -Fq -- 'ACME_LOCK="/run/sb-acme.lock"' "$ROOT_DIR/sb.sh" ||
  fail "ACME lock is not independent from the removable sb directory"
# The dollar-prefixed name below is literal generated-script text.
# shellcheck disable=SC2016
grep -Fq -- 'ACME_COMPAT_LOCK="$SB_DIR/acme.lock"' "$ROOT_DIR/sb.sh" ||
  fail "v1.8.0 ACME lock compatibility is missing"
grep -Fq -- 'with_acme_lock resolve_orphaned_acme_state_backup || return 1' "$ROOT_DIR/sb.sh" ||
  fail "startup ACME recovery-point handling is missing"
inscertificate_function=$(awk '/^inscertificate\(\)\{/{inside=1} inside' "$ROOT_DIR/sb.sh")
[[ $(printf '%s\n' "$inscertificate_function" | grep -Fc -- 'issue_cloudflare_certificate 1' || true) -eq 2 ]] ||
  fail "only initial installation may mark ACME install hooks as initial"

if command -v shellcheck >/dev/null 2>&1; then
  # Print the version: the CI image ships a different ShellCheck than most dev
  # boxes, and a newer linter adds codes (SC2318 was the first to slip through a
  # green local gate). Seeing the version in the log is how that skew is spotted.
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

digest=$(sha256sum "$ROOT_DIR/sb.sh" | awk '{print $1}')
printf 'verification passed: %s\n' "$digest"
