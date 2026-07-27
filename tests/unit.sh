#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
readonly ROOT_DIR TEMP_DIR
trap 'rm -rf -- "$TEMP_DIR"' EXIT

TEST_HAS_SYSTEM_FLOCK=1
if ! command -v flock >/dev/null 2>&1; then
  TEST_HAS_SYSTEM_FLOCK=0
  mkdir -p "$TEMP_DIR/test-bin"
  printf '%s\n' '#!/bin/bash' 'exit 0' > "$TEMP_DIR/test-bin/flock"
  chmod 700 "$TEMP_DIR/test-bin/flock"
  export PATH="$TEMP_DIR/test-bin:$PATH"
fi

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

# The production bootstrap provides this dependency to certificate metadata helpers.
sanitize_location(){
  tr '\r\n\t' '   ' | sed 's/[[:cntrl:]]//g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-160
}

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
export ACME_CERT="$SB_DIR/acme-cert.pem"
export ACME_KEY="$SB_DIR/acme-private.key"
CRONTAB_FILE="$STATE_DIR/crontab"
mkdir -p "$ACME_HOME/dnsapi"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$ACME_BIN"
printf '%s\n' '# dns_cf fixture' > "$ACME_HOME/dnsapi/dns_cf.sh"
printf '%s\n' \
  "SAVED_CF_Token='fixture_token_123'" \
  "SAVED_CF_Account_ID='0123456789abcdef0123456789abcdef'" > "$ACME_HOME/account.conf"
printf '%s\n' 'example.com' > "$ACME_IDENTITY"
chmod 700 "$ACME_BIN"

DOMAIN_CONF_DIR="$ACME_HOME/certs/example.com_ecc"
DOMAIN_CONF="$DOMAIN_CONF_DIR/example.com.conf"
DOMAIN_CONF_MARKER="$STATE_DIR/domain-conf-command-ran"
mkdir -p "$DOMAIN_CONF_DIR"

write_domain_conf_fixture(){
  printf '%s\n' "$@" > "$DOMAIN_CONF"
  chmod 600 "$DOMAIN_CONF"
}

read_acme_domain_conf_value_quiet(){
  read_acme_domain_conf_value "$@" >/dev/null
}

write_domain_conf_fixture \
  "Le_Domain='example.com'" \
  "Le_API='https://acme-v02.api.letsencrypt.org/directory'" \
  "Le_CertCreateTime='1700000000'" \
  "Le_NextRenewTime='1702592000'" \
  "Le_InstallCertSuccessTime='1700000030'" \
  "Unrelated_Field='\$(touch $DOMAIN_CONF_MARKER)'"
expect_success "strict ACME domain value is readable" \
  read_acme_domain_conf_value_quiet example.com Le_Domain
[[ ! -e $DOMAIN_CONF_MARKER ]] || fail "ACME domain parser executed an unrelated config value"
pass "ACME domain parser does not execute unrelated config values"
expect_success "complete ACME certificate schedule is readable" \
  load_acme_certificate_schedule example.com
[[ $ACME_META_CREATED_EPOCH == 1700000000 &&
   $ACME_META_NEXT_RENEW_EPOCH == 1702592000 &&
   $ACME_META_DEPLOYED_EPOCH == 1700000030 &&
   $ACME_META_CREATED == *UTC && $ACME_META_NEXT_RENEW == *UTC ]] ||
  fail "ACME certificate schedule has unexpected values"
pass "ACME certificate schedule exposes canonical timestamps"
expect_failure "ACME domain parser rejects unknown requested fields" \
  read_acme_domain_conf_value example.com Le_ReloadCmd
expect_failure "ACME domain parser rejects path traversal identities" \
  read_acme_domain_conf_value '../example.com' Le_Domain

write_domain_conf_fixture \
  "Le_Domain='example.com'" \
  "Le_Domain='duplicate.example.com'"
expect_failure "ACME domain parser rejects duplicate fields" \
  read_acme_domain_conf_value example.com Le_Domain

write_domain_conf_fixture \
  "Le_CertCreateTime='1700000000'; touch '$DOMAIN_CONF_MARKER'; value='1'"
