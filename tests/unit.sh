#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
readonly ROOT_DIR TEMP_DIR
trap 'rm -rf -- "$TEMP_DIR"' EXIT

passed=0

pass(){
  passed=$((passed + 1))
  printf 'ok %d - %s\n' "$passed" "$1"
}

fail(){
  printf 'not ok %d - %s\n' "$((passed + 1))" "$1" >&2
  exit 1
}

expect_success(){
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

expect_failure(){
  local name=$1
  shift
  if "$@"; then fail "$name"; else pass "$name"; fi
}

# Production concatenates these files. Tests may source definition-only modules.
# shellcheck source=/dev/null
source "$ROOT_DIR/src/20-ports.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/10-acme.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/60-cron.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/80-lifecycle.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/70-management.sh"

export SB_DIR=/etc/sb
export SB_CONFIG="$SB_DIR/sb.json"
export SB_SERVICE=sb
export SOCKS_USERNAME=sb
export SHORTCUT=/usr/bin/sb
export ACME_HOME="$SB_DIR/acme"
export ACME_BIN="$ACME_HOME/acme.sh"
export ACME_RELOAD="$SB_DIR/acme_reload.sh"
export ACME_RELOAD_IDENTITY="# sb-acme-reload-v1"
export ACME_CRON_MARKER="# sb-managed-acme"
export RESTART_CRON_MARKER="# sb-managed-restart"

expect_success "port 443 is valid" valid_port 443
expect_success "port 1 is valid" valid_port 1
expect_success "port 65535 is valid" valid_port 65535
expect_failure "port 0 is invalid" valid_port 0
expect_failure "port 65536 is invalid" valid_port 65536
expect_failure "non-numeric port is invalid" valid_port abc

expect_success "hostname is valid" valid_hostname sub.example.com
expect_failure "single-label hostname is invalid" valid_hostname localhost
expect_success "UUID is valid" valid_uuid 123e4567-e89b-12d3-a456-426614174000
expect_failure "malformed UUID is invalid" valid_uuid 123e4567
expect_success "16-character SOCKS password is valid" valid_socks_password 0123456789abcdef
expect_success "safe SOCKS password punctuation is valid" valid_socks_password 'abcDEF0123._~-xyz'
expect_failure "15-character SOCKS password is invalid" valid_socks_password 0123456789abcde
expect_failure "SOCKS password with a space is invalid" valid_socks_password 'bad password value'
expect_failure "SOCKS password with a colon is invalid" valid_socks_password 'bad:password:value'
socks_password_128=$(printf 'a%.0s' {1..128})
socks_password_129="${socks_password_128}a"
expect_success "128-character SOCKS password is valid" valid_socks_password "$socks_password_128"
expect_failure "129-character SOCKS password is invalid" valid_socks_password "$socks_password_129"
expect_success "Cloudflare Account ID is valid" \
  valid_cloudflare_account_id 0123456789ABCDEF0123456789abcdef
expect_failure "short Cloudflare Account ID is invalid" valid_cloudflare_account_id 01234567
expect_failure "31-character Account ID is invalid" \
  valid_cloudflare_account_id 0123456789abcdef0123456789abcde
expect_failure "non-hex Account ID is invalid" \
  valid_cloudflare_account_id 0123456789abcdef0123456789abcdeg

normalize_acme_domain ' Example.COM. ' || fail "single-domain normalization"
[[ $ACME_PRIMARY_DOMAIN == example.com && -z $ACME_WILDCARD_DOMAIN ]] ||
  fail "single-domain normalization values"
pass "single-domain normalization"

normalize_acme_domain '*.Example.COM' || fail "wildcard normalization"
[[ $ACME_PRIMARY_DOMAIN == example.com && $ACME_WILDCARD_DOMAIN == '*.example.com' ]] ||
  fail "wildcard normalization values"
pass "wildcard normalization"
expect_failure "embedded wildcard is invalid" normalize_acme_domain 'api.*.example.com'
expect_failure "leading-hyphen label is invalid" normalize_acme_domain '-bad.example.com'
expect_failure "trailing-hyphen label is invalid" normalize_acme_domain 'bad-.example.com'
expect_failure "empty domain label is invalid" normalize_acme_domain 'bad..example.com'
expect_failure "single-label ACME domain is invalid" normalize_acme_domain localhost

expected_cron=$(acme_renew_cron_entry)
expect_success "canonical ACME cron is current" acme_renew_cron_is_current "$expected_cron"
expect_success "user cron may coexist" acme_renew_cron_is_current \
  "15 2 * * * /root/user-task
$expected_cron"
expect_failure "marker-only ACME cron is stale" acme_renew_cron_is_current '# sb-managed-acme'
expect_failure "wrong ACME command is stale" acme_renew_cron_is_current \
  '0 0 * * * false # sb-managed-acme'
expect_failure "duplicate ACME cron is stale" acme_renew_cron_is_current \
  "$expected_cron
$expected_cron"

ACME_RELOAD="$TEMP_DIR/acme_reload.sh"
printf '%s\n' '#!/bin/bash' "$ACME_RELOAD_IDENTITY" > "$ACME_RELOAD"
chmod 700 "$ACME_RELOAD"
expect_failure "marker-only ACME hook is stale" acme_reload_hook_is_current
printf '%s\n' '#!/bin/bash' > "$ACME_RELOAD"
chmod 700 "$ACME_RELOAD"
expect_failure "unversioned ACME hook is stale" acme_reload_hook_is_current

expect_success "generated sb.sh has formal identity" script_copy_has_identity "$ROOT_DIR/sb.sh"
printf '%s\n' '#!/bin/bash' > "$TEMP_DIR/foreign.sh"
expect_failure "foreign script has no formal identity" script_copy_has_identity "$TEMP_DIR/foreign.sh"

MOCK_TCP_PORTS=443
MOCK_UDP_PORTS=
ss(){
  local state ports port
  case " $* " in
    *" -lnt "*) state=LISTEN; ports=$MOCK_TCP_PORTS ;;
    *" -lnu "*) state=UNCONN; ports=$MOCK_UDP_PORTS ;;
    *) return 2 ;;
  esac
  for port in $ports; do
    printf '%s 0 4096 0.0.0.0:%s 0.0.0.0:*\n' "$state" "$port"
  done
}

