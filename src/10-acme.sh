# sb-module: 10-acme
# Certificate functions
cert_self_signed(){
  ym_vl_re=apple.com
  certificatec_hy2="$SB_DIR/cert.pem"
  certificatep_hy2="$SB_DIR/private.key"
  use_acme_cert=0
}

certificate_san_text(){
  local cert=$1
  if openssl x509 -help 2>&1 | grep -q -- '-ext'; then
    openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null
  else
    openssl x509 -in "$cert" -noout -text 2>/dev/null | \
      awk '/X509v3 Subject Alternative Name/{getline; print; exit}'
  fi
}

certificate_identity_matches(){
  local cert=$1 identity=$2 check_option san
  if valid_ipv4 "$identity" || valid_ipv6 "$identity"; then
    check_option=checkip
  elif valid_hostname "$identity"; then
    check_option=checkhost
  else
    return 1
  fi
  if openssl x509 -help 2>&1 | grep -q -- "-$check_option"; then
    openssl x509 -in "$cert" -noout "-$check_option" "$identity" >/dev/null 2>&1
    return
  fi
  san=$(certificate_san_text "$cert") || return 1
  if [[ $check_option == checkip ]]; then
    printf '%s\n' "$san" | grep -oE 'IP Address:[^,[:space:]]+' | cut -d: -f2- | grep -Fxq -- "$identity"
  else
    printf '%s\n' "$san" | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2- | grep -Fxiq -- "$identity"
  fi
}

certificate_time_valid(){
  local cert=$1 not_before not_before_epoch now
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
  not_before=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d= -f2-) || return 1
  [[ -n $not_before ]] || return 1
  not_before_epoch=$(date -d "$not_before" +%s 2>/dev/null) || return 1
  now=$(date +%s) || return 1
  ((not_before_epoch <= now))
}

certificate_key_matches(){
  local cert=$1 key=$2 cert_public key_public
  cert_public=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
  key_public=$(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
  [[ -n $cert_public && $cert_public == "$key_public" ]]
}

format_epoch_utc(){
  local epoch=$1
  [[ $epoch =~ ^[0-9]{1,12}$ ]] || return 1
  date -u -d "@$epoch" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null
}

certificate_dns_names(){
  local cert=$1 san
  san=$(certificate_san_text "$cert") || return 1
  printf '%s\n' "$san" | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2- |
    awk 'NF { if (result != "") result = result ", "; result = result $0 }
         END { if (result == "") exit 1; print result }'
}

load_certificate_metadata(){
  local cert=$1 key=$2 not_before not_after now remaining issuer subject
  CERT_META_NOT_BEFORE_EPOCH=
  CERT_META_NOT_AFTER_EPOCH=
  CERT_META_NOT_BEFORE=
  CERT_META_NOT_AFTER=
  CERT_META_REMAINING_DAYS=
  CERT_META_ISSUER=
  CERT_META_SUBJECT=
  CERT_META_DNS_NAMES=
  CERT_META_FINGERPRINT=
  CERT_META_KEY_MATCH=0
  CERT_META_STATE=invalid

  [[ -f $cert && ! -L $cert && -f $key && ! -L $key ]] || return 1
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || return 1
  not_before=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d= -f2-) || return 1
  not_after=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-) || return 1
  CERT_META_NOT_BEFORE_EPOCH=$(date -d "$not_before" +%s 2>/dev/null) || return 1
  CERT_META_NOT_AFTER_EPOCH=$(date -d "$not_after" +%s 2>/dev/null) || return 1
  CERT_META_NOT_BEFORE=$(format_epoch_utc "$CERT_META_NOT_BEFORE_EPOCH") || return 1
  CERT_META_NOT_AFTER=$(format_epoch_utc "$CERT_META_NOT_AFTER_EPOCH") || return 1
  now=$(date +%s) || return 1
  if ((CERT_META_NOT_AFTER_EPOCH >= now)); then
    remaining=$(((CERT_META_NOT_AFTER_EPOCH - now + 86399) / 86400))
  else
    remaining=$((-((now - CERT_META_NOT_AFTER_EPOCH + 86399) / 86400)))
  fi
  CERT_META_REMAINING_DAYS=$remaining

  issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 2>/dev/null ||
    openssl x509 -in "$cert" -noout -issuer 2>/dev/null) || return 1
  subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null ||
    openssl x509 -in "$cert" -noout -subject 2>/dev/null) || return 1
  CERT_META_ISSUER=$(printf '%s\n' "${issuer#issuer=}" | sanitize_location)
  CERT_META_SUBJECT=$(printf '%s\n' "${subject#subject=}" | sanitize_location)
  CERT_META_DNS_NAMES=$(certificate_dns_names "$cert" 2>/dev/null || true)
  CERT_META_FINGERPRINT=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null |
    cut -d= -f2- | tr -d '\r\n')
  [[ -n $CERT_META_ISSUER && -n $CERT_META_SUBJECT && -n $CERT_META_FINGERPRINT ]] || return 1

  if certificate_key_matches "$cert" "$key"; then
    CERT_META_KEY_MATCH=1
  fi
  if ((CERT_META_NOT_BEFORE_EPOCH > now)); then
    CERT_META_STATE=not_yet_valid
  elif ((CERT_META_NOT_AFTER_EPOCH < now)); then
    CERT_META_STATE=expired
  elif [[ $CERT_META_KEY_MATCH -ne 1 ]]; then
    CERT_META_STATE=key_mismatch
  else
    CERT_META_STATE=valid
  fi
}