expect_failure "ACME domain parser rejects injected field values" \
  read_acme_domain_conf_value example.com Le_CertCreateTime
[[ ! -e $DOMAIN_CONF_MARKER ]] || fail "ACME domain parser executed an injected field value"
pass "ACME domain parser does not execute injected field values"

write_domain_conf_fixture "Le_CertCreateTime='not-a-timestamp'"
expect_failure "ACME domain parser rejects non-numeric timestamps" \
  read_acme_domain_conf_value example.com Le_CertCreateTime
write_domain_conf_fixture "Le_CertCreateTime='1234567890123'"
expect_failure "ACME domain parser rejects oversized timestamps" \
  read_acme_domain_conf_value example.com Le_CertCreateTime
write_domain_conf_fixture "Le_API='https://attacker.invalid/directory'"
expect_failure "ACME domain parser rejects an unexpected CA endpoint" \
  read_acme_domain_conf_value example.com Le_API
write_domain_conf_fixture $'Le_Domain=\'example.com\'\r'
expect_failure "ACME domain parser rejects carriage returns" \
  read_acme_domain_conf_value example.com Le_Domain

write_domain_conf_fixture \
  "Le_Domain='other.example.com'" \
  "Le_API='https://acme-v02.api.letsencrypt.org/directory'" \
  "Le_CertCreateTime='1700000000'" \
  "Le_NextRenewTime='1702592000'"
expect_failure "ACME schedule rejects a mismatched configured domain" \
  load_acme_certificate_schedule example.com

write_domain_conf_fixture \
  "Le_Domain='example.com'" \
  "Le_API='https://acme-v02.api.letsencrypt.org/directory'" \
  "Le_CertCreateTime='1700000000'" \
  "Le_NextRenewTime='1702592000'"
expect_success "ACME schedule permits missing optional deployment time" \
  load_acme_certificate_schedule example.com
[[ -z $ACME_META_DEPLOYED_EPOCH && -z $ACME_META_DEPLOYED ]] ||
  fail "missing deployment time left stale ACME metadata"
pass "missing deployment time clears optional metadata"

DOMAIN_CONF_REAL="$DOMAIN_CONF_DIR/example.com.real.conf"
cp -p "$DOMAIN_CONF" "$DOMAIN_CONF_REAL"
rm -f "$DOMAIN_CONF"
if ln -s "$DOMAIN_CONF_REAL" "$DOMAIN_CONF" 2>/dev/null && [[ -L $DOMAIN_CONF ]]; then
  expect_failure "ACME domain parser rejects a symlinked config" \
    read_acme_domain_conf_value example.com Le_Domain
  rm -f "$DOMAIN_CONF"
  cp -p "$DOMAIN_CONF_REAL" "$DOMAIN_CONF"
else
  rm -f "$DOMAIN_CONF"
  cp -p "$DOMAIN_CONF_REAL" "$DOMAIN_CONF"
fi
rm -f "$DOMAIN_CONF_REAL"

CERT_FIXTURE_DIR="$STATE_DIR/certificates"
mkdir -p "$CERT_FIXTURE_DIR"
cat > "$CERT_FIXTURE_DIR/valid.cnf" <<'CERTCONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = example.com

[extensions]
subjectAltName = DNS:example.com,DNS:*.example.com
CERTCONFIG
openssl ecparam -genkey -name prime256v1 -out "$CERT_FIXTURE_DIR/valid.key" >/dev/null 2>&1 ||
  fail "could not generate valid certificate key fixture"
openssl req -new -x509 -days 2 -key "$CERT_FIXTURE_DIR/valid.key" \
  -out "$CERT_FIXTURE_DIR/valid.pem" -config "$CERT_FIXTURE_DIR/valid.cnf" >/dev/null 2>&1 ||
  fail "could not generate valid certificate fixture"
openssl ecparam -genkey -name prime256v1 -out "$CERT_FIXTURE_DIR/other.key" >/dev/null 2>&1 ||
  fail "could not generate mismatched certificate key fixture"

expect_success "valid X.509 metadata is readable" load_certificate_metadata \
  "$CERT_FIXTURE_DIR/valid.pem" "$CERT_FIXTURE_DIR/valid.key"