expect_success "TCP 443 conflict is detected" port_conflict 443 tcp
expect_failure "TCP 443 does not block UDP 443" port_conflict 443 udp
MOCK_TCP_PORTS=
MOCK_UDP_PORTS=443
expect_success "UDP 443 conflict is detected" port_conflict 443 udp
expect_failure "UDP 443 does not block TCP 443" port_conflict 443 tcp

STATE_DIR="$TEMP_DIR/state"
export SB_DIR="$STATE_DIR/sb"
export SB_CONFIG="$SB_DIR/sb.json"
export ACME_HOME="$SB_DIR/acme"
export ACME_BIN="$ACME_HOME/acme.sh"
export ACME_RELOAD="$SB_DIR/acme_reload.sh"
export ACME_IDENTITY="$SB_DIR/acme_server_name"
CRONTAB_FILE="$STATE_DIR/crontab"
mkdir -p "$ACME_HOME/dnsapi"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$ACME_BIN"
printf '%s\n' '# dns_cf fixture' > "$ACME_HOME/dnsapi/dns_cf.sh"
printf '%s\n' 'example.com' > "$ACME_IDENTITY"
chmod 700 "$ACME_BIN"

MOCK_CRON_DAEMON_ACTIVE=1
cron_daemon_is_active(){
  [[ $MOCK_CRON_DAEMON_ACTIVE -eq 1 ]]
}

crontab(){
  case ${1-} in
    -l)
      if [[ -f $CRONTAB_FILE ]]; then
        cat "$CRONTAB_FILE"
      else
        printf 'no crontab for root\n' >&2
        return 1
      fi
      ;;
    -) cat > "$CRONTAB_FILE" ;;
    *) return 2 ;;
  esac
}

MOCK_CONFIG_USES_ACME=1
MOCK_CONFIG_USES_SELF_SIGNED=0
config_uses_acme_certificate(){
  [[ $MOCK_CONFIG_USES_ACME -eq 1 ]]
}
config_uses_self_signed_certificate(){
  [[ $MOCK_CONFIG_USES_SELF_SIGNED -eq 1 ]]
}
# Called indirectly by sourced cron functions.
# shellcheck disable=SC2317
red(){ :; }