acme_domain_conf_path(){
  local identity=$1
  valid_hostname "$identity" || return 1
  printf '%s/certs/%s_ecc/%s.conf\n' "$ACME_HOME" "$identity" "$identity"
}

read_acme_domain_conf_value(){
  local identity=$1 key=$2 conf prefix line value='' count=0
  case "$key" in
    Le_Domain|Le_API|Le_CertCreateTime|Le_NextRenewTime|Le_InstallCertSuccessTime) ;;
    *) return 1 ;;
  esac
  conf=$(acme_domain_conf_path "$identity") || return 1
  [[ -f $conf && ! -L $conf ]] || return 1
  prefix="${key}='"
  while IFS= read -r line; do
    [[ $line == "$prefix"* ]] || continue
    [[ $line == *"'" ]] || return 1
    value=${line#"$prefix"}
    value=${value%"'"}
    [[ $value != *"'"* && $value != *$'\r'* ]] || return 1
    count=$((count + 1))
  done < "$conf"
  [[ $count -eq 1 ]] || return 1
  case "$key" in
    Le_Domain) valid_hostname "$value" ;;
    Le_API) [[ $value == 'https://acme-v02.api.letsencrypt.org/directory' ]] ;;
    *) [[ $value =~ ^[0-9]{1,12}$ ]] ;;
  esac || return 1
  printf '%s\n' "$value"
}

load_acme_certificate_schedule(){
  local identity=$1 configured_domain
  ACME_META_CREATED_EPOCH=
  ACME_META_NEXT_RENEW_EPOCH=
  ACME_META_DEPLOYED_EPOCH=
  ACME_META_CREATED=
  ACME_META_NEXT_RENEW=
  ACME_META_DEPLOYED=
  ACME_META_CA=
  configured_domain=$(read_acme_domain_conf_value "$identity" Le_Domain) || return 1
  [[ $configured_domain == "$identity" ]] || return 1
  read_acme_domain_conf_value "$identity" Le_API >/dev/null || return 1
  ACME_META_CA="Let's Encrypt"
  ACME_META_CREATED_EPOCH=$(read_acme_domain_conf_value "$identity" Le_CertCreateTime) || return 1
  ACME_META_NEXT_RENEW_EPOCH=$(read_acme_domain_conf_value "$identity" Le_NextRenewTime) || return 1
  ACME_META_CREATED=$(format_epoch_utc "$ACME_META_CREATED_EPOCH") || return 1
  ACME_META_NEXT_RENEW=$(format_epoch_utc "$ACME_META_NEXT_RENEW_EPOCH") || return 1
  if ACME_META_DEPLOYED_EPOCH=$(read_acme_domain_conf_value "$identity" Le_InstallCertSuccessTime); then
    ACME_META_DEPLOYED=$(format_epoch_utc "$ACME_META_DEPLOYED_EPOCH") || ACME_META_DEPLOYED=
  else
    ACME_META_DEPLOYED_EPOCH=
  fi
}

cloudflare_acme_credentials_present(){
  local account_conf="$ACME_HOME/account.conf" token_count account_count
  [[ -f $account_conf && ! -L $account_conf ]] || return 1
  token_count=$(grep -Ec "^SAVED_CF_Token='[A-Za-z0-9_-]+'$" "$account_conf" 2>/dev/null || true)
  account_count=$(grep -Ec "^SAVED_CF_Account_ID='[0-9A-Fa-f]{32}'$" "$account_conf" 2>/dev/null || true)
  [[ $token_count -eq 1 && $account_count -eq 1 ]]
}