[[ $CERT_META_STATE == valid && $CERT_META_KEY_MATCH -eq 1 &&
   $CERT_META_REMAINING_DAYS -gt 0 &&
   $CERT_META_DNS_NAMES == 'example.com, *.example.com' &&
   $CERT_META_NOT_BEFORE == *UTC && $CERT_META_NOT_AFTER == *UTC &&
   -n $CERT_META_ISSUER && -n $CERT_META_SUBJECT && -n $CERT_META_FINGERPRINT ]] ||
  fail "valid X.509 metadata has unexpected values"
pass "valid X.509 metadata exposes identity and validity"

expect_success "mismatched X.509 key metadata is readable" load_certificate_metadata \
  "$CERT_FIXTURE_DIR/valid.pem" "$CERT_FIXTURE_DIR/other.key"
[[ $CERT_META_STATE == key_mismatch && $CERT_META_KEY_MATCH -eq 0 ]] ||
  fail "mismatched X.509 key was not reported"
pass "X.509 metadata reports a mismatched private key"

printf '%s\n' 'not a certificate' > "$CERT_FIXTURE_DIR/corrupt.pem"
expect_failure "corrupt X.509 certificate is rejected" load_certificate_metadata \
  "$CERT_FIXTURE_DIR/corrupt.pem" "$CERT_FIXTURE_DIR/valid.key"

EXPIRED_CERT_DIR="$CERT_FIXTURE_DIR/expired-ca"
export EXPIRED_CERT_DIR
mkdir -p "$EXPIRED_CERT_DIR/newcerts"
: > "$EXPIRED_CERT_DIR/index.txt"
printf '%s\n' 1000 > "$EXPIRED_CERT_DIR/serial"
cat > "$EXPIRED_CERT_DIR/ca.cnf" <<'CACONFIG'
[ca]
default_ca = local_ca

[local_ca]
dir = $ENV::EXPIRED_CERT_DIR
database = $dir/index.txt
new_certs_dir = $dir/newcerts
certificate = $dir/ca.pem
serial = $dir/serial
private_key = $dir/ca.key
default_md = sha256
default_days = 1
policy = supplied_cn
x509_extensions = server_extensions

[supplied_cn]
commonName = supplied

[server_extensions]
basicConstraints = CA:FALSE
subjectAltName = DNS:expired.example.com
CACONFIG
cat > "$EXPIRED_CERT_DIR/ca-request.cnf" <<'CAREQUEST'
[req]
distinguished_name = subject
prompt = no

[subject]
CN = Unit Test CA
CAREQUEST
cat > "$EXPIRED_CERT_DIR/expired-request.cnf" <<'EXPIREDREQUEST'
[req]
distinguished_name = subject
prompt = no

[subject]
CN = expired.example.com
EXPIREDREQUEST
openssl ecparam -genkey -name prime256v1 -out "$EXPIRED_CERT_DIR/ca.key" >/dev/null 2>&1 ||
  fail "could not generate expired fixture CA key"
openssl req -new -x509 -days 2 -key "$EXPIRED_CERT_DIR/ca.key" \
  -config "$EXPIRED_CERT_DIR/ca-request.cnf" -out "$EXPIRED_CERT_DIR/ca.pem" >/dev/null 2>&1 ||
  fail "could not generate expired fixture CA"
openssl ecparam -genkey -name prime256v1 -out "$EXPIRED_CERT_DIR/expired.key" >/dev/null 2>&1 ||
  fail "could not generate expired certificate key fixture"
openssl req -new -key "$EXPIRED_CERT_DIR/expired.key" \
  -config "$EXPIRED_CERT_DIR/expired-request.cnf" \
  -out "$EXPIRED_CERT_DIR/expired.csr" >/dev/null 2>&1 ||
  fail "could not generate expired certificate request fixture"
openssl ca -batch -config "$EXPIRED_CERT_DIR/ca.cnf" \
  -startdate 20200101000000Z -enddate 20200102000000Z \
  -in "$EXPIRED_CERT_DIR/expired.csr" -out "$EXPIRED_CERT_DIR/expired.pem" >/dev/null 2>&1 ||
  fail "could not generate expired certificate fixture"