user_cron='5 4 * * * /root/user-task'
bad_cron="0 0 * * * false $ACME_CRON_MARKER"
old_cron="0 1 * * * $SB_DIR/cert_renew.sh"
printf '%s\n' "$user_cron" "$bad_cron" "$old_cron" > "$CRONTAB_FILE"
cron_hash=$(sha256sum "$CRONTAB_FILE" | awk '{print $1}')
MOCK_CRON_DAEMON_ACTIVE=0
expect_failure "ACME cron setup rejects an inactive daemon" setup_acme_renew_cron
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "inactive daemon changed existing cron"
pass "inactive daemon preserves existing cron"
MOCK_CRON_DAEMON_ACTIVE=1
expect_success "ACME cron setup succeeds" setup_acme_renew_cron

expected_cron=$(acme_renew_cron_entry)
cron_is_normalized(){
  [[ $(grep -Fxc -- "$user_cron" "$CRONTAB_FILE" || true) -eq 1 ]] &&
    [[ $(grep -Fxc -- "$expected_cron" "$CRONTAB_FILE" || true) -eq 1 ]] &&
    [[ $(grep -Fc -- "$ACME_CRON_MARKER" "$CRONTAB_FILE" || true) -eq 1 ]] &&
    ! grep -Fq -- "$SB_DIR/cert_renew.sh" "$CRONTAB_FILE"
}
expect_success "ACME cron is normalized and preserves user tasks" cron_is_normalized

cron_hash=$(sha256sum "$CRONTAB_FILE" | awk '{print $1}')
expect_success "repeated ACME cron setup succeeds" setup_acme_renew_cron
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "ACME cron setup is byte-idempotent"
pass "ACME cron setup is byte-idempotent"

MOCK_CRON_DAEMON_ACTIVE=0
expect_failure "ACME ensure rejects an inactive daemon" ensure_acme_renew_cron
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "inactive daemon ensure changed canonical cron"
pass "inactive daemon ensure preserves canonical cron"
MOCK_CRON_DAEMON_ACTIVE=1

rm -f "$ACME_HOME/dnsapi/dns_cf.sh"
expect_failure "ACME ensure rejects missing DNS component" ensure_acme_renew_cron
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "missing ACME component changed canonical cron"
pass "missing ACME component preserves canonical cron"
printf '%s\n' '# dns_cf fixture' > "$ACME_HOME/dnsapi/dns_cf.sh"

MOCK_CONFIG_USES_ACME=0
expect_failure "ACME ensure preserves cron for unknown certificate mode" ensure_acme_renew_cron
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "unknown certificate mode changed canonical cron"
pass "unknown certificate mode preserves canonical cron"
MOCK_CONFIG_USES_ACME=1

expect_success "generated ACME hook is current" acme_reload_hook_is_current
expect_success "generated ACME hook passes bash -n" bash -n "$ACME_RELOAD"
cp "$ACME_RELOAD" "$TEMP_DIR/good-acme-reload.sh"
grep -Fv '  systemctl restart sb >/dev/null 2>&1 || exit 1' \
  "$TEMP_DIR/good-acme-reload.sh" > "$ACME_RELOAD"
chmod 700 "$ACME_RELOAD"
expect_failure "ACME hook missing restart logic is stale" acme_reload_hook_is_current
cp "$TEMP_DIR/good-acme-reload.sh" "$ACME_RELOAD"
chmod 700 "$ACME_RELOAD"
expect_success "complete ACME hook is current" acme_reload_hook_is_current
if compgen -G "$SB_DIR/.acme_reload.*" >/dev/null; then
  fail "ACME hook left a temporary file"
fi
pass "ACME hook leaves no temporary file"

printf '%s\n' '#!/bin/bash' '# old hook' > "$ACME_RELOAD"
chmod 700 "$ACME_RELOAD"
expect_success "ensure refreshes an old executable hook" ensure_acme_renew_cron
expect_success "refreshed ACME hook is current" acme_reload_hook_is_current
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "hook refresh changed canonical cron"
pass "hook refresh preserves canonical cron"

hook_hash=$(sha256sum "$ACME_RELOAD" | awk '{print $1}')
expect_success "ensure accepts the current hook" ensure_acme_renew_cron
[[ $(sha256sum "$ACME_RELOAD" | awk '{print $1}') == "$hook_hash" ]] ||
  fail "current hook was rewritten"
pass "current hook is byte-idempotent"

