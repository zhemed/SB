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

  if [[ -L $cert || -L $key ]]; then
    [[ $cert == "${ACME_CERT:-}" && $key == "${ACME_KEY:-}" ]] || return 1
    managed_acme_live_layout_is_valid || return 1
  else
    [[ -f $cert && -f $key ]] || return 1
  fi
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

managed_acme_live_layout_is_valid(){
  local current_target generation cert_target key_target
  [[ -d ${ACME_LIVE:-} && ! -L $ACME_LIVE &&
     -d ${ACME_GENERATIONS:-} && ! -L $ACME_GENERATIONS &&
     -L ${ACME_CURRENT:-} && -L ${ACME_CERT:-} && -L ${ACME_KEY:-} ]] || return 1
  [[ $(readlink "$ACME_CERT" 2>/dev/null) == 'acme-live/current/fullchain.pem' &&
     $(readlink "$ACME_KEY" 2>/dev/null) == 'acme-live/current/private.key' ]] || return 1
  current_target=$(readlink "$ACME_CURRENT" 2>/dev/null) || return 1
  [[ $current_target =~ ^generations/gen\.[A-Za-z0-9]+$ ]] || return 1
  generation="$ACME_LIVE/$current_target"
  [[ -d $generation && ! -L $generation &&
     -f $generation/fullchain.pem && ! -L $generation/fullchain.pem &&
     -f $generation/private.key && ! -L $generation/private.key ]] || return 1
  cert_target=$(readlink -f "$ACME_CERT" 2>/dev/null) || return 1
  key_target=$(readlink -f "$ACME_KEY" 2>/dev/null) || return 1
  [[ $cert_target == "$generation/fullchain.pem" &&
     $key_target == "$generation/private.key" ]]
}

acme_domain_conf_path(){
  local identity=$1
  valid_hostname "$identity" || return 1
  printf '%s/certs/%s_ecc/%s.conf\n' "$ACME_HOME" "$identity" "$identity"
}

read_acme_domain_conf_value(){
  local identity=$1 key=$2 conf prefix line value='' count=0 expected
  case "$key" in
    Le_Domain|Le_API|Le_CertCreateTime|Le_NextRenewTime|Le_InstallCertSuccessTime|\
      Le_RealCertPath|Le_RealCACertPath|Le_RealKeyPath|Le_RealFullChainPath|Le_ReloadCmd) ;;
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
    Le_CertCreateTime|Le_NextRenewTime|Le_InstallCertSuccessTime)
      [[ $value =~ ^[0-9]{1,12}$ ]]
      ;;
    Le_RealCertPath|Le_RealCACertPath) [[ -z $value ]] ;;
    Le_RealKeyPath) [[ $value == "$ACME_STAGE_KEY" ]] ;;
    Le_RealFullChainPath) [[ $value == "$ACME_STAGE_CERT" ]] ;;
    Le_ReloadCmd)
      expected=$(printf '%s' "$ACME_RELOAD" | base64 | tr -d '\r\n') || return 1
      [[ $value == "__ACME_BASE64__START_${expected}__ACME_BASE64__END_" ]]
      ;;
  esac || return 1
  printf '%s\n' "$value"
}