expect_success "expired X.509 metadata is readable" load_certificate_metadata \
  "$EXPIRED_CERT_DIR/expired.pem" "$EXPIRED_CERT_DIR/expired.key"
[[ $CERT_META_STATE == expired && $CERT_META_KEY_MATCH -eq 1 &&
   $CERT_META_REMAINING_DAYS -lt 0 ]] || fail "expired X.509 certificate was not reported"
pass "X.509 metadata reports an expired certificate"

if ln -s "$CERT_FIXTURE_DIR/valid.pem" "$CERT_FIXTURE_DIR/cert-link.pem" 2>/dev/null &&
   [[ -L $CERT_FIXTURE_DIR/cert-link.pem ]]; then
  expect_failure "X.509 metadata rejects a symlinked certificate" load_certificate_metadata \
    "$CERT_FIXTURE_DIR/cert-link.pem" "$CERT_FIXTURE_DIR/valid.key"
fi

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

renew_runner=$(acme_renew_runner_path)
renew_state=$(acme_renew_state_path)
expect_success "generated ACME renewal runner is current" acme_renew_runner_is_current
expect_success "generated ACME renewal runner passes bash -n" bash -n "$renew_runner"
printf '%s\n' original-certificate > "$ACME_CERT"
expect_success "ACME runner records an unchanged certificate" "$renew_runner"
expect_success "unchanged renewal state is readable" load_acme_renew_state
[[ $ACME_RENEW_LAST_RESULT == unchanged && $ACME_RENEW_LAST_EXIT_CODE -eq 0 &&
   $ACME_RENEW_LAST_RENEWAL_EPOCH -eq 0 && $ACME_RENEW_FINGERPRINT =~ ^[0-9a-f]{64}$ ]] ||
  fail "unchanged renewal state has invalid values"
pass "unchanged renewal state has canonical values"

printf '%s\n' '#!/bin/bash' \
  "printf '%s\\n' renewed-certificate > \"\$HOME/acme-cert.pem\"" 'exit 0' > "$ACME_BIN"
chmod 700 "$ACME_BIN"
expect_success "ACME runner detects a renewed certificate" "$renew_runner"
expect_success "renewed state is readable" load_acme_renew_state
[[ $ACME_RENEW_LAST_RESULT == renewed && $ACME_RENEW_LAST_EXIT_CODE -eq 0 &&
   $ACME_RENEW_LAST_RENEWAL_EPOCH -eq $ACME_RENEW_LAST_CHECK_EPOCH ]] ||
  fail "renewed state did not record the fingerprint change"
pass "renewed state records the fingerprint change"
recorded_renewal_epoch=$ACME_RENEW_LAST_RENEWAL_EPOCH

printf '%s\n' '#!/bin/bash' 'exit 7' > "$ACME_BIN"
chmod 700 "$ACME_BIN"
expect_failure "ACME runner propagates an acme.sh failure" "$renew_runner"
expect_success "failed renewal state is readable" load_acme_renew_state
[[ $ACME_RENEW_LAST_RESULT == failed && $ACME_RENEW_LAST_EXIT_CODE -eq 7 &&
   $ACME_RENEW_LAST_RENEWAL_EPOCH -eq $recorded_renewal_epoch ]] ||
  fail "failed renewal state lost its exit code or last renewal"
pass "failed renewal state preserves the last actual renewal"

printf '%s\n' 'unexpected=value' >> "$renew_state"
expect_failure "renewal state parser rejects unknown fields" load_acme_renew_state
printf '%s\n' '#!/bin/bash' 'exit 0' > "$ACME_BIN"
chmod 700 "$ACME_BIN"
expect_success "ACME runner atomically replaces a malformed state" "$renew_runner"
expect_success "replaced renewal state is readable" load_acme_renew_state
if compgen -G "$SB_DIR/.acme_renew.state.*" >/dev/null; then
  fail "ACME runner left a temporary state file"
fi
pass "ACME runner leaves no temporary state file"