export ACME_RELOAD="$SB_DIR/failure-hook.sh"
printf '%s\n' '#!/bin/bash' '# preserved' > "$ACME_RELOAD"
chmod 700 "$ACME_RELOAD"
# Called indirectly by the sourced write_acme_reload_hook function.
# shellcheck disable=SC2317
mv(){ return 1; }
expect_failure "hook replacement reports atomic move failure" write_acme_reload_hook
unset -f mv
grep -Fqx '# preserved' "$ACME_RELOAD" || fail "failed replacement changed the old hook"
pass "failed hook replacement preserves the old file"
if compgen -G "$SB_DIR/.acme_reload.*" >/dev/null; then
  fail "failed hook replacement left a temporary file"
fi
pass "failed hook replacement cleans temporary files"

export ACME_RELOAD="$SB_DIR/hook-directory"
mkdir "$ACME_RELOAD"
expect_failure "hook writer rejects a directory target" write_acme_reload_hook

cron_hash=$(sha256sum "$CRONTAB_FILE" | awk '{print $1}')
MOCK_CRON_DAEMON_ACTIVE=0
expect_failure "daily restart cron rejects an inactive daemon" cronsb
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "inactive daemon changed cron while adding daily restart"
pass "inactive daemon preserves cron while adding daily restart"
MOCK_CRON_DAEMON_ACTIVE=1
expect_success "daily restart cron setup succeeds" cronsb
[[ $(grep -Fc -- "$RESTART_CRON_MARKER" "$CRONTAB_FILE" || true) -eq 1 ]] ||
  fail "daily restart cron is missing or duplicated"
pass "daily restart cron is canonical"
[[ $(grep -Fc -- "$ACME_CRON_MARKER" "$CRONTAB_FILE" || true) -eq 1 ]] ||
  fail "daily restart setup changed the ACME cron"
pass "daily restart setup preserves ACME cron"

UUID_ONE=11111111-1111-4111-8111-111111111111
UUID_TWO=22222222-2222-4222-8222-222222222222
UUID_ORIGINAL=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
SOCKS_PASSWORD_ORIGINAL='Socks.Original_123'
SOCKS_PASSWORD_ONE='Socks.Pass_One-1234'
SOCKS_PASSWORD_TWO='Socks.Pass_Two-5678'
FLOW_RESPONSES=()
FLOW_RESPONSE_INDEX=0
FLOW_MESSAGES=
FLOW_PROMPTS=
COMMIT_RESULTS=()
COMMIT_INDEX=0
LAST_GENERATED_UUID=
LAST_UUID_FILTER=
LAST_GENERATED_SOCKS_PASSWORD=
LAST_GENERATED_SOCKS_USERNAME=
LAST_SOCKS_FILTER=
LAST_COMMITTED_CANDIDATE=

readp(){
  local prompt=$1 target=${2-} response
  FLOW_PROMPTS+="$prompt"$'\n'
  [[ $FLOW_RESPONSE_INDEX -lt ${#FLOW_RESPONSES[@]} ]] || return 1
  response=${FLOW_RESPONSES[$FLOW_RESPONSE_INDEX]}
  FLOW_RESPONSE_INDEX=$((FLOW_RESPONSE_INDEX + 1))
  if [[ -n $target ]]; then
    printf -v "$target" '%s' "$response"
  else
    REPLY=$response
  fi
}

# Called indirectly by the sourced changeuuid function.
# shellcheck disable=SC2317
red(){ FLOW_MESSAGES+="red:$1"$'\n'; }
# shellcheck disable=SC2317
green(){ FLOW_MESSAGES+="green:$1"$'\n'; }
# shellcheck disable=SC2317
yellow(){ FLOW_MESSAGES+="yellow:$1"$'\n'; }
# shellcheck disable=SC2317
blue(){ FLOW_MESSAGES+="blue:$1"$'\n'; }
# shellcheck disable=SC2317
sbactive(){ return 0; }
# shellcheck disable=SC2317
sbshare(){ return 0; }
# shellcheck disable=SC2317
jq(){
  local filter candidate_socks candidate_uuid
  case ${1-} in
    -er)
      filter=${2-}
      if [[ $filter == *'socks5-sb'* ]]; then
        printf '%s\n' "$SOCKS_PASSWORD_ORIGINAL"
      else
        printf '%s\n' "$UUID_ORIGINAL"
      fi
      ;;
    --arg)
      case ${2-} in
        uuid)
          LAST_GENERATED_UUID=${3-}
          LAST_UUID_FILTER=${4-}
          candidate_socks=$SOCKS_PASSWORD_ORIGINAL
          if [[ $LAST_UUID_FILTER == *'socks5-sb'* || $LAST_UUID_FILTER == *'type == "socks"'* ]]; then
            candidate_socks=$LAST_GENERATED_UUID
          fi
          printf '{"candidate":true,"uuid":"%s","socks_password":"%s"}\n' \
            "$LAST_GENERATED_UUID" "$candidate_socks"
          ;;
        password)
          LAST_GENERATED_SOCKS_PASSWORD=${3-}
          LAST_GENERATED_SOCKS_USERNAME=${6-}
          LAST_SOCKS_FILTER=${7-}
          candidate_uuid=$UUID_ORIGINAL
          if [[ $LAST_SOCKS_FILTER == *'vless-sb'* || $LAST_SOCKS_FILTER == *'hy2-sb'* ]]; then
            candidate_uuid=$LAST_GENERATED_SOCKS_PASSWORD
          fi
          printf '{"candidate":true,"uuid":"%s","socks_password":"%s","socks_username":"%s"}\n' \
            "$candidate_uuid" "$LAST_GENERATED_SOCKS_PASSWORD" "$LAST_GENERATED_SOCKS_USERNAME"
          ;;
        *) return 2 ;;
      esac
      ;;
    -e) return 0 ;;
    *) return 2 ;;
  esac
}
# shellcheck disable=SC2317
commit_config(){
  local candidate_path=$1 result=${COMMIT_RESULTS[$COMMIT_INDEX]:-0}
  LAST_COMMITTED_CANDIDATE=$(<"$candidate_path")
  COMMIT_INDEX=$((COMMIT_INDEX + 1))
  rm -f "$candidate_path"
  return "$result"
}

