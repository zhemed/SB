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
[[ $(grep -Fxc 'sb_version="v1.8.0"' "$ROOT_DIR/sb.sh" || true) -eq 1 ]] ||
  fail "script version is not 1.8.0"
[[ $(tr -d '\r\n' < "$ROOT_DIR/VERSION") == '1.8.0' ]] ||
  fail "VERSION file is not 1.8.0"
grep -Fq -- "当前项目版本：\`1.8.0\`" "$ROOT_DIR/README.md" ||
  fail "README project version is not 1.8.0"
for lifecycle_pattern in \
  'INSTALL_TRANSACTION_ACTIVE=0' \
  'cleanup_install_transaction()' \
  'cleanup_incomplete_install()' \
  'abort_install_transaction()' \
  'trap handle_install_interrupt INT TERM HUP' \
  'green " 1. 安装"' \
  'green " 2. 修复"' \
  'green " 9. 卸载"' \
  'readp "请输入数字 [0-9]: " Input'; do
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
  'VL reality SNI域名修改成功' \
  'Vless-reality端口修改成功' \
  'Hysteria2主端口修改成功' \
  'SOCKS5端口修改成功' \
  'IP优先级修改成功' \
  'VLESS/Hysteria2 UUID（密码）修改成功' \
  'SOCKS5独立密码修改成功'; do
  grep -Fq -- "$success_message" "$ROOT_DIR/sb.sh" ||
    fail "missing modification success message: $success_message"
done
for socks_pattern in \
  '"tag": "socks5-sb"' \
  'ressocks5()' \
  'change_socks_password()' \
  "\"password\": \"\${socks_password}\"" \
  "socks5://\$socks_username:\$socks_password@\$server_ip:\$socks_port" \
  '"type": "socks"' \
  'type: socks5' \
  '"network": "tcp"' \
  'udp: false' \
  "socks5-\$hostname"; do
  grep -Fq -- "$socks_pattern" "$ROOT_DIR/sb.sh" ||
    fail "missing SOCKS5 integration: $socks_pattern"
done
grep -Fq -- '请选择【0-3】' "$ROOT_DIR/sb.sh" ||
  fail "SOCKS5 port is missing from management menu"
[[ $(grep -Fc -- '按回车返回主菜单...' "$ROOT_DIR/sb.sh" || true) -ge 5 ]] ||
  fail "modification flows do not consistently wait before returning"

uuid_function=$(awk '/^changeuuid\(\)\{/{inside=1} /^change_socks_password\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $uuid_function ]] || fail "cannot extract UUID management function"
if printf '%s\n' "$uuid_function" | grep -Fq -- 'socks5-sb'; then
  fail "UUID management still modifies SOCKS5 credentials"
fi

client_function=$(awk '/^sb_client\(\)\{/{inside=1} /^sbshare\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $client_function ]] || fail "cannot extract client configuration generator"
auto_block=$(printf '%s\n' "$client_function" |
  awk '/"tag": "auto"/{inside=1} inside{print} inside && /"type": "direct"/{exit}')
[[ -n $auto_block ]] || fail "cannot extract Sing-box urltest block"
if printf '%s\n' "$auto_block" | grep -Fq -- 'socks5-'; then
  fail "SOCKS5 must not participate in Sing-box automatic testing"
fi
clash_auto_block=$(printf '%s\n' "$client_function" |
  awk '/^- name: 负载均衡/{inside=1} inside{print} /^- name: 🌍选择代理节点/{exit}')
[[ -n $clash_auto_block ]] || fail "cannot extract Clash automatic groups"
if printf '%s\n' "$clash_auto_block" | grep -Fq -- 'socks5-'; then
  fail "SOCKS5 must not participate in Clash automatic groups"
fi

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
  fail "SOCKS5 UDP blocking route is missing"
grep -Fq -- 'SOCKS5本身不加密' "$ROOT_DIR/sb.sh" ||
  fail "SOCKS5 plaintext warning is missing"

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
    getline initial_guard
    getline normal_rejection
    getline block_end
    valid = initial_guard == "  [[ ${SB_INITIAL_INSTALL:-0} == 1 ]] && exit 0" &&
      normal_rejection == "  exit 1" && block_end == "fi"
    exit
  }
  END { exit !valid }
' "$hook_candidate" || fail "ACME reload hook does not limit the missing-config bypass to initial install"

issue_function=$(awk '/^issue_cloudflare_certificate\(\)\{/{inside=1} /^inscertificate\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/sb.sh")
[[ -n $issue_function ]] || fail "cannot extract ACME issue function"
# The dollar-prefixed names below are literal generated-script text.
# shellcheck disable=SC2016
[[ $(printf '%s\n' "$issue_function" | grep -Fc -- 'SB_INITIAL_INSTALL=1 HOME="$SB_DIR" "$ACME_BIN"' || true) -eq 1 ]] ||
  fail "initial ACME install is not explicitly marked"
# shellcheck disable=SC2016
[[ $(printf '%s\n' "$issue_function" | grep -Fc -- 'SB_INITIAL_INSTALL=0 HOME="$SB_DIR" "$ACME_BIN"' || true) -eq 1 ]] ||
  fail "non-initial ACME install does not clear the initial-install marker"
inscertificate_function=$(awk '/^inscertificate\(\)\{/{inside=1} inside' "$ROOT_DIR/sb.sh")
[[ $(printf '%s\n' "$inscertificate_function" | grep -Fc -- 'issue_cloudflare_certificate 1' || true) -eq 2 ]] ||
  fail "only initial installation may mark ACME install hooks as initial"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --shell=bash --severity=info "$ROOT_DIR/sb.sh"
  shellcheck --shell=bash --severity=info "$hook_candidate"
  shellcheck --shell=bash --severity=info \
    "$ROOT_DIR/scripts/build.sh" "$ROOT_DIR/tests/unit.sh" "$ROOT_DIR/tests/verify.sh"
else
  printf 'verify: shellcheck not found; static lint skipped\n' >&2
fi

bash "$ROOT_DIR/tests/unit.sh"

digest=$(sha256sum "$ROOT_DIR/sb.sh" | awk '{print $1}')
printf 'verification passed: %s\n' "$digest"