write_renew_state_fixture(){
  printf '%s\n' "$@" > "$renew_state"
  chmod 600 "$renew_state"
}

write_renew_state_fixture \
  'last_check_epoch=2000000000' \
  'last_check_epoch=2000000001' \
  'last_result=unchanged' \
  'last_exit_code=0' \
  'last_renewal_epoch=0' \
  "cert_fingerprint=$(printf 'a%.0s' {1..64})"
expect_failure "renewal state rejects duplicate fields" load_acme_renew_state

write_renew_state_fixture \
  'last_check_epoch=2000000000' \
  'last_result=unknown' \
  'last_exit_code=0' \
  'last_renewal_epoch=0' \
  "cert_fingerprint=$(printf 'a%.0s' {1..64})"
expect_failure "renewal state rejects an unknown result" load_acme_renew_state

write_renew_state_fixture \
  'last_check_epoch=2000000000' \
  'last_result=failed' \
  'last_exit_code=256' \
  'last_renewal_epoch=0' \
  'cert_fingerprint='
expect_failure "renewal state rejects an out-of-range exit code" load_acme_renew_state

write_renew_state_fixture \
  'last_check_epoch=2000000000' \
  'last_result=unchanged' \
  'last_exit_code=7' \
  'last_renewal_epoch=0' \
  "cert_fingerprint=$(printf 'a%.0s' {1..64})"
expect_failure "renewal state rejects a nonzero successful exit code" load_acme_renew_state

write_renew_state_fixture \
  'last_check_epoch=2000000000' \
  'last_result=failed' \
  'last_exit_code=0' \
  'last_renewal_epoch=0' \
  'cert_fingerprint='
expect_failure "renewal state rejects a zero failed exit code" load_acme_renew_state

write_renew_state_fixture \
  'last_check_epoch=2000000000' \
  'last_result=unchanged' \
  'last_exit_code=0' \
  'last_renewal_epoch=2000000001' \
  "cert_fingerprint=$(printf 'a%.0s' {1..64})"
expect_failure "renewal state rejects a future renewal timestamp" load_acme_renew_state

write_renew_state_fixture \
  'last_check_epoch=2000000000' \
  'last_result=renewed' \
  'last_exit_code=0' \
  'last_renewal_epoch=1999999999' \
  "cert_fingerprint=$(printf 'a%.0s' {1..64})"
expect_failure "renewed state requires matching check and renewal times" load_acme_renew_state

RENEW_STATE_MARKER="$STATE_DIR/renew-state-command-ran"
write_renew_state_fixture \
  "last_check_epoch=\$(touch $RENEW_STATE_MARKER)" \
  'last_result=failed' \
  'last_exit_code=1' \
  'last_renewal_epoch=0' \
  'cert_fingerprint='
expect_failure "renewal state rejects command substitution input" load_acme_renew_state
[[ ! -e $RENEW_STATE_MARKER ]] || fail "renewal state parser executed command substitution"
pass "renewal state parser does not execute command substitution"
[[ -z $ACME_RENEW_LAST_CHECK_EPOCH && -z $ACME_RENEW_LAST_RESULT ]] ||
  fail "failed renewal state parsing exposed partial values"
pass "failed renewal state parsing clears exported values"

printf '%s\n' '#!/bin/bash' 'exit 0' > "$ACME_BIN"
chmod 700 "$ACME_BIN"
expect_success "ACME runner restores canonical state after malicious input" "$renew_runner"
expect_success "restored renewal state is readable" load_acme_renew_state

force_args_file="$SB_DIR/force-args"
# Dollar-prefixed names below are literal fixture-script text.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/bash' \
  'printf '\''%s\n'\'' "$@" > "$HOME/force-args"' \
  'printf '\''%s\n'\'' forced-certificate > "$HOME/acme-cert.pem"' \
  'exit 0' > "$ACME_BIN"
chmod 700 "$ACME_BIN"
expect_success "ACME runner accepts a force renewal" "$renew_runner" --force
expect_success "forced renewal state is readable" load_acme_renew_state
[[ $ACME_RENEW_LAST_RESULT == renewed ]] || fail "forced renewal did not record a changed certificate"
pass "forced renewal records the changed certificate"
expected_force_args=$(printf '%s\n' \
  --home "$ACME_HOME" --config-home "$ACME_HOME" --renew -d example.com --ecc --force)