read_acme_identity(){
  local identity
  local -a identity_lines=()
  [[ -f $ACME_IDENTITY && ! -L $ACME_IDENTITY ]] || return 1
  mapfile -t identity_lines < "$ACME_IDENTITY" || return 1
  [[ ${#identity_lines[@]} -eq 1 ]] || return 1
  identity=${identity_lines[0]}
  valid_hostname "$identity" || return 1
  printf '%s\n' "$identity"
}

detect_acme_identity(){
  local identity san
  [[ -s $ACME_CERT && -s $ACME_KEY ]] || return 1
  openssl x509 -in "$ACME_CERT" -noout >/dev/null 2>&1 || return 1
  certificate_time_valid "$ACME_CERT" || return 1
  certificate_key_matches "$ACME_CERT" "$ACME_KEY" || return 1
  if identity=$(read_acme_identity 2>/dev/null); then
    if certificate_identity_matches "$ACME_CERT" "$identity"; then
      printf '%s\n' "$identity"
      return 0
    fi
  fi
  san=$(certificate_san_text "$ACME_CERT") || return 1
  identity=$(printf '%s\n' "$san" | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2- | grep -v '^\*\.' | head -n 1)
  valid_hostname "$identity" && certificate_identity_matches "$ACME_CERT" "$identity" || return 1
  printf '%s\n' "$identity"
}

cert_acme(){
  local identity
  if ! identity=$(detect_acme_identity); then
    red "无法从 ACME 证书中确认有效域名，拒绝使用该证书"
    return 1
  fi
  ym_vl_re=apple.com
  certificatec_hy2="$ACME_CERT"
  certificatep_hy2="$ACME_KEY"
  use_acme_cert=1
  printf '%s\n' "$identity" > "$ACME_IDENTITY" || return 1
  chmod 600 "$ACME_IDENTITY"
}

normalize_acme_domain(){
  local value=${1,,}
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  value=${value%.}
  ACME_PRIMARY_DOMAIN=
  ACME_WILDCARD_DOMAIN=
  if [[ $value == \*.* ]]; then
    ACME_PRIMARY_DOMAIN=${value#\*.}
    valid_hostname "$ACME_PRIMARY_DOMAIN" || return 1
    ACME_WILDCARD_DOMAIN="*.$ACME_PRIMARY_DOMAIN"
  elif [[ $value == *\** ]]; then
    return 1
  else
    valid_hostname "$value" || return 1
    ACME_PRIMARY_DOMAIN=$value
  fi
}

valid_cloudflare_account_id(){
  [[ $1 =~ ^[0-9A-Fa-f]{32}$ ]]
}

install_official_acme(){
  local temp_dir archive source_dir actual_sha256 installed_version
  if [[ -x $ACME_BIN && -f $ACME_HOME/dnsapi/dns_cf.sh ]]; then
    installed_version=$(HOME="$SB_DIR" "$ACME_BIN" --version 2>/dev/null)
    if printf '%s\n' "$installed_version" | grep -Fxq "v$ACME_VERSION"; then
      return 0
    fi
  fi
  temp_dir=$(mktemp -d "$SB_DIR/.acme-install.XXXXXX") || return 1
  archive="$temp_dir/acme.sh.tar.gz"
  source_dir="$temp_dir/acme.sh-$ACME_VERSION"
  green "正在从 acme.sh 官方仓库安装 v${ACME_VERSION}……"
  if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --retry 2 --connect-timeout 10 --max-time 60 -o "$archive" \
      "https://codeload.github.com/acmesh-official/acme.sh/tar.gz/refs/tags/${ACME_VERSION}"; then
    rm -rf "$temp_dir"
    red "官方 acme.sh 下载失败"
    return 1
  fi
  actual_sha256=$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')
  if [[ $actual_sha256 != "$ACME_ARCHIVE_SHA256" ]]; then
    rm -rf "$temp_dir"
    red "官方 acme.sh 压缩包 SHA-256 校验失败，拒绝执行"
    return 1
  fi
  if ! tar -xzf "$archive" -C "$temp_dir" || [[ ! -f $source_dir/acme.sh ]] || \
     [[ ! -f $source_dir/dnsapi/dns_cf.sh ]] || \
     ! (cd "$source_dir" && HOME="$SB_DIR" bash ./acme.sh --install \
       --home "$ACME_HOME" --config-home "$ACME_HOME" --cert-home "$ACME_HOME/certs" \
       --no-cron --no-profile); then
    rm -rf "$temp_dir"
    red "官方 acme.sh 安装失败"
    return 1
  fi
  rm -rf "$temp_dir"
  installed_version=$(HOME="$SB_DIR" "$ACME_BIN" --version 2>/dev/null)
  if [[ ! -x $ACME_BIN || ! -f $ACME_HOME/dnsapi/dns_cf.sh ]] || \
     ! printf '%s\n' "$installed_version" | grep -Fxq "v$ACME_VERSION"; then
    red "官方 acme.sh 安装不完整"
    return 1
  fi
  chmod 700 "$ACME_HOME" "$ACME_BIN"
}

write_acme_reload_hook(){
  local hook_tmp
  hook_tmp=$(mktemp "$SB_DIR/.acme_reload.XXXXXX") || return 1
  if [[ -e $ACME_RELOAD || -L $ACME_RELOAD ]] && \
     [[ ! -f $ACME_RELOAD || -L $ACME_RELOAD ]]; then
    rm -f "$hook_tmp"
    return 1
  fi
  if ! cat > "$hook_tmp" <<'ACMERELOAD'
#!/bin/bash
# sb-acme-reload-v1
export LANG=en_US.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cert="/etc/sb/acme-cert.pem"
key="/etc/sb/acme-private.key"
config="/etc/sb/sb.json"
identity_file="/etc/sb/acme_server_name"
systemd_unit="/etc/systemd/system/sb.service"
openrc_unit="/etc/init.d/sb"
if [[ ! -s $config ]]; then
  [[ ${SB_INITIAL_INSTALL:-0} == 1 ]] && exit 0
  exit 1
fi
command -v jq >/dev/null 2>&1 || exit 1
current_cert=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.certificate_path' "$config" 2>/dev/null) || exit 1
current_key=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.key_path' "$config" 2>/dev/null) || exit 1
[[ $current_cert == "$cert" && $current_key == "$key" ]] || exit 0
[[ -s "$cert" && -s "$key" && -s "$identity_file" ]] || exit 1
openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || exit 1
not_before=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d= -f2-) || exit 1
not_before_epoch=$(date -d "$not_before" +%s 2>/dev/null) || exit 1
[[ $not_before_epoch -le $(date +%s) ]] || exit 1
identity=$(head -n 1 "$identity_file" | tr -d '\r' | awk '{print $1}')
[[ -n "$identity" ]] || exit 1
if openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
  openssl x509 -in "$cert" -noout -checkhost "$identity" >/dev/null 2>&1 || exit 1
else
  if openssl x509 -help 2>&1 | grep -q -- '-ext'; then
    san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) || exit 1
  else
    san=$(openssl x509 -in "$cert" -noout -text 2>/dev/null | awk '/X509v3 Subject Alternative Name/{getline; print; exit}') || exit 1
  fi
  printf '%s\n' "$san" | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2- | grep -Fxiq -- "$identity" || exit 1
fi
cert_public=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || exit 1
key_public=$(openssl pkey -in "$key" -pubout 2>/dev/null) || exit 1
[[ -n "$cert_public" && "$cert_public" == "$key_public" ]] || exit 1
has_openrc=0
has_systemd=0
[[ -e $openrc_unit || -L $openrc_unit ]] && has_openrc=1
[[ -e $systemd_unit || -L $systemd_unit ]] && has_systemd=1
((has_openrc + has_systemd <= 1)) || exit 1
if ((has_openrc)); then
  if command -v systemctl >/dev/null 2>&1 && systemctl cat sb >/dev/null 2>&1; then
    exit 1
  fi
  rc_service=$(command -v rc-service 2>/dev/null) || exit 1
  [[ -f $openrc_unit && ! -L $openrc_unit ]] || exit 1
  grep -Fqx '# Managed by sb.sh' "$openrc_unit" 2>/dev/null &&
    grep -Fqx 'command="/etc/sb/sing-box"' "$openrc_unit" 2>/dev/null &&
    grep -Fqx 'command_args="run -c /etc/sb/sb.json"' "$openrc_unit" 2>/dev/null || exit 1
  "$rc_service" sb status >/dev/null 2>&1 || exit 0
  "$rc_service" sb restart >/dev/null 2>&1 || exit 1
  sleep 1
  "$rc_service" sb status >/dev/null 2>&1
elif ((has_systemd)); then
  command -v systemctl >/dev/null 2>&1 || exit 1
  [[ -f $systemd_unit && ! -L $systemd_unit ]] || exit 1
  for unit_base in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system \
    /usr/lib/systemd/system /lib/systemd/system; do
    candidate_unit="$unit_base/sb.service"
    [[ $candidate_unit == "$systemd_unit" ]] && continue
    [[ ! -e $candidate_unit && ! -L $candidate_unit ]] || exit 1
  done
  for dropin_dir in /etc/systemd/system/sb.service.d /run/systemd/system/sb.service.d \
    /usr/local/lib/systemd/system/sb.service.d /usr/lib/systemd/system/sb.service.d \
    /lib/systemd/system/sb.service.d; do
    [[ -L $dropin_dir || -e $dropin_dir && ! -d $dropin_dir ]] && exit 1
    if [[ -d $dropin_dir ]]; then
      for dropin in "$dropin_dir"/* "$dropin_dir"/.[!.]* "$dropin_dir"/..?*; do
        [[ -e $dropin || -L $dropin ]] && exit 1
      done
    fi
  done
  fragment=$(systemctl show sb.service -p FragmentPath --value 2>/dev/null || true)
  dropins=$(systemctl show sb.service -p DropInPaths --value 2>/dev/null || true)
  [[ -z $fragment || $fragment == "$systemd_unit" ]] || exit 1
  [[ -z $dropins ]] || exit 1
  grep -Fqx '# Managed by sb.sh' "$systemd_unit" 2>/dev/null &&
    grep -Fqx 'WorkingDirectory=/etc/sb' "$systemd_unit" 2>/dev/null &&
    grep -Fqx 'ExecStart=/etc/sb/sing-box run -c /etc/sb/sb.json' "$systemd_unit" 2>/dev/null || exit 1
  systemctl is-active --quiet sb || exit 0
  systemctl restart sb >/dev/null 2>&1 || exit 1
  sleep 1
  systemctl is-active --quiet sb
else
  if command -v systemctl >/dev/null 2>&1 && systemctl cat sb >/dev/null 2>&1; then
    exit 1
  fi
  exit 0
fi
ACMERELOAD
  then
    rm -f "$hook_tmp"
    return 1
  fi
  if ! chmod 700 "$hook_tmp" || ! mv -f "$hook_tmp" "$ACME_RELOAD"; then
    rm -f "$hook_tmp"
    return 1
  fi
  acme_reload_hook_is_current
}

acme_reload_hook_is_current(){
  [[ -f $ACME_RELOAD && ! -L $ACME_RELOAD && -x $ACME_RELOAD ]] &&
    [[ $(grep -Fxc "$ACME_RELOAD_IDENTITY" "$ACME_RELOAD" 2>/dev/null || true) -eq 1 ]] &&
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
    ' "$ACME_RELOAD" &&
    grep -Fqx 'command -v jq >/dev/null 2>&1 || exit 1' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx "[[ -n \"\$cert_public\" && \"\$cert_public\" == \"\$key_public\" ]] || exit 1" "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx '  systemctl restart sb >/dev/null 2>&1 || exit 1' "$ACME_RELOAD" 2>/dev/null &&
    bash -n "$ACME_RELOAD" >/dev/null 2>&1
}

config_uses_acme_certificate(){
  [[ -s $SB_CONFIG ]] || return 1
  jq -e --arg cert "$ACME_CERT" --arg key "$ACME_KEY" '
    [.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb" and
      .tls.certificate_path == $cert and .tls.key_path == $key)] | length == 1
  ' "$SB_CONFIG" >/dev/null 2>&1
}

config_uses_self_signed_certificate(){
  [[ -s $SB_CONFIG ]] || return 1
  jq -e --arg cert "$SB_DIR/cert.pem" --arg key "$SB_DIR/private.key" '
    [.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb" and
      .tls.certificate_path == $cert and .tls.key_path == $key)] | length == 1
  ' "$SB_CONFIG" >/dev/null 2>&1
}

config_references_acme_state(){
  [[ -s $SB_CONFIG ]] || return 1
  jq -e --arg cert "$ACME_CERT" --arg key "$ACME_KEY" '
    [.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb" and
      (.tls.certificate_path == $cert or .tls.key_path == $key))] | length > 0
  ' "$SB_CONFIG" >/dev/null 2>&1
}

begin_acme_state_backup(){
  local backup path
  local -a state_paths=(
    "$ACME_CERT" "$ACME_KEY" "$ACME_IDENTITY" "$ACME_RELOAD"
    "$SB_DIR/acme_renew.sh" "$SB_DIR/acme_renew.state"
    "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
  )
  ACME_STATE_BACKUP=
  backup=$(mktemp -d "$SB_DIR/.acme-backup.XXXXXX") || return 1
  chmod 700 "$backup" || { rm -rf -- "$backup"; return 1; }
  mkdir "$backup/files" || { rm -rf -- "$backup"; return 1; }
  if [[ -e $ACME_HOME || -L $ACME_HOME ]]; then
    if [[ ! -d $ACME_HOME || -L $ACME_HOME ]] || ! cp -a -- "$ACME_HOME" "$backup/acme"; then
      rm -rf -- "$backup"
      return 1
    fi
  fi
  for path in "${state_paths[@]}"; do
    [[ -e $path || -L $path ]] || continue
    if [[ ! -f $path || -L $path ]] || ! cp -p -- "$path" "$backup/files/${path##*/}"; then
      rm -rf -- "$backup"
      return 1
    fi
  done
  ACME_STATE_BACKUP=$backup
}

clear_acme_state_backup(){
  local backup=${ACME_STATE_BACKUP:-}
  [[ -n $backup ]] || return 0
  [[ $backup == "$SB_DIR"/.acme-backup.* && -d $backup && ! -L $backup ]] || return 1
  rm -rf -- "$backup" || return 1
  ACME_STATE_BACKUP=
}

restore_acme_state_backup(){
  local backup=${ACME_STATE_BACKUP:-} stage entry name destination index
  local -a state_names=(
    acme-cert.pem acme-private.key acme_server_name acme_reload.sh
    acme_renew.sh acme_renew.state cert_renew.sh .cert_mtime
  )
  local -a state_paths=(
    "$ACME_CERT" "$ACME_KEY" "$ACME_IDENTITY" "$ACME_RELOAD"
    "$SB_DIR/acme_renew.sh" "$SB_DIR/acme_renew.state"
    "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
  )
  [[ -n $backup ]] || return 0
  [[ $backup == "$SB_DIR"/.acme-backup.* && -d $backup && ! -L $backup ]] || return 1
  [[ -d $backup/files && ! -L $backup/files ]] || return 1
  stage=$(mktemp -d "$SB_DIR/.acme-restore.XXXXXX") || return 1
  chmod 700 "$stage" || { rm -rf -- "$stage"; return 1; }
  mkdir "$stage/files" || { rm -rf -- "$stage"; return 1; }
  if [[ -e $backup/acme || -L $backup/acme ]]; then
    if [[ ! -d $backup/acme || -L $backup/acme ]] ||
       ! cp -a -- "$backup/acme" "$stage/acme"; then
      rm -rf -- "$stage"
      return 1
    fi
  fi
  for entry in "$backup/files"/* "$backup/files"/.[!.]* "$backup/files"/..?*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    [[ -f $entry && ! -L $entry ]] || { rm -rf -- "$stage"; return 1; }
    printf '%s\n' "${state_names[@]}" | grep -Fxq -- "$name" || {
      rm -rf -- "$stage"
      return 1
    }
    cp -p -- "$entry" "$stage/files/$name" || { rm -rf -- "$stage"; return 1; }
  done

  rm -rf -- "$ACME_HOME" || { rm -rf -- "$stage"; return 1; }
  for destination in "${state_paths[@]}"; do
    rm -f -- "$destination" || { rm -rf -- "$stage"; return 1; }
  done
  if [[ -d $stage/acme ]]; then
    mv -- "$stage/acme" "$ACME_HOME" || { rm -rf -- "$stage"; return 1; }
  fi
  for index in "${!state_names[@]}"; do
    entry="$stage/files/${state_names[$index]}"
    [[ -e $entry ]] || continue
    destination=${state_paths[$index]}
    mv -- "$entry" "$destination" || { rm -rf -- "$stage"; return 1; }
  done
  rm -rf -- "$stage" || return 1
  rm -rf -- "$backup" || return 1
  ACME_STATE_BACKUP=
}

discard_acme_state(){
  local path failed=0
  rm -rf "$ACME_HOME" || failed=1
  rm -f "$ACME_CERT" "$ACME_KEY" "$ACME_IDENTITY" "$ACME_RELOAD" \
    "$SB_DIR/acme_renew.sh" "$SB_DIR/acme_renew.state" \
    "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime" || failed=1
  for path in "$ACME_HOME" "$ACME_CERT" "$ACME_KEY" "$ACME_IDENTITY" "$ACME_RELOAD" \
    "$SB_DIR/acme_renew.sh" "$SB_DIR/acme_renew.state" \
    "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"; do
    [[ ! -e $path && ! -L $path ]] || failed=1
  done
  if ((failed)); then
    red "清理旧 ACME 状态不完整，已中止新证书申请"
    return 1
  fi
}

reset_acme_state(){
  local current
  if config_references_acme_state; then
    red "当前服务正在使用 ACME 证书，请先切换为自签证书"
    return 1
  fi
  load_current_crontab || return 1
  current=$CURRENT_CRONTAB
  if crontab_has_acme_entries "$current"; then
    remove_acme_renew_cron || return 1
  fi
  discard_acme_state
}

issue_cloudflare_certificate(){
  local domain_input account_id cf_token identity_tmp backup_path
  local initial_install=${1:-0} retain_backup=${2:-0} reuse_backup=${3:-0}
  local -a issue_args
  [[ $initial_install == 0 || $initial_install == 1 ]] || return 1
  [[ $retain_backup == 0 || $retain_backup == 1 ]] || return 1
  [[ $reuse_backup == 0 || $reuse_backup == 1 ]] || return 1
  while true; do
    readp "请输入域名；泛域名请写成 *.example.com：" domain_input || return 1
    if normalize_acme_domain "$domain_input"; then
      break
    fi
    red "域名格式错误，请输入 example.com、sub.example.com 或 *.example.com"
  done
  while true; do
    readp "请输入 Cloudflare Account ID：" account_id || return 1
    account_id=${account_id,,}
    account_id=$(printf '%s' "$account_id" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if valid_cloudflare_account_id "$account_id"; then
      break
    fi
    red "Account ID 应为 32 位十六进制字符串"
  done
  yellow "DNS API 只负责证书验证；节点仍连接 VPS 公网 IP，域名仅作为 TLS SNI"
  yellow "API Token 需要 Zone / DNS / Edit 与 Zone / Zone / Read 权限"
  yellow "请把 Token 的 Zone 资源限制到目标域名"
  yellow "Token 将由 acme.sh 保存在仅 root 可读的 $ACME_HOME 配置中，用于自动续期"
  readp "请输入 Cloudflare API Token：" cf_token || return 1
  if [[ -z $cf_token ]]; then
    red "API Token 不能为空"
    return 1
  fi
  if [[ $reuse_backup == 1 ]]; then
    if [[ -z ${ACME_STATE_BACKUP:-} ]]; then
      red "原 ACME 状态备份不存在，已取消申请"
      return 1
    fi
  else
    if [[ -n ${ACME_STATE_BACKUP:-} ]] || ! begin_acme_state_backup; then
      red "无法安全备份现有 ACME 状态，已取消申请"
      return 1
    fi
  fi
  if ! reset_acme_state; then
    restore_acme_state_backup || red "恢复 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  fi
  if ! install_official_acme; then
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  fi
  if ! write_acme_reload_hook; then
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  fi
  issue_args=(--home "$ACME_HOME" --config-home "$ACME_HOME" --issue --server letsencrypt \
    --dns dns_cf --keylength ec-256 -d "$ACME_PRIMARY_DOMAIN")
  if [[ -n $ACME_WILDCARD_DOMAIN ]]; then
    issue_args+=(-d "$ACME_WILDCARD_DOMAIN")
    blue "将申请：$ACME_PRIMARY_DOMAIN + $ACME_WILDCARD_DOMAIN"
  else
    blue "将申请单域名证书：$ACME_PRIMARY_DOMAIN"
  fi
  if ! HOME="$SB_DIR" CF_Token="$cf_token" CF_Account_ID="$account_id" \
      CF_Zone_ID='' CF_Key='' CF_Email='' \
      "$ACME_BIN" "${issue_args[@]}"; then
    cf_token=
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    red "Cloudflare DNS 验证或证书签发失败"
    return 1
  fi
  cf_token=
  identity_tmp=$(mktemp "$SB_DIR/.acme-identity.XXXXXX") || {
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  }
  if ! printf '%s\n' "$ACME_PRIMARY_DOMAIN" > "$identity_tmp" || \
     ! chmod 600 "$identity_tmp" || ! mv -f "$identity_tmp" "$ACME_IDENTITY"; then
    rm -f "$identity_tmp"
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  fi
  if [[ $initial_install == 1 ]]; then
    if ! SB_INITIAL_INSTALL=1 HOME="$SB_DIR" "$ACME_BIN" --home "$ACME_HOME" --config-home "$ACME_HOME" \
        --install-cert -d "$ACME_PRIMARY_DOMAIN" --ecc \
        --key-file "$ACME_KEY" --fullchain-file "$ACME_CERT" --reloadcmd "$ACME_RELOAD"; then
      discard_acme_state
      restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
      red "证书签发成功，但安装到 $SB_DIR 失败"
      return 1
    fi
  elif ! SB_INITIAL_INSTALL=0 HOME="$SB_DIR" "$ACME_BIN" --home "$ACME_HOME" --config-home "$ACME_HOME" \
      --install-cert -d "$ACME_PRIMARY_DOMAIN" --ecc \
      --key-file "$ACME_KEY" --fullchain-file "$ACME_CERT" --reloadcmd "$ACME_RELOAD"; then
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    red "证书签发成功，但安装到 $SB_DIR 失败"
    return 1
  fi
  if ! chmod 600 "$ACME_CERT" "$ACME_KEY"; then
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  fi
  if ! cert_acme; then
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    red "证书有效性、域名或公私钥校验失败"
    return 1
  fi
  if [[ $retain_backup == 0 ]]; then
    if ! clear_acme_state_backup; then
      backup_path=$ACME_STATE_BACKUP
      ACME_STATE_BACKUP=
      yellow "新证书已签发，但临时备份未能删除：$backup_path"
    fi
  fi
  green "Cloudflare DNS API 证书申请完成"
}

inscertificate(){
  local menu acme_name selfsign_config
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "二、生成并设置相关证书"
  echo
  blue "自动生成bing自签证书中……" && sleep 2
  selfsign_config=$(mktemp "$SB_DIR/.selfsign-openssl.XXXXXX") || return 1
  if ! cat > "$selfsign_config" <<'SELFSIGN'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = www.bing.com

[extensions]
subjectAltName = DNS:www.bing.com
SELFSIGN
  then
    rm -f "$selfsign_config"
    return 1
  fi
  if ! openssl ecparam -genkey -name prime256v1 -out "$SB_DIR/private.key" || \
     ! openssl req -new -x509 -days 36500 -key "$SB_DIR/private.key" \
       -out "$SB_DIR/cert.pem" -config "$selfsign_config"; then
    rm -f "$selfsign_config"
    red "生成bing自签证书失败"
    return 1
  fi
  rm -f "$selfsign_config"
  chmod 600 "$SB_DIR/private.key" "$SB_DIR/cert.pem"
  echo
  if [[ -s $SB_DIR/cert.pem ]]; then
    blue "生成bing自签证书成功"
  else
    red "生成bing自签证书失败"
    return 1
  fi
  echo
  if acme_name=$(detect_acme_identity); then
    yellow "检测到可用的 ACME 域名证书：$acme_name"
    green "请选择 Hysteria2 证书模式"
    yellow "1：否！使用自签的证书 (回车默认)"
    yellow "2：使用已有的 $acme_name 域名证书"
    yellow "3：通过 Cloudflare Account ID + API Token 重新申请"
    yellow "   重新申请会删除本脚本现有的 ACME 证书与续期配置"
    while true; do
      readp "请选择【1-3】：" menu || return 1
      case "$menu" in
        ""|1) cert_self_signed; break ;;
        2)
          if cert_acme; then
            break
          fi
          ;;
        3)
          if issue_cloudflare_certificate 1; then break; fi
          yellow "继续使用自签证书"
          cert_self_signed
          break
          ;;
        *) red "请输入1、2或3" ;;
      esac
    done
  else
    green "请选择 Hysteria2 证书模式"
    yellow "1：使用自签证书 (回车默认)"
    yellow "2：使用官方 acme.sh + Cloudflare DNS API 申请域名证书"
    while true; do
      readp "请选择【1-2】：" menu || return 1
      case "$menu" in
        ""|1) cert_self_signed; break ;;
        2)
          if issue_cloudflare_certificate 1; then break; fi
          yellow "证书申请失败，继续使用自签证书"
          cert_self_signed
          break
          ;;
        *) red "请输入1或2" ;;
      esac
    done
  fi
}