acme_deployment_config_is_current(){
  local identity=$1 key
  for key in Le_RealCertPath Le_RealCACertPath Le_RealKeyPath Le_RealFullChainPath Le_ReloadCmd; do
    read_acme_domain_conf_value "$identity" "$key" >/dev/null || return 1
  done
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

write_acme_identity(){
  local identity=$1 identity_tmp
  valid_hostname "$identity" || return 1
  identity_tmp=$(mktemp "$SB_DIR/.acme-identity.XXXXXX") || return 1
  if ! printf '%s\n' "$identity" > "$identity_tmp" ||
     ! chmod 600 "$identity_tmp" || ! mv -fT -- "$identity_tmp" "$ACME_IDENTITY"; then
    rm -f "$identity_tmp"
    return 1
  fi
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
  write_acme_identity "$identity" || return 1
  ym_vl_re=apple.com
  certificatec_hy2="$ACME_CERT"
  certificatep_hy2="$ACME_KEY"
  use_acme_cert=1
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
# Signal handlers and EXIT cleanup functions are invoked indirectly by Bash.
# shellcheck disable=SC2317
# sb-acme-reload-v2
export LANG=en_US.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
base="/etc/sb"
cert="/etc/sb/acme-cert.pem"
key="/etc/sb/acme-private.key"
config="/etc/sb/sb.json"
identity_file="/etc/sb/acme_server_name"
systemd_unit="/etc/systemd/system/sb.service"
openrc_unit="/etc/init.d/sb"
stage_cert=
stage_key=
new_generation=
old_current_target=
deployment_started=0
created_layout=0
restore_managed_links=0

cleanup_deploy_files(){
  [[ -z $stage_cert ]] || rm -f -- "$stage_cert"
  [[ -z $stage_key ]] || rm -f -- "$stage_key"
}

switch_current(){
  local target=$1 pointer_tmp
  [[ $target =~ ^generations/gen\.[A-Za-z0-9]+$ ]] || return 1
  pointer_tmp=$(mktemp "$base/acme-live/.current.XXXXXX") || return 1
  rm -f -- "$pointer_tmp" || return 1
  if ! ln -s -- "$target" "$pointer_tmp" ||
     ! mv -Tf -- "$pointer_tmp" "$base/acme-live/current"; then
    rm -f -- "$pointer_tmp"
    return 1
  fi
}

install_managed_link(){
  local destination=$1 target=$2 link_tmp
  link_tmp=$(mktemp "$base/.acme-link.XXXXXX") || return 1
  rm -f -- "$link_tmp" || return 1
  if ! ln -s -- "$target" "$link_tmp" || ! mv -Tf -- "$link_tmp" "$destination"; then
    rm -f -- "$link_tmp"
    return 1
  fi
}

rollback_deployment(){
  local failed=0 pointer_released=0 new_target current_after
  [[ $deployment_started -eq 1 ]] || return 0
  if [[ -n $old_current_target ]]; then
    if switch_current "$old_current_target"; then
      pointer_released=1
    else
      failed=1
    fi
  elif [[ $created_layout -eq 1 ]]; then
    if rm -f -- "$cert" "$key" "$base/acme-live/current"; then
      pointer_released=1
    else
      failed=1
    fi
  fi
  if [[ $restore_managed_links -eq 1 && -n $old_current_target ]]; then
    install_managed_link "$cert" 'acme-live/current/fullchain.pem' || failed=1
    install_managed_link "$key" 'acme-live/current/private.key' || failed=1
    if [[ ! -L $cert || ! -L $key ]] ||
       [[ $(readlink "$cert" 2>/dev/null) != 'acme-live/current/fullchain.pem' ]] ||
       [[ $(readlink "$key" 2>/dev/null) != 'acme-live/current/private.key' ]]; then
      failed=1
    fi
  fi
  if [[ -n $new_generation ]]; then
    new_target="generations/${new_generation##*/}"
    current_after=$(readlink "$base/acme-live/current" 2>/dev/null || true)
    [[ $current_after != "$new_target" ]] && pointer_released=1
  fi
  if [[ $pointer_released -eq 1 && -n $new_generation ]]; then
    rm -rf -- "$new_generation" || failed=1
  fi
  [[ $failed -eq 0 ]] || return 1
  deployment_started=0
  restore_managed_links=0
}

commit_deployment(){
  local current_target generation
  deployment_started=0
  current_target=$(readlink "$base/acme-live/current" 2>/dev/null || true)
  [[ $current_target =~ ^generations/gen\.[A-Za-z0-9]+$ ]] || return 0
  for generation in "$base/acme-live/generations"/gen.*; do
    [[ -e $generation || -L $generation ]] || continue
    [[ $generation == "$base/acme-live/$current_target" ]] && continue
    [[ -d $generation && ! -L $generation && ${generation##*/} =~ ^gen\.[A-Za-z0-9]+$ ]] || continue
    rm -rf -- "$generation" || true
  done
}

handle_deploy_signal(){
  trap '' HUP INT TERM
  rollback_deployment || true
  exit 1
}

managed_service_active(){
  case $service_kind in
    openrc) "$rc_service" sb status >/dev/null 2>&1 ;;
    systemd) systemctl is-active --quiet sb ;;
    *) return 1 ;;
  esac
}

restart_managed_service(){
  case $service_kind in
    openrc) "$rc_service" sb restart >/dev/null 2>&1 ;;
    systemd) systemctl restart sb >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

trap cleanup_deploy_files EXIT
trap handle_deploy_signal HUP INT TERM
[[ -d $base && ! -L $base && -f $identity_file && ! -L $identity_file ]] || exit 1
mapfile -t identity_lines < "$identity_file" || exit 1
[[ ${#identity_lines[@]} -eq 1 ]] || exit 1
identity=${identity_lines[0]}
[[ ${#identity} -le 253 && $identity == *.* && $identity != *..* &&
   $identity =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || exit 1
IFS=. read -r -a identity_labels <<< "$identity"
for label in "${identity_labels[@]}"; do
  [[ ${#label} -le 63 && $label != -* && $label != *- ]] || exit 1
done
source_dir="$base/acme/sb-stage"
source_cert="$source_dir/fullchain.pem"
source_key="$source_dir/private.key"
[[ -d $base/acme && ! -L $base/acme && -d $source_dir && ! -L $source_dir &&
   -f $source_cert && ! -L $source_cert && -f $source_key && ! -L $source_key ]] || exit 1
stage_cert=$(mktemp "$base/.acme-cert.deploy.XXXXXX") || exit 1
stage_key=$(mktemp "$base/.acme-key.deploy.XXXXXX") || exit 1
if ! cp -- "$source_cert" "$stage_cert" || ! cp -- "$source_key" "$stage_key" ||
   ! chmod 600 "$stage_cert" "$stage_key"; then
  exit 1
fi
openssl x509 -in "$stage_cert" -noout -checkend 0 >/dev/null 2>&1 || exit 1
not_before=$(openssl x509 -in "$stage_cert" -noout -startdate 2>/dev/null | cut -d= -f2-) || exit 1
not_before_epoch=$(date -d "$not_before" +%s 2>/dev/null) || exit 1
[[ $not_before_epoch -le $(date +%s) ]] || exit 1
if openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
  openssl x509 -in "$stage_cert" -noout -checkhost "$identity" >/dev/null 2>&1 || exit 1
else
  if openssl x509 -help 2>&1 | grep -q -- '-ext'; then
    san=$(openssl x509 -in "$stage_cert" -noout -ext subjectAltName 2>/dev/null) || exit 1
  else
    san=$(openssl x509 -in "$stage_cert" -noout -text 2>/dev/null | awk '/X509v3 Subject Alternative Name/{getline; print; exit}') || exit 1
  fi
  printf '%s\n' "$san" | grep -oE 'DNS:[^,[:space:]]+' | cut -d: -f2- | grep -Fxiq -- "$identity" || exit 1
fi
cert_public=$(openssl x509 -in "$stage_cert" -pubkey -noout 2>/dev/null) || exit 1
key_public=$(openssl pkey -in "$stage_key" -pubout 2>/dev/null) || exit 1
[[ -n "$cert_public" && "$cert_public" == "$key_public" ]] || exit 1
if [[ -e $base/acme-live || -L $base/acme-live ]]; then
  [[ -d $base/acme-live && ! -L $base/acme-live ]] || exit 1
else
  mkdir "$base/acme-live" || exit 1
  chmod 700 "$base/acme-live" || exit 1
fi
if [[ -e $base/acme-live/generations || -L $base/acme-live/generations ]]; then
  [[ -d $base/acme-live/generations && ! -L $base/acme-live/generations ]] || exit 1
else
  mkdir "$base/acme-live/generations" || exit 1
  chmod 700 "$base/acme-live/generations" || exit 1
fi
new_generation=$(mktemp -d "$base/acme-live/generations/gen.XXXXXX") || exit 1
chmod 700 "$new_generation" || exit 1
deployment_started=1
if ! mv -fT -- "$stage_cert" "$new_generation/fullchain.pem" ||
   ! mv -fT -- "$stage_key" "$new_generation/private.key" ||
   ! chmod 600 "$new_generation/fullchain.pem" "$new_generation/private.key"; then
  rollback_deployment || true
  exit 1
fi
stage_cert=
stage_key=

current_valid=0
if [[ -e $base/acme-live/current || -L $base/acme-live/current ]]; then
  [[ -L $base/acme-live/current ]] || { rollback_deployment || true; exit 1; }
  current_target=$(readlink "$base/acme-live/current" 2>/dev/null) || {
    rollback_deployment || true
    exit 1
  }
  if [[ $current_target =~ ^generations/gen\.[A-Za-z0-9]+$ &&
        -d $base/acme-live/$current_target && ! -L $base/acme-live/$current_target &&
        -f $base/acme-live/$current_target/fullchain.pem &&
        ! -L $base/acme-live/$current_target/fullchain.pem &&
        -f $base/acme-live/$current_target/private.key &&
        ! -L $base/acme-live/$current_target/private.key ]]; then
    current_public=$(openssl x509 -in "$base/acme-live/$current_target/fullchain.pem" \
      -pubkey -noout 2>/dev/null) || current_public=
    current_key_public=$(openssl pkey -in "$base/acme-live/$current_target/private.key" \
      -pubout 2>/dev/null) || current_key_public=
    if [[ -n $current_public && $current_public == "$current_key_public" ]]; then
      current_valid=1
    fi
  fi
  [[ $current_valid -eq 1 ]] || { rollback_deployment || true; exit 1; }
fi

cert_exists=0
key_exists=0
cert_managed=0
key_managed=0
[[ -e $cert || -L $cert ]] && cert_exists=1
[[ -e $key || -L $key ]] && key_exists=1
if [[ -L $cert ]]; then
  [[ $(readlink "$cert" 2>/dev/null) == 'acme-live/current/fullchain.pem' ]] || {
    rollback_deployment || true
    exit 1
  }
  cert_managed=1
elif [[ $cert_exists -eq 1 && ! -f $cert ]]; then
  rollback_deployment || true
  exit 1
fi
if [[ -L $key ]]; then
  [[ $(readlink "$key" 2>/dev/null) == 'acme-live/current/private.key' ]] || {
    rollback_deployment || true
    exit 1
  }
  key_managed=1
elif [[ $key_exists -eq 1 && ! -f $key ]]; then
  rollback_deployment || true
  exit 1
fi

if [[ $cert_exists -eq 1 && $key_exists -eq 1 ]]; then
  old_cert_public=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || old_cert_public=
  old_key_public=$(openssl pkey -in "$key" -pubout 2>/dev/null) || old_key_public=
  [[ -n $old_cert_public && $old_cert_public == "$old_key_public" ]] || {
    rollback_deployment || true
    exit 1
  }
  if [[ $cert_managed -eq 0 && $key_managed -eq 0 ]]; then
    preserved_generation=$(mktemp -d "$base/acme-live/generations/gen.XXXXXX") || {
      rollback_deployment || true
      exit 1
    }
    if ! chmod 700 "$preserved_generation" ||
       ! cp -- "$cert" "$preserved_generation/fullchain.pem" ||
       ! cp -- "$key" "$preserved_generation/private.key" ||
       ! chmod 600 "$preserved_generation/fullchain.pem" "$preserved_generation/private.key"; then
      rm -rf -- "$preserved_generation"
      rollback_deployment || true
      exit 1
    fi
    old_current_target="generations/${preserved_generation##*/}"
    switch_current "$old_current_target" || {
      rm -rf -- "$preserved_generation"
      rollback_deployment || true
      exit 1
    }
  else
    [[ $current_valid -eq 1 ]] || { rollback_deployment || true; exit 1; }
    old_current_target=$current_target
  fi
  if [[ $cert_managed -eq 0 || $key_managed -eq 0 ]]; then
    restore_managed_links=1
  fi
  if [[ $cert_managed -eq 0 ]] &&
     ! install_managed_link "$cert" 'acme-live/current/fullchain.pem'; then
    rollback_deployment || true
    exit 1
  fi
  if [[ $key_managed -eq 0 ]] &&
     ! install_managed_link "$key" 'acme-live/current/private.key'; then
    rollback_deployment || true
    exit 1
  fi
  switch_current "generations/${new_generation##*/}" || {
    rollback_deployment || true
    exit 1
  }
elif [[ $cert_exists -eq 0 && $key_exists -eq 0 ]]; then
  created_layout=1
  switch_current "generations/${new_generation##*/}" || {
    rollback_deployment || true
    exit 1
  }
  install_managed_link "$cert" 'acme-live/current/fullchain.pem' || {
    rollback_deployment || true
    exit 1
  }
  install_managed_link "$key" 'acme-live/current/private.key' || {
    rollback_deployment || true
    exit 1
  }
else
  rollback_deployment || true
  exit 1
fi

if [[ ! -s $config ]]; then
  if [[ ${SB_INITIAL_INSTALL:-0} == 1 ]]; then
    commit_deployment
    exit 0
  fi
  rollback_deployment || true
  exit 1
fi
command -v jq >/dev/null 2>&1 || { rollback_deployment || true; exit 1; }
certificate_paths=$(jq -er '
  [.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb")] as $matches |
  if ($matches | length) == 1 then
    [$matches[0].tls.certificate_path, $matches[0].tls.key_path] | @tsv
  else error("hy2 inbound missing or duplicated") end
' "$config" 2>/dev/null) || { rollback_deployment || true; exit 1; }
IFS=$'\t' read -r current_cert current_key <<< "$certificate_paths"
if [[ $current_cert != "$cert" || $current_key != "$key" ]]; then
  commit_deployment
  exit 0
fi
has_openrc=0
has_systemd=0
[[ -e $openrc_unit || -L $openrc_unit ]] && has_openrc=1
[[ -e $systemd_unit || -L $systemd_unit ]] && has_systemd=1
if ((has_openrc + has_systemd > 1)); then
  rollback_deployment || true
  exit 1
fi
service_kind=none
if ((has_openrc)); then
  if command -v systemctl >/dev/null 2>&1 && systemctl cat sb >/dev/null 2>&1; then
    rollback_deployment || true
    exit 1
  fi
  rc_service=$(command -v rc-service 2>/dev/null) || { rollback_deployment || true; exit 1; }
  [[ -f $openrc_unit && ! -L $openrc_unit ]] || { rollback_deployment || true; exit 1; }
  if ! grep -Fqx '# Managed by sb.sh' "$openrc_unit" 2>/dev/null ||
     ! grep -Fqx 'command="/etc/sb/sing-box"' "$openrc_unit" 2>/dev/null ||
     ! grep -Fqx 'command_args="run -c /etc/sb/sb.json"' "$openrc_unit" 2>/dev/null; then
    rollback_deployment || true
    exit 1
  fi
  service_kind=openrc
elif ((has_systemd)); then
  command -v systemctl >/dev/null 2>&1 || { rollback_deployment || true; exit 1; }
  [[ -f $systemd_unit && ! -L $systemd_unit ]] || { rollback_deployment || true; exit 1; }
  for unit_base in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system \
    /usr/lib/systemd/system /lib/systemd/system; do
    candidate_unit="$unit_base/sb.service"
    [[ $candidate_unit == "$systemd_unit" ]] && continue
    if [[ -e $candidate_unit || -L $candidate_unit ]]; then
      rollback_deployment || true
      exit 1
    fi
  done
  for dropin_dir in /etc/systemd/system/sb.service.d /run/systemd/system/sb.service.d \
    /usr/local/lib/systemd/system/sb.service.d /usr/lib/systemd/system/sb.service.d \
    /lib/systemd/system/sb.service.d; do
    if [[ -L $dropin_dir || -e $dropin_dir && ! -d $dropin_dir ]]; then
      rollback_deployment || true
      exit 1
    fi
    if [[ -d $dropin_dir ]]; then
      for dropin in "$dropin_dir"/* "$dropin_dir"/.[!.]* "$dropin_dir"/..?*; do
        if [[ -e $dropin || -L $dropin ]]; then
          rollback_deployment || true
          exit 1
        fi
      done
    fi
  done
  fragment=$(systemctl show sb.service -p FragmentPath --value 2>/dev/null || true)
  dropins=$(systemctl show sb.service -p DropInPaths --value 2>/dev/null || true)
  [[ -z $fragment || $fragment == "$systemd_unit" ]] || { rollback_deployment || true; exit 1; }
  [[ -z $dropins ]] || { rollback_deployment || true; exit 1; }
  if ! grep -Fqx '# Managed by sb.sh' "$systemd_unit" 2>/dev/null ||
     ! grep -Fqx 'WorkingDirectory=/etc/sb' "$systemd_unit" 2>/dev/null ||
     ! grep -Fqx 'ExecStart=/etc/sb/sing-box run -c /etc/sb/sb.json' "$systemd_unit" 2>/dev/null; then
    rollback_deployment || true
    exit 1
  fi
  service_kind=systemd
else
  if command -v systemctl >/dev/null 2>&1 && systemctl cat sb >/dev/null 2>&1; then
    rollback_deployment || true
    exit 1
  fi
  commit_deployment
  exit 0
fi
if ! managed_service_active; then
  commit_deployment
  exit 0
fi
if restart_managed_service && sleep 1 && managed_service_active; then
  commit_deployment
  exit 0
fi
if rollback_deployment; then
  restart_managed_service >/dev/null 2>&1 || true
  sleep 1
  managed_service_active >/dev/null 2>&1 || true
fi
exit 1
ACMERELOAD
  then
    rm -f "$hook_tmp"
    return 1
  fi
  if ! chmod 700 "$hook_tmp" || ! mv -fT -- "$hook_tmp" "$ACME_RELOAD"; then
    rm -f "$hook_tmp"
    return 1
  fi
  acme_reload_hook_is_current
}

acme_reload_hook_is_current(){
  # Dollar-prefixed names in the grep patterns are literal generated-hook text.
  # shellcheck disable=SC2016
  [[ -f $ACME_RELOAD && ! -L $ACME_RELOAD && -x $ACME_RELOAD ]] &&
    [[ $(grep -Fxc "$ACME_RELOAD_IDENTITY" "$ACME_RELOAD" 2>/dev/null || true) -eq 1 ]] &&
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
    ' "$ACME_RELOAD" &&
    grep -Fqx 'source_cert="$source_dir/fullchain.pem"' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'source_key="$source_dir/private.key"' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'deployment_started=1' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx '    restore_managed_links=1' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'if ! mv -fT -- "$stage_cert" "$new_generation/fullchain.pem" ||' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx '   ! mv -fT -- "$stage_key" "$new_generation/private.key" ||' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx '     ! mv -Tf -- "$pointer_tmp" "$base/acme-live/current"; then' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx "     ! install_managed_link \"\$cert\" 'acme-live/current/fullchain.pem'; then" "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx "     ! install_managed_link \"\$key\" 'acme-live/current/private.key'; then" "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'cert_public=$(openssl x509 -in "$stage_cert" -pubkey -noout 2>/dev/null) || exit 1' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'key_public=$(openssl pkey -in "$stage_key" -pubout 2>/dev/null) || exit 1' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'if restart_managed_service && sleep 1 && managed_service_active; then' "$ACME_RELOAD" 2>/dev/null &&
    bash -n "$ACME_RELOAD" >/dev/null 2>&1
}

prepare_acme_deploy_stage(){
  local path
  if [[ -e $ACME_STAGE || -L $ACME_STAGE ]]; then
    [[ -d $ACME_STAGE && ! -L $ACME_STAGE ]] || return 1
  else
    mkdir "$ACME_STAGE" || return 1
  fi
  chmod 700 "$ACME_STAGE" || return 1
  for path in "$ACME_STAGE_CERT" "$ACME_STAGE_KEY"; do
    [[ -e $path || -L $path ]] || continue
    [[ -f $path && ! -L $path ]] || return 1
  done
}

valid_acme_renewal_identity(){
  local identity
  [[ -x $ACME_BIN && -f $ACME_HOME/dnsapi/dns_cf.sh ]] || return 1
  identity=$(read_acme_identity 2>/dev/null) || return 1
  if ! load_certificate_metadata "$ACME_CERT" "$ACME_KEY" ||
     [[ $CERT_META_STATE != valid ]] ||
     ! certificate_identity_matches "$ACME_CERT" "$identity" ||
     ! load_acme_certificate_schedule "$identity"; then
    return 1
  fi
  printf '%s\n' "$identity"
}

recover_acme_renewal_identity(){
  local identity
  identity=$(detect_acme_identity 2>/dev/null) || return 1
  load_acme_certificate_schedule "$identity" || return 1
  write_acme_identity "$identity" || return 1
  printf '%s\n' "$identity"
}

register_acme_certificate_deployment(){
  local identity=$1 initial_install=${2:-0}
  [[ $initial_install == 0 || $initial_install == 1 ]] || return 1
  valid_hostname "$identity" || return 1
  acme_reload_hook_is_current || return 1
  prepare_acme_deploy_stage || return 1
  if ! SB_INITIAL_INSTALL="$initial_install" HOME="$SB_DIR" "$ACME_BIN" \
      --home "$ACME_HOME" --config-home "$ACME_HOME" \
      --install-cert -d "$identity" --ecc \
      --key-file "$ACME_STAGE_KEY" --fullchain-file "$ACME_STAGE_CERT" \
      --reloadcmd "$ACME_RELOAD"; then
    return 1
  fi
  managed_acme_live_layout_is_valid &&
    acme_deployment_config_is_current "$identity" &&
    load_certificate_metadata "$ACME_CERT" "$ACME_KEY" &&
    [[ $CERT_META_STATE == valid ]] &&
    certificate_identity_matches "$ACME_CERT" "$identity"
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

validate_acme_state_backup(){
  local backup=$1 entry name mode owner expected_owner enforce_modes=1
  local -a state_names=(
    acme-cert.pem acme-private.key acme_server_name acme_reload.sh
    acme_renew.sh acme_renew.state cert_renew.sh .cert_mtime
  )
  [[ $backup == "$SB_DIR"/.acme-backup.* ]] || return 1
  name=${backup##*/}
  [[ $name =~ ^\.acme-backup\.[A-Za-z0-9]+$ ]] || return 1
  [[ -d $backup && ! -L $backup && -d $backup/files && ! -L $backup/files ]] || return 1
  expected_owner=$(id -u 2>/dev/null) || return 1
  case $(uname -s 2>/dev/null) in
    MINGW*|MSYS*) enforce_modes=0 ;;
  esac
  mode=$(stat -c '%a' "$backup" 2>/dev/null) || return 1
  owner=$(stat -c '%u' "$backup" 2>/dev/null) || return 1
  [[ $owner == "$expected_owner" ]] || return 1
  ((enforce_modes == 0)) || [[ $mode == 700 ]] || return 1
  mode=$(stat -c '%a' "$backup/files" 2>/dev/null) || return 1
  owner=$(stat -c '%u' "$backup/files" 2>/dev/null) || return 1
  [[ $owner == "$expected_owner" ]] || return 1
  ((enforce_modes == 0)) || [[ $mode == 700 ]] || return 1

  for entry in "$backup"/* "$backup"/.[!.]* "$backup"/..?*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    case $name in
      files) [[ -d $entry && ! -L $entry ]] || return 1 ;;
      acme|live)
        [[ -d $entry && ! -L $entry ]] || return 1
        mode=$(stat -c '%a' "$entry" 2>/dev/null) || return 1
        owner=$(stat -c '%u' "$entry" 2>/dev/null) || return 1
        [[ $owner == "$expected_owner" ]] || return 1
        ((enforce_modes == 0)) || [[ $mode == 700 ]] || return 1
        ;;
      *) return 1 ;;
    esac
  done
  for entry in "$backup/files"/* "$backup/files"/.[!.]* "$backup/files"/..?*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    printf '%s\n' "${state_names[@]}" | grep -Fxq -- "$name" || return 1
    owner=$(stat -c '%u' "$entry" 2>/dev/null) || return 1
    [[ $owner == "$expected_owner" ]] || return 1
    if [[ -L $entry ]]; then
      case $name in
        acme-cert.pem) [[ $(readlink "$entry" 2>/dev/null) == 'acme-live/current/fullchain.pem' ]] ;;
        acme-private.key) [[ $(readlink "$entry" 2>/dev/null) == 'acme-live/current/private.key' ]] ;;
        *) false ;;
      esac || return 1
    else
      [[ -f $entry ]] || return 1
      mode=$(stat -c '%a' "$entry" 2>/dev/null) || return 1
      ((enforce_modes == 0)) || (( (8#$mode & 0022) == 0 )) || return 1
    fi
  done
}

acme_state_backup_certificate_pair_is_valid(){
  local backup=$1 backup_cert backup_key current_target generation
  validate_acme_state_backup "$backup" || return 1
  backup_cert="$backup/files/acme-cert.pem"
  backup_key="$backup/files/acme-private.key"
  if [[ -f $backup_cert && ! -L $backup_cert && -f $backup_key && ! -L $backup_key ]]; then
    :
  elif [[ -L $backup_cert && -L $backup_key ]] &&
       [[ $(readlink "$backup_cert" 2>/dev/null) == 'acme-live/current/fullchain.pem' ]] &&
       [[ $(readlink "$backup_key" 2>/dev/null) == 'acme-live/current/private.key' ]] &&
       [[ -d $backup/live && ! -L $backup/live && -L $backup/live/current ]]; then
    current_target=$(readlink "$backup/live/current" 2>/dev/null) || return 1
    [[ $current_target =~ ^generations/gen\.[A-Za-z0-9]+$ ]] || return 1
    generation="$backup/live/$current_target"
    [[ -d $generation && ! -L $generation ]] || return 1
    backup_cert="$generation/fullchain.pem"
    backup_key="$generation/private.key"
    [[ -f $backup_cert && ! -L $backup_cert && -f $backup_key && ! -L $backup_key ]] || return 1
  else
    return 1
  fi
  certificate_time_valid "$backup_cert" && certificate_key_matches "$backup_cert" "$backup_key"
}

current_acme_state_is_safe_to_keep(){
  local identity
  identity=$(valid_acme_renewal_identity 2>/dev/null) || return 1
  managed_acme_live_layout_is_valid &&
    acme_deployment_config_is_current "$identity" &&
    cloudflare_acme_credentials_present &&
    acme_reload_hook_is_current
}

find_orphaned_acme_state_backup(){
  local path candidate='' count=0
  ACME_ORPHANED_BACKUP_COUNT=0
  [[ -z ${ACME_STATE_BACKUP:-} ]] || {
    return 2
  }
  for path in "$SB_DIR"/.acme-backup.*; do
    [[ -e $path || -L $path ]] || continue
    count=$((count + 1))
    candidate=$path
  done
  ACME_ORPHANED_BACKUP_COUNT=$count
  [[ $count -ne 0 ]] || return 1
  if [[ $count -ne 1 ]]; then
    return 2
  fi
  if ! validate_acme_state_backup "$candidate"; then
    return 2
  fi
  ACME_STATE_BACKUP=$candidate
}

acme_state_backup_candidates_exist(){
  local path
  for path in "$SB_DIR"/.acme-backup.*; do
    [[ -e $path || -L $path ]] && return 0
  done
  return 1
}

resolve_orphaned_acme_state_backup(){
  local scan_status menu confirmation backup
  if find_orphaned_acme_state_backup; then
    scan_status=0
  else
    scan_status=$?
  fi
  case $scan_status in
    1) return 0 ;;
    2)
      red "检测到 ${ACME_ORPHANED_BACKUP_COUNT:-0} 个异常或重复的 ACME 恢复点，拒绝自动选择"
      yellow "请人工检查 $SB_DIR/.acme-backup.*；处理前脚本不会执行证书、修复或卸载操作"
      return 1
      ;;
  esac
  backup=$ACME_STATE_BACKUP
  while true; do
    yellow "检测到上次证书操作留下的安全恢复点：$backup"
    green "1：恢复到证书操作前的状态"
    green "2：确认保留当前证书状态并删除恢复点"
    green "0：退出脚本，不做修改"
    readp "请选择【0-2】：" menu || return 1
    case $menu in
      1)
        if config_references_acme_state &&
           ! acme_state_backup_certificate_pair_is_valid "$backup"; then
          red "当前配置正在使用 ACME 证书，但恢复点中没有可用的证书与私钥，拒绝恢复"
          yellow "如已确认当前证书正常，可选择[2]删除恢复点"
          continue
        fi
        if ! restore_acme_state_backup 1; then
          red "恢复 ACME 状态失败，恢复点已保留；脚本将退出"
          return 1
        fi
        if config_uses_acme_certificate; then
          if ! cert_acme; then
            red "恢复后的 ACME 证书校验失败，恢复点已保留；脚本将退出"
            return 1
          fi
          if service_is_active && (! restartsb || ! service_is_active); then
            red "ACME 状态已恢复，但 sb 重启失败，恢复点已保留；脚本将退出"
            return 1
          fi
        fi
        if ! clear_acme_state_backup; then
          red "ACME 状态已恢复，但恢复点清理失败；脚本将退出"
          return 1
        fi
        green "证书操作前的 ACME 状态已恢复"
        return 0
        ;;
      2)
        if config_references_acme_state &&
           (! config_uses_acme_certificate ||
            ! current_acme_state_is_safe_to_keep); then
          red "当前 ACME 证书或续期状态未通过校验，拒绝删除唯一恢复点"
          continue
        fi
        red "删除恢复点后将无法自动回到证书操作前的状态"
        readp "请输入 DELETE 确认删除，其他输入取消：" confirmation || return 1
        [[ $confirmation == DELETE ]] || continue
        if ! clear_acme_state_backup; then
          red "删除 ACME 恢复点失败，脚本将退出"
          return 1
        fi
        green "已保留当前证书状态并删除旧恢复点"
        return 0
        ;;
      0|"") return 1 ;;
      *) red "请输入0、1或2" ;;
    esac
  done
}

begin_acme_state_backup(){
  local backup path
  local -a state_paths=(
    "$ACME_CERT" "$ACME_KEY" "$ACME_IDENTITY" "$ACME_RELOAD"
    "$SB_DIR/acme_renew.sh" "$SB_DIR/acme_renew.state"
    "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
  )
  [[ -z ${ACME_STATE_BACKUP:-} ]] || return 1
  backup=$(mktemp -d "$SB_DIR/.acme-backup.XXXXXX") || return 1
  chmod 700 "$backup" || { rm -rf -- "$backup"; return 1; }
  if ! mkdir "$backup/files" || ! chmod 700 "$backup/files"; then
    rm -rf -- "$backup"
    return 1
  fi
  if [[ -e $ACME_HOME || -L $ACME_HOME ]]; then
    if [[ ! -d $ACME_HOME || -L $ACME_HOME ]] || ! cp -a -- "$ACME_HOME" "$backup/acme"; then
      rm -rf -- "$backup"
      return 1
    fi
  fi
  if [[ -e $ACME_LIVE || -L $ACME_LIVE ]]; then
    if [[ ! -d $ACME_LIVE || -L $ACME_LIVE ]] ||
       ! cp -a -- "$ACME_LIVE" "$backup/live"; then
      rm -rf -- "$backup"
      return 1
    fi
  fi
  for path in "${state_paths[@]}"; do
    [[ -e $path || -L $path ]] || continue
    if [[ -L $path ]]; then
      case $path in
        "$ACME_CERT") [[ $(readlink "$path" 2>/dev/null) == 'acme-live/current/fullchain.pem' ]] ;;
        "$ACME_KEY") [[ $(readlink "$path" 2>/dev/null) == 'acme-live/current/private.key' ]] ;;
        *) false ;;
      esac || { rm -rf -- "$backup"; return 1; }
      cp -Pp -- "$path" "$backup/files/${path##*/}" || {
        rm -rf -- "$backup"
        return 1
      }
    elif [[ ! -f $path ]] || ! cp -p -- "$path" "$backup/files/${path##*/}"; then
      rm -rf -- "$backup"
      return 1
    fi
  done
  ACME_STATE_BACKUP=$backup
}

clear_acme_state_backup(){
  local backup=${ACME_STATE_BACKUP:-}
  [[ -n $backup ]] || return 0
  validate_acme_state_backup "$backup" || return 1
  rm -rf -- "$backup" || return 1
  ACME_STATE_BACKUP=
}

restore_acme_state_backup(){
  local backup=${ACME_STATE_BACKUP:-} retain_backup=${1:-0} stage entry name destination index
  local -a state_names=(
    acme-cert.pem acme-private.key acme_server_name acme_reload.sh
    acme_renew.sh acme_renew.state cert_renew.sh .cert_mtime
  )
  local -a state_paths=(
    "$ACME_CERT" "$ACME_KEY" "$ACME_IDENTITY" "$ACME_RELOAD"
    "$SB_DIR/acme_renew.sh" "$SB_DIR/acme_renew.state"
    "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime"
  )
  [[ $retain_backup == 0 || $retain_backup == 1 ]] || return 1
  [[ -n $backup ]] || return 0
  validate_acme_state_backup "$backup" || return 1
  stage=$(mktemp -d "$SB_DIR/.acme-restore.XXXXXX") || return 1
  chmod 700 "$stage" || { rm -rf -- "$stage"; return 1; }
  if ! mkdir "$stage/files" || ! chmod 700 "$stage/files"; then
    rm -rf -- "$stage"
    return 1
  fi
  if [[ -e $backup/acme || -L $backup/acme ]]; then
    if [[ ! -d $backup/acme || -L $backup/acme ]] ||
       ! cp -a -- "$backup/acme" "$stage/acme"; then
      rm -rf -- "$stage"
      return 1
    fi
  fi
  if [[ -e $backup/live || -L $backup/live ]]; then
    if [[ ! -d $backup/live || -L $backup/live ]] ||
       ! cp -a -- "$backup/live" "$stage/live"; then
      rm -rf -- "$stage"
      return 1
    fi
  fi
  for entry in "$backup/files"/* "$backup/files"/.[!.]* "$backup/files"/..?*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    printf '%s\n' "${state_names[@]}" | grep -Fxq -- "$name" || {
      rm -rf -- "$stage"
      return 1
    }
    if [[ -L $entry ]]; then
      case $name in
        acme-cert.pem) [[ $(readlink "$entry" 2>/dev/null) == 'acme-live/current/fullchain.pem' ]] ;;
        acme-private.key) [[ $(readlink "$entry" 2>/dev/null) == 'acme-live/current/private.key' ]] ;;
        *) false ;;
      esac || { rm -rf -- "$stage"; return 1; }
      cp -Pp -- "$entry" "$stage/files/$name" || { rm -rf -- "$stage"; return 1; }
    elif [[ -f $entry ]]; then
      cp -p -- "$entry" "$stage/files/$name" || { rm -rf -- "$stage"; return 1; }
    else
      rm -rf -- "$stage"
      return 1
    fi
  done

  rm -rf -- "$ACME_HOME" || { rm -rf -- "$stage"; return 1; }
  rm -rf -- "$ACME_LIVE" || { rm -rf -- "$stage"; return 1; }
  for destination in "${state_paths[@]}"; do
    rm -f -- "$destination" || { rm -rf -- "$stage"; return 1; }
  done
  if [[ -d $stage/acme ]]; then
    mv -fT -- "$stage/acme" "$ACME_HOME" || { rm -rf -- "$stage"; return 1; }
  fi
  if [[ -d $stage/live ]]; then
    mv -fT -- "$stage/live" "$ACME_LIVE" || { rm -rf -- "$stage"; return 1; }
  fi
  for index in "${!state_names[@]}"; do
    entry="$stage/files/${state_names[$index]}"
    [[ -e $entry || -L $entry ]] || continue
    destination=${state_paths[$index]}
    mv -fT -- "$entry" "$destination" || { rm -rf -- "$stage"; return 1; }
  done
  rm -rf -- "$stage" || return 1
  if [[ $retain_backup == 0 ]]; then
    rm -rf -- "$backup" || return 1
    ACME_STATE_BACKUP=
  fi
}

discard_acme_state(){
  local path failed=0
  rm -rf "$ACME_HOME" "$ACME_LIVE" || failed=1
  rm -f "$ACME_CERT" "$ACME_KEY" "$ACME_IDENTITY" "$ACME_RELOAD" \
    "$SB_DIR/acme_renew.sh" "$SB_DIR/acme_renew.state" \
    "$SB_DIR/cert_renew.sh" "$SB_DIR/.cert_mtime" || failed=1
  for path in "$ACME_HOME" "$ACME_LIVE" "$ACME_CERT" "$ACME_KEY" "$ACME_IDENTITY" "$ACME_RELOAD" \
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
  local domain_input account_id cf_token backup_path
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
  if ! write_acme_identity "$ACME_PRIMARY_DOMAIN"; then
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  fi
  if ! register_acme_certificate_deployment "$ACME_PRIMARY_DOMAIN" "$initial_install"; then
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

self_signed_certificate_is_valid(){
  load_certificate_metadata "$SB_DIR/cert.pem" "$SB_DIR/private.key" &&
    [[ $CERT_META_STATE == valid ]] &&
    certificate_identity_matches "$SB_DIR/cert.pem" www.bing.com
}

generate_self_signed_certificate(){
  local selfsign_config key_tmp cert_tmp key_backup='' cert_backup='' path
  local key_path="$SB_DIR/private.key" cert_path="$SB_DIR/cert.pem"
  for path in "$key_path" "$cert_path"; do
    if [[ -e $path || -L $path ]]; then
      [[ -f $path && ! -L $path ]] || return 1
    fi
  done
  selfsign_config=$(mktemp "$SB_DIR/.selfsign-openssl.XXXXXX") || return 1
  key_tmp=$(mktemp "$SB_DIR/.selfsign-key.XXXXXX") || {
    rm -f "$selfsign_config"
    return 1
  }
  cert_tmp=$(mktemp "$SB_DIR/.selfsign-cert.XXXXXX") || {
    rm -f "$selfsign_config" "$key_tmp"
    return 1
  }
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
    rm -f "$selfsign_config" "$key_tmp" "$cert_tmp"
    return 1
  fi
  if ! openssl ecparam -genkey -name prime256v1 -out "$key_tmp" ||
     ! openssl req -new -x509 -days 36500 -key "$key_tmp" \
       -out "$cert_tmp" -config "$selfsign_config" ||
     ! chmod 600 "$key_tmp" "$cert_tmp" ||
     ! load_certificate_metadata "$cert_tmp" "$key_tmp" ||
     [[ $CERT_META_STATE != valid ]] ||
     ! certificate_identity_matches "$cert_tmp" www.bing.com; then
    rm -f "$selfsign_config" "$key_tmp" "$cert_tmp"
    return 1
  fi
  rm -f "$selfsign_config"
  if [[ -f $key_path ]]; then
    key_backup=$(mktemp "$SB_DIR/.selfsign-key.backup.XXXXXX") || {
      rm -f "$key_tmp" "$cert_tmp"
      return 1
    }
    cp -p -- "$key_path" "$key_backup" || {
      rm -f "$key_tmp" "$cert_tmp" "$key_backup"
      return 1
    }
  fi
  if [[ -f $cert_path ]]; then
    cert_backup=$(mktemp "$SB_DIR/.selfsign-cert.backup.XXXXXX") || {
      rm -f "$key_tmp" "$cert_tmp" "$key_backup"
      return 1
    }
    cp -p -- "$cert_path" "$cert_backup" || {
      rm -f "$key_tmp" "$cert_tmp" "$key_backup" "$cert_backup"
      return 1
    }
  fi
  if ! mv -fT -- "$key_tmp" "$key_path" ||
     ! mv -fT -- "$cert_tmp" "$cert_path"; then
    if [[ -n $key_backup ]]; then cp -p -- "$key_backup" "$key_path"; else rm -f "$key_path"; fi
    if [[ -n $cert_backup ]]; then cp -p -- "$cert_backup" "$cert_path"; else rm -f "$cert_path"; fi
    rm -f "$key_tmp" "$cert_tmp" "$key_backup" "$cert_backup"
    return 1
  fi
  rm -f "$key_backup" "$cert_backup"
  chmod 600 "$key_path" "$cert_path" && self_signed_certificate_is_valid
}

inscertificate(){
  local menu acme_name
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "二、生成并设置相关证书"
  echo
  blue "自动生成bing自签证书中……" && sleep 2
  if ! generate_self_signed_certificate; then
    red "生成bing自签证书失败"
    return 1
  fi
  echo
  blue "生成bing自签证书成功"
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