[[ $(<"$force_args_file") == "$expected_force_args" ]] ||
  fail "force runner did not invoke the targeted ACME renew command"
pass "force runner invokes the targeted ACME renew command"

renew_state_hash=$(sha256sum "$renew_state" | awk '{print $1}')
expect_failure "ACME runner rejects an unknown argument" "$renew_runner" --debug
[[ $(sha256sum "$renew_state" | awk '{print $1}') == "$renew_state_hash" ]] ||
  fail "unknown runner argument changed renewal state"
pass "unknown runner argument preserves renewal state"
expect_failure "ACME runner rejects multiple arguments" "$renew_runner" --force extra
[[ $(sha256sum "$renew_state" | awk '{print $1}') == "$renew_state_hash" ]] ||
  fail "multiple runner arguments changed renewal state"
pass "multiple runner arguments preserve renewal state"

if [[ $TEST_HAS_SYSTEM_FLOCK -eq 1 ]]; then
  lock_file=$(acme_lock_path)
  exec {TEST_ACME_LOCK_FD}> "$lock_file"
  flock -n "$TEST_ACME_LOCK_FD" || fail "cannot hold the ACME test lock"
  renew_state_hash=$(sha256sum "$renew_state" | awk '{print $1}')
  if "$renew_runner"; then
    fail "renewal runner ignored a held ACME lock"
  else
    runner_lock_status=$?
  fi
  [[ $runner_lock_status -eq 75 ]] || fail "busy renewal runner returned an unexpected status"
  pass "renewal runner refuses to overlap another ACME operation"
  [[ $(sha256sum "$renew_state" | awk '{print $1}') == "$renew_state_hash" ]] ||
    fail "busy renewal runner changed renewal state"
  pass "busy renewal runner preserves renewal state"
  flock -u "$TEST_ACME_LOCK_FD"
  exec {TEST_ACME_LOCK_FD}>&-
else
  pass "renewal lock contention is covered on Linux CI"
  pass "busy renewal state preservation is covered on Linux CI"
fi

printf '%s\n' 'example.com' 'injected.example.com' > "$ACME_IDENTITY"
expect_failure "force runner rejects a multi-line ACME identity" "$renew_runner" --force
[[ $(sha256sum "$renew_state" | awk '{print $1}') == "$renew_state_hash" ]] ||
  fail "invalid force identity changed renewal state"
pass "invalid force identity preserves renewal state"
printf '%s\n' 'example.com' > "$ACME_IDENTITY"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$ACME_BIN"
chmod 700 "$ACME_BIN"

write_renew_state_fixture \
  'last_check_epoch=999999999999' \
  'last_result=renewed' \
  'last_exit_code=0' \
  'last_renewal_epoch=999999999999' \
  "cert_fingerprint=$(sha256sum "$ACME_CERT" | awk '{print $1}')"
expect_success "ACME runner replaces a future inherited renewal time" "$renew_runner"
expect_success "future renewal time replacement is readable" load_acme_renew_state
[[ $ACME_RENEW_LAST_RENEWAL_EPOCH -eq 0 ]] ||
  fail "runner preserved an impossible future renewal time"
pass "runner resets an impossible future renewal time"

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

account_conf_fixture=$(<"$ACME_HOME/account.conf")
rm -f "$ACME_HOME/account.conf"
expect_failure "ACME setup rejects missing Cloudflare credentials" setup_acme_renew_cron
printf '%s\n' "$account_conf_fixture" > "$ACME_HOME/account.conf"

MOCK_CONFIG_USES_ACME=0
expect_failure "ACME ensure preserves cron for unknown certificate mode" ensure_acme_renew_cron
[[ $(sha256sum "$CRONTAB_FILE" | awk '{print $1}') == "$cron_hash" ]] ||
  fail "unknown certificate mode changed canonical cron"
pass "unknown certificate mode preserves canonical cron"
MOCK_CONFIG_USES_ACME=1