export SB_DIR="$TEMP_DIR/credentials"
export SB_CONFIG="$SB_DIR/sb.json"
export SB_BIN="$SB_DIR/sing-box"
mkdir -p "$SB_DIR"
printf '%s\n' '{"fixture":true}' > "$SB_CONFIG"

FLOW_RESPONSES=('invalid' "$UUID_ONE" '' "$UUID_TWO" '')
FLOW_RESPONSE_INDEX=0
FLOW_MESSAGES=
FLOW_PROMPTS=
COMMIT_RESULTS=(1 0)
COMMIT_INDEX=0
expect_success "UUID flow retries failures and then succeeds" changeuuid
[[ $COMMIT_INDEX -eq 2 ]] || fail "UUID flow did not retry the failed commit"
pass "UUID flow retries the failed commit"
[[ $LAST_GENERATED_UUID == "$UUID_TWO" ]] || fail "UUID flow did not commit the final value"
pass "UUID flow commits the final value"
[[ $LAST_UUID_FILTER != *'socks5-sb'* && $LAST_UUID_FILTER != *'type == "socks"'* ]] ||
  fail "UUID flow unexpectedly targets SOCKS5"
pass "UUID flow does not target SOCKS5"
[[ $LAST_COMMITTED_CANDIDATE == *"\"socks_password\":\"$SOCKS_PASSWORD_ORIGINAL\""* ]] ||
  fail "UUID flow changed the SOCKS5 password"
pass "UUID flow preserves the SOCKS5 password"
[[ $FLOW_MESSAGES == *'UUID格式错误'* ]] || fail "UUID format failure was not shown"
pass "UUID format failure is shown"
[[ $FLOW_MESSAGES == *'UUID修改失败，原配置未修改或已恢复'* ]] ||
  fail "UUID commit failure was not shown"
pass "UUID commit failure is shown"
[[ $FLOW_MESSAGES == *"VLESS/Hysteria2 UUID（密码）修改成功：$UUID_TWO"* ]] ||
  fail "UUID success was not shown"
pass "UUID success is shown"
[[ $FLOW_PROMPTS == *'按回车返回凭据菜单...'* ]] || fail "UUID success did not wait for return"
pass "UUID success waits before returning"

FLOW_RESPONSES=("$UUID_ONE" '')
FLOW_RESPONSE_INDEX=0
FLOW_MESSAGES=
FLOW_PROMPTS=
COMMIT_RESULTS=(2)
COMMIT_INDEX=0
expect_failure "UUID flow stops when automatic rollback fails" changeuuid
[[ $FLOW_MESSAGES == *'自动回滚失败'* ]] || fail "UUID rollback failure was not shown"
pass "UUID rollback failure is shown"
[[ $FLOW_RESPONSE_INDEX -eq 2 ]] || fail "UUID rollback failure did not wait before returning"
pass "UUID rollback failure waits before returning"