expect_success "generated ACME hook is current" acme_reload_hook_is_current
expect_success "generated ACME hook passes bash -n" bash -n "$ACME_RELOAD"
cp "$ACME_RELOAD" "$TEMP_DIR/good-acme-reload.sh"
hook_fixture="$TEMP_DIR/acme-reload-fixture.sh"
sed "s|/etc/sb|$SB_DIR|g" "$ACME_RELOAD" > "$hook_fixture"
chmod 700 "$hook_fixture"
rm -f "$SB_CONFIG"
run_initial_install_acme_hook(){
  SB_INITIAL_INSTALL=1 "$hook_fixture"
}
run_renewal_acme_hook_without_config(){
  unset SB_INITIAL_INSTALL
  "$hook_fixture"
}
expect_success "initial ACME install hook permits missing config" run_initial_install_acme_hook
expect_failure "renewal ACME hook rejects missing config" run_renewal_acme_hook_without_config
awk '
  $0 == "if [[ ! -s $config ]]; then" { in_config_guard=1; print; next }
  in_config_guard && $0 == "  exit 1" { in_config_guard=0; next }
  { print }
' "$TEMP_DIR/good-acme-reload.sh" > "$ACME_RELOAD"
chmod 700 "$ACME_RELOAD"
expect_failure "ACME hook without normal rejection is stale" acme_reload_hook_is_current
cp "$TEMP_DIR/good-acme-reload.sh" "$ACME_RELOAD"
chmod 700 "$ACME_RELOAD"
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

printf '%s\n' 'preserved-private-key' > "$ACME_KEY"
chmod 600 "$ACME_KEY"
renew_runner_hash=$(sha256sum "$renew_runner" | awk '{print $1}')
renew_state_hash=$(sha256sum "$renew_state" | awk '{print $1}')
acme_bin_hash=$(sha256sum "$ACME_BIN" | awk '{print $1}')
account_conf_hash=$(sha256sum "$ACME_HOME/account.conf" | awk '{print $1}')
identity_hash=$(sha256sum "$ACME_IDENTITY" | awk '{print $1}')
key_hash=$(sha256sum "$ACME_KEY" | awk '{print $1}')
ACME_STATE_BACKUP=
expect_success "ACME state backup is created" begin_acme_state_backup
acme_backup_path=$ACME_STATE_BACKUP
[[ -d $acme_backup_path && $acme_backup_path == "$SB_DIR"/.acme-backup.* ]] ||
  fail "ACME state backup path is invalid"
pass "ACME state backup uses a private managed path"

expect_success "new ACME state can be discarded before restore" discard_acme_state
mkdir -p "$ACME_HOME"
printf '%s\n' 'replacement-state' > "$ACME_HOME/replacement"
printf '%s\n' 'replacement-certificate' > "$ACME_CERT"
printf '%s\n' 'replacement-renew-state' > "$renew_state"

FAIL_RESTORE_DEST=$ACME_KEY
# Called indirectly by restore_acme_state_backup to simulate a partial apply failure.
# shellcheck disable=SC2317
mv(){
  if [[ ${*: -1} == "$FAIL_RESTORE_DEST" ]]; then
    return 1
  fi
  command mv "$@"
}
expect_failure "ACME restore reports a partial apply failure" restore_acme_state_backup
unset -f mv
[[ $ACME_STATE_BACKUP == "$acme_backup_path" && -d $acme_backup_path/acme ]] ||
  fail "failed ACME restore consumed its source backup"
pass "failed ACME restore keeps a complete retry source"
expect_success "ACME restore succeeds when retried" restore_acme_state_backup
[[ -z $ACME_STATE_BACKUP && ! -e $acme_backup_path ]] ||
  fail "successful ACME restore left its transaction backup"
pass "successful ACME restore clears its transaction backup"
[[ $(sha256sum "$renew_runner" | awk '{print $1}') == "$renew_runner_hash" &&
   $(sha256sum "$renew_state" | awk '{print $1}') == "$renew_state_hash" &&
   $(sha256sum "$ACME_BIN" | awk '{print $1}') == "$acme_bin_hash" &&
   $(sha256sum "$ACME_HOME/account.conf" | awk '{print $1}') == "$account_conf_hash" &&
   $(sha256sum "$ACME_IDENTITY" | awk '{print $1}') == "$identity_hash" &&
   $(sha256sum "$ACME_KEY" | awk '{print $1}') == "$key_hash" ]] ||
  fail "retried ACME restore did not recover every managed artifact"
pass "retried ACME restore recovers runner, state, credentials and key"
if compgen -G "$SB_DIR/.acme-restore.*" >/dev/null; then
  fail "ACME restore left a staging directory"
fi
pass "ACME restore leaves no staging directory"

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

LIFECYCLE_ROOT="$TEMP_DIR/lifecycle"
export SB_DIR="$LIFECYCLE_ROOT/sb"
export SHORTCUT="$LIFECYCLE_ROOT/bin/sb"
MOCK_SERVICE_CONFLICT=0
MOCK_SERVICE_CLEANUP=0
MOCK_CRON_CLEANUP=0
MOCK_SHORTCUT_OWNED=0
MOCK_RUNNING_SHORTCUT=0
service_name_conflict(){ [[ $MOCK_SERVICE_CONFLICT -eq 1 ]]; }
cleanup_service(){ return "$MOCK_SERVICE_CLEANUP"; }
remove_all_managed_crons(){ return "$MOCK_CRON_CLEANUP"; }
managed_directory_is_owned(){
  [[ -d $SB_DIR && -f $SB_DIR/.sb-managed ]]
}
shortcut_is_owned(){ [[ $MOCK_SHORTCUT_OWNED -eq 1 && -f $SHORTCUT ]]; }
running_from_managed_shortcut(){ [[ $MOCK_RUNNING_SHORTCUT -eq 1 ]]; }

mkdir -p "$SB_DIR"
printf '%s\n' keep > "$SB_DIR/data"
INSTALL_TRANSACTION_ACTIVE=0
expect_success "inactive install transaction cleanup is a no-op" cleanup_install_transaction
[[ -f $SB_DIR/data ]] || fail "inactive transaction deleted installation data"
pass "inactive install transaction preserves data"

printf '%s\n' managed > "$SB_DIR/.sb-managed"
mkdir -p "${SHORTCUT%/*}"
printf '%s\n' shortcut > "$SHORTCUT"
MOCK_SHORTCUT_OWNED=1
INSTALL_TRANSACTION_ACTIVE=1
expect_success "active install transaction cleanup succeeds" cleanup_install_transaction
[[ ! -e $SB_DIR && ! -e $SHORTCUT ]] || fail "active transaction left managed artifacts"
pass "active install transaction removes managed artifacts"
[[ $INSTALL_TRANSACTION_ACTIVE -eq 0 ]] || fail "active transaction flag was not cleared"
pass "active install transaction clears its flag"

mkdir -p "$SB_DIR"
printf '%s\n' foreign > "$SB_DIR/data"
MOCK_SHORTCUT_OWNED=0
INSTALL_TRANSACTION_ACTIVE=1
expect_failure "transaction cleanup rejects an unowned directory" cleanup_install_transaction
[[ -f $SB_DIR/data ]] || fail "unowned directory was deleted"
pass "transaction cleanup preserves an unowned directory"

printf '%s\n' managed > "$SB_DIR/.sb-managed"
MOCK_SERVICE_CLEANUP=1
expect_failure "incomplete cleanup preserves data when service cleanup fails" cleanup_incomplete_install
[[ -f $SB_DIR/data ]] || fail "data was deleted after service cleanup failure"
pass "service cleanup failure preserves installation data"

MOCK_SERVICE_CLEANUP=0
MOCK_RUNNING_SHORTCUT=1
MOCK_SHORTCUT_OWNED=1
mkdir -p "${SHORTCUT%/*}"
printf '%s\n' shortcut > "$SHORTCUT"
expect_success "incomplete cleanup preserves the running managed shortcut" cleanup_incomplete_install
[[ ! -e $SB_DIR && -f $SHORTCUT ]] || fail "running managed shortcut was not preserved"
pass "running managed shortcut remains available for reinstall"

printf '1..%d\n' "$passed"