FLOW_RESPONSES=('bad password value' "$SOCKS_PASSWORD_ONE" '' "$SOCKS_PASSWORD_TWO" '')
FLOW_RESPONSE_INDEX=0
FLOW_MESSAGES=
FLOW_PROMPTS=
COMMIT_RESULTS=(1 0)
COMMIT_INDEX=0
expect_success "SOCKS password flow retries failures and then succeeds" change_socks_password
[[ $COMMIT_INDEX -eq 2 ]] || fail "SOCKS password flow did not retry the failed commit"
pass "SOCKS password flow retries the failed commit"
[[ $LAST_GENERATED_SOCKS_PASSWORD == "$SOCKS_PASSWORD_TWO" ]] ||
  fail "SOCKS password flow did not commit the final value"
pass "SOCKS password flow commits the final value"
[[ $LAST_GENERATED_SOCKS_USERNAME == sb ]] || fail "SOCKS password flow changed the username"
pass "SOCKS password flow preserves the fixed username"
[[ $LAST_SOCKS_FILTER != *'vless-sb'* && $LAST_SOCKS_FILTER != *'hy2-sb'* ]] ||
  fail "SOCKS password flow unexpectedly targets UUID protocols"
pass "SOCKS password flow does not target UUID protocols"
[[ $LAST_COMMITTED_CANDIDATE == *"\"uuid\":\"$UUID_ORIGINAL\""* ]] ||
  fail "SOCKS password flow changed the VLESS/Hysteria2 UUID"
pass "SOCKS password flow preserves the VLESS/Hysteria2 UUID"
[[ $FLOW_MESSAGES == *'SOCKS5密码必须为16-128位'* ]] ||
  fail "SOCKS password format failure was not shown"
pass "SOCKS password format failure is shown"
[[ $FLOW_MESSAGES == *'SOCKS5密码修改失败，原配置未修改或已恢复'* ]] ||
  fail "SOCKS password commit failure was not shown"
pass "SOCKS password commit failure is shown"
[[ $FLOW_MESSAGES == *"SOCKS5独立密码修改成功：$SOCKS_PASSWORD_TWO"* ]] ||
  fail "SOCKS password success was not shown"
pass "SOCKS password success is shown"
[[ $FLOW_PROMPTS == *'按回车返回凭据菜单...'* ]] ||
  fail "SOCKS password success did not wait for return"
pass "SOCKS password success waits before returning"

FLOW_RESPONSES=("$SOCKS_PASSWORD_ONE" '')
FLOW_RESPONSE_INDEX=0
FLOW_MESSAGES=
FLOW_PROMPTS=
COMMIT_RESULTS=(2)
COMMIT_INDEX=0
expect_failure "SOCKS password flow stops when automatic rollback fails" change_socks_password
[[ $FLOW_MESSAGES == *'自动回滚失败'* ]] ||
  fail "SOCKS password rollback failure was not shown"
pass "SOCKS password rollback failure is shown"
[[ $FLOW_RESPONSE_INDEX -eq 2 ]] ||
  fail "SOCKS password rollback failure did not wait before returning"
pass "SOCKS password rollback failure waits before returning"

CREDENTIAL_UUID_CALLS=0
CREDENTIAL_SOCKS_CALLS=0
changeuuid(){ CREDENTIAL_UUID_CALLS=$((CREDENTIAL_UUID_CALLS + 1)); }
change_socks_password(){ CREDENTIAL_SOCKS_CALLS=$((CREDENTIAL_SOCKS_CALLS + 1)); }
FLOW_RESPONSES=(1 2 9 0)
FLOW_RESPONSE_INDEX=0
FLOW_MESSAGES=
FLOW_PROMPTS=
expect_success "credential menu dispatches both credential flows" change_credentials
[[ $CREDENTIAL_UUID_CALLS -eq 1 && $CREDENTIAL_SOCKS_CALLS -eq 1 ]] ||
  fail "credential menu did not dispatch both flows exactly once"
pass "credential menu dispatches both flows exactly once"
[[ $FLOW_MESSAGES == *'请输入0、1或2'* ]] || fail "credential menu invalid choice was not shown"
pass "credential menu reports invalid choices"

printf '1..%d\n' "$passed"
