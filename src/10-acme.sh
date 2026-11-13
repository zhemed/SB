# sb-module: 10-acme
cert_self_signed(){
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

# acme.sh 自己把用过的 DNS 凭据写进 account.conf：Cloudflare 是 SAVED_CF_*，
# 华为云是插件通过 _saveaccountconf_mutable 写入的 SAVED_HUAWEICLOUD_*。
# 每次签发前 reset_acme_state 会整体删除 ACME_HOME，所以这里不必新增状态文件。
huaweicloud_acme_credentials_present(){
  local account_conf="$ACME_HOME/account.conf" ak_count sk_count region_count
  [[ -f $account_conf && ! -L $account_conf ]] || return 1
  ak_count=$(grep -Ec "^SAVED_HUAWEICLOUD_ACCESS_KEY_ID='[^']+'$" "$account_conf" 2>/dev/null || true)
  sk_count=$(grep -Ec "^SAVED_HUAWEICLOUD_SECRET_ACCESS_KEY='[^']+'$" "$account_conf" 2>/dev/null || true)
  region_count=$(grep -Ec "^SAVED_HUAWEICLOUD_REGION='[^']+'$" "$account_conf" 2>/dev/null || true)
  [[ $ak_count -eq 1 && $sk_count -eq 1 && $region_count -eq 1 ]]
}

acme_dns_provider_detected(){
  local cloudflare=0 huaweicloud=0
  if cloudflare_acme_credentials_present; then
    cloudflare=1
  fi
  if huaweicloud_acme_credentials_present; then
    huaweicloud=1
  fi
  # 两家同时命中说明凭据是拼接出来的，不猜；都不命中说明状态不完整。
  if ((cloudflare + huaweicloud != 1)); then
    return 1
  fi
  if ((cloudflare == 1)); then
    printf '%s\n' cloudflare
  else
    printf '%s\n' huaweicloud
  fi
}

acme_credentials_present(){
  acme_dns_provider_detected >/dev/null
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

valid_dns_provider(){
  [[ ${1-} == cloudflare || ${1-} == huaweicloud ]]
}

dns_provider_plugin_file(){
  case ${1-} in
    cloudflare) printf '%s\n' 'dns_cf.sh' ;;
    huaweicloud) printf '%s\n' 'dns_huaweicloud_aksk.sh' ;;
    *) return 1 ;;
  esac
}

dns_provider_label(){
  case ${1-} in
    cloudflare) printf '%s\n' 'Cloudflare' ;;
    huaweicloud) printf '%s\n' '华为云' ;;
    *) return 1 ;;
  esac
}

valid_huaweicloud_access_key_id(){
  [[ ${1-} =~ ^[A-Za-z0-9_-]{16,64}$ ]]
}

valid_huaweicloud_secret_access_key(){
  [[ ${1-} =~ ^[A-Za-z0-9+/=_-]{16,128}$ ]]
}

valid_huaweicloud_region(){
  [[ ${1-} =~ ^[A-Za-z0-9_-]{2,32}$ ]]
}

huawei_aksk_plugin_path(){
  printf '%s\n' "$ACME_HOME/dnsapi/dns_huaweicloud_aksk.sh"
}

# 自定义插件是受管文件：常规文件、非符号链接、marker 恰好一行、bash -n 通过。
huawei_aksk_plugin_ok(){
  local plugin marker_count
  plugin=$(huawei_aksk_plugin_path) || return 1
  [[ -f $plugin && ! -L $plugin ]] || return 1
  marker_count=$(grep -Fxc -- '# sb-huaweicloud-aksk: v1' "$plugin" 2>/dev/null || true)
  [[ $marker_count -eq 1 ]] || return 1
  bash -n "$plugin" >/dev/null 2>&1
}

write_huawei_aksk_plugin(){
  local plugin plugin_tmp
  plugin=$(huawei_aksk_plugin_path) || return 1
  if huawei_aksk_plugin_ok; then
    return 0
  fi
  [[ -d $ACME_HOME/dnsapi && ! -L $ACME_HOME/dnsapi ]] || return 1
  plugin_tmp=$(mktemp "$ACME_HOME/.aksk-plugin.XXXXXX") || return 1
  if ! cat > "$plugin_tmp" <<'HWAKSK'
#!/bin/sh
# sb-huaweicloud-aksk: v1
# Custom Huawei Cloud DNS dnsapi plugin for acme.sh using AK/SK signing (DNS v2 API).
# Requires: curl, openssl, jq. Uses acme.sh helpers when sourced.
export LANG=en_US.UTF-8

_hwak_sha256_hex(){
  openssl dgst -sha256 -hex | sed 's/^.*= //'
}

_hwak_hmac_hex(){
  openssl dgst -sha256 -hmac "$1" -binary | od -An -tx1 | tr -d ' \n'
}

_hwak_urlencode(){
  printf '%s' "$1" | jq -sRr @uri
}

_hwak_canonical_query(){
  printf '%s' "$1" | tr '&' '\n' | grep -v '^$' | sort | \
    awk -F= '{ if (sep) printf "&"; printf "%s=%s", $1, $2; sep=1 }'
}

_hwak_sign(){
  local method=$1 path=$2 query=$3 headers=$4 signed=$5 body=$6 sdk_date=$7
  local payload_hash canonical string2sign signature nl
  nl='
'
  case $headers in
    *"$nl") ;;
    *) headers="$headers$nl" ;;
  esac
  case $path in
    */) ;;
    *) path="$path/" ;;
  esac
  payload_hash=$(printf '%s' "$body" | _hwak_sha256_hex) || return 1
  canonical=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    "$method" "$path" "$query" "$headers" "$signed" "$payload_hash") || return 1
  string2sign=$(printf 'SDK-HMAC-SHA256\n%s\n%s' \
    "$sdk_date" "$(printf '%s' "$canonical" | _hwak_sha256_hex)") || return 1
  signature=$(printf '%s' "$string2sign" | _hwak_hmac_hex "$HUAWEICLOUD_SECRET_ACCESS_KEY") || return 1
  printf 'SDK-HMAC-SHA256 Access=%s, SignedHeaders=%s, Signature=%s' \
    "$HUAWEICLOUD_ACCESS_KEY_ID" "$signed" "$signature"
}

_hwak_request(){
  local method=$1 path=$2 query=$3 body=$4
  local sdk_date endpoint headers signed auth url code response out canonical_query
  [ -n "$HUAWEICLOUD_ACCESS_KEY_ID" ] || return 1
  [ -n "$HUAWEICLOUD_SECRET_ACCESS_KEY" ] || return 1
  [ -n "$HUAWEICLOUD_REGION" ] || return 1
  sdk_date=$(date -u +%Y%m%dT%H%M%SZ) || return 1
  endpoint="dns.$HUAWEICLOUD_REGION.myhuaweicloud.com"
  headers=$(printf 'content-type:application/json\nhost:%s\nx-sdk-date:%s\n' "$endpoint" "$sdk_date")
  signed='content-type;host;x-sdk-date'
  canonical_query=$(_hwak_canonical_query "$query")
  url="https://$endpoint$path"
  [ -z "$canonical_query" ] || url="$url?$canonical_query"
  auth=$(_hwak_sign "$method" "$path" "$canonical_query" "$headers" "$signed" "$body" "$sdk_date") || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/hwak.XXXXXX") || return 1
  if [ -n "$body" ]; then
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" \
      -H "Content-Type: application/json" -H "Host: $endpoint" \
      -H "X-Sdk-Date: $sdk_date" -H "Authorization: $auth" \
      --connect-timeout 10 --max-time 30 --data "$body" "$url" 2>/dev/null) || { rm -f "$out"; return 1; }
  else
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" \
      -H "Content-Type: application/json" -H "Host: $endpoint" \
      -H "X-Sdk-Date: $sdk_date" -H "Authorization: $auth" \
      --connect-timeout 10 --max-time 30 "$url" 2>/dev/null) || { rm -f "$out"; return 1; }
  fi
  response=$(cat "$out" 2>/dev/null)
  rm -f "$out"
  case $code in
    2??) ;;
    *) _err "huaweicloud aksk: HTTP $code $response"; return 1 ;;
  esac
  printf '%s' "$response"
}

_hwak_find_zone(){
  local fulldomain=$1 zone resp id
  zone=$fulldomain
  while :; do
    case $zone in
      *.*) zone=${zone#*.} ;;
      *) break ;;
    esac
    resp=$(_hwak_request GET "/v2/zones" "type=public&name=$(_hwak_urlencode "$zone")" "") || return 1
    id=$(printf '%s' "$resp" | jq -r --arg z "$zone" '.zones[]? | select(.name == ($z + ".")) | .id' | head -n 1)
    [ -n "$id" ] || continue
    printf '%s' "$id"
    return 0
  done
  return 1
}

_hwak_find_recordset(){
  local fulldomain=$1 resp
  resp=$(_hwak_request GET "/v2/recordsets" "type=TXT&name=$(_hwak_urlencode "$fulldomain")" "") || return 1
  printf '%s' "$resp" | jq -c --arg f "$fulldomain" '.recordsets[]? | select(.name == ($f + "."))'
}

_hwak_append_record(){
  local zone_id=$1 fulldomain=$2 txtvalue=$3 rs=$4
  local id records new_records_json body
  id=$(printf '%s' "$rs" | jq -r '.id')
  [ -n "$id" ] || return 1
  records=$(printf '%s' "$rs" | jq -r '.records[]?')
  new_records_json=$(printf '%s\n' "$records" | \
    awk -v v="\"$txtvalue\"" 'BEGIN{found=0} {if ($0==v) found=1; else print} END{if (!found) print v}' | \
    jq -Rsc 'split("\n") | map(select(length>0))')
  body=$(jq -nc --arg name "$fulldomain." --argjson records "$new_records_json" \
    '{name:$name, type:"TXT", ttl:300, records:$records}')
  _hwak_request PUT "/v2/zones/$zone_id/recordsets/$id" "" "$body" >/dev/null || return 1
}

dns_huaweicloud_aksk_add(){
  local fulldomain=$1 txtvalue=$2 zone_id rs body
  HUAWEICLOUD_ACCESS_KEY_ID="${HUAWEICLOUD_ACCESS_KEY_ID:-$(_readaccountconf_mutable HUAWEICLOUD_ACCESS_KEY_ID)}"
  HUAWEICLOUD_SECRET_ACCESS_KEY="${HUAWEICLOUD_SECRET_ACCESS_KEY:-$(_readaccountconf_mutable HUAWEICLOUD_SECRET_ACCESS_KEY)}"
  HUAWEICLOUD_REGION="${HUAWEICLOUD_REGION:-$(_readaccountconf_mutable HUAWEICLOUD_REGION)}"
  if [ -z "$HUAWEICLOUD_ACCESS_KEY_ID" ] || [ -z "$HUAWEICLOUD_SECRET_ACCESS_KEY" ] || [ -z "$HUAWEICLOUD_REGION" ]; then
    _err "Not enough information provided to dns_huaweicloud_aksk!"
    return 1
  fi
  _saveaccountconf_mutable HUAWEICLOUD_ACCESS_KEY_ID "$HUAWEICLOUD_ACCESS_KEY_ID"
  _saveaccountconf_mutable HUAWEICLOUD_SECRET_ACCESS_KEY "$HUAWEICLOUD_SECRET_ACCESS_KEY"
  _saveaccountconf_mutable HUAWEICLOUD_REGION "$HUAWEICLOUD_REGION"
  zone_id=$(_hwak_find_zone "$fulldomain") || { _err "huaweicloud aksk: cannot find zone for $fulldomain"; return 1; }
  rs=$(_hwak_find_recordset "$fulldomain") || return 1
  if [ -z "$rs" ]; then
    body=$(printf '{"name":"%s.","type":"TXT","ttl":300,"records":["\\"%s\\""]}' "$fulldomain" "$txtvalue")
    _hwak_request POST "/v2/zones/$zone_id/recordsets" "" "$body" >/dev/null || return 1
  else
    _hwak_append_record "$zone_id" "$fulldomain" "$txtvalue" "$rs" || return 1
  fi
}

dns_huaweicloud_aksk_rm(){
  local fulldomain=$1 txtvalue=$2 zone_id rs id records new_records_json body
  HUAWEICLOUD_ACCESS_KEY_ID="${HUAWEICLOUD_ACCESS_KEY_ID:-$(_readaccountconf_mutable HUAWEICLOUD_ACCESS_KEY_ID)}"
  HUAWEICLOUD_SECRET_ACCESS_KEY="${HUAWEICLOUD_SECRET_ACCESS_KEY:-$(_readaccountconf_mutable HUAWEICLOUD_SECRET_ACCESS_KEY)}"
  HUAWEICLOUD_REGION="${HUAWEICLOUD_REGION:-$(_readaccountconf_mutable HUAWEICLOUD_REGION)}"
  [ -n "$HUAWEICLOUD_ACCESS_KEY_ID" ] && [ -n "$HUAWEICLOUD_SECRET_ACCESS_KEY" ] && [ -n "$HUAWEICLOUD_REGION" ] || return 1
  zone_id=$(_hwak_find_zone "$fulldomain") || return 0
  rs=$(_hwak_find_recordset "$fulldomain") || return 0
  [ -n "$rs" ] || return 0
  id=$(printf '%s' "$rs" | jq -r '.id')
  [ -n "$id" ] || return 1
  records=$(printf '%s' "$rs" | jq -r '.records[]?')
  new_records_json=$(printf '%s\n' "$records" | awk -v v="\"$txtvalue\"" '$0 != v' | jq -Rsc 'split("\n") | map(select(length>0))')
  if [ "$new_records_json" = "[]" ]; then
    _hwak_request DELETE "/v2/zones/$zone_id/recordsets/$id" "" "" >/dev/null || return 1
  else
    body=$(jq -nc --arg name "$fulldomain." --argjson records "$new_records_json" \
      '{name:$name, type:"TXT", ttl:300, records:$records}')
    _hwak_request PUT "/v2/zones/$zone_id/recordsets/$id" "" "$body" >/dev/null || return 1
  fi
}
HWAKSK
  then
    rm -f "$plugin_tmp"
    return 1
  fi
  if ! chmod 700 "$plugin_tmp" || ! mv -fT -- "$plugin_tmp" "$plugin"; then
    rm -f "$plugin_tmp"
    return 1
  fi
  huawei_aksk_plugin_ok
}

ensure_acme_dns_plugin(){
  local provider plugin
  provider=$(acme_dns_provider_detected 2>/dev/null) || return 1
  plugin=$(dns_provider_plugin_file "$provider") || return 1
  if [[ $provider == huaweicloud ]]; then
    write_huawei_aksk_plugin
    return
  fi
  [[ -f $ACME_HOME/dnsapi/$plugin && ! -L $ACME_HOME/dnsapi/$plugin ]]
}

# ---- 共享证书库（/etc/cert-store）----------------------------------------
# 契约见 .trellis/tasks/11-13-shared-cert-store/design.md。
# owner 是唯一允许签发/续期的工具；consumer 只领养（配置指向 current 路径），绝不签发。
cert_store_root(){
  printf '%s\n' "${CERT_STORE:-/etc/cert-store}"
}

cert_store_modes_enforced(){
  case $(uname -s 2>/dev/null) in
    MINGW*|MSYS*) return 1 ;;
    *) return 0 ;;
  esac
}

cert_store_private_dir(){
  local path=$1 owner expected_owner mode
  [[ -d $path && ! -L $path ]] || return 1
  expected_owner=$(id -u 2>/dev/null) || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  [[ $owner == "$expected_owner" ]] || return 1
  cert_store_modes_enforced || return 0
  mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
  [[ $mode == 700 ]]
}

cert_store_private_file(){
  local path=$1 owner expected_owner mode
  [[ -f $path && ! -L $path ]] || return 1
  expected_owner=$(id -u 2>/dev/null) || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  [[ $owner == "$expected_owner" ]] || return 1
  cert_store_modes_enforced || return 0
  mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
  [[ $mode == 600 ]]
}

cert_store_domain_dir(){
  local apex=$1
  [[ $apex == "${apex,,}" ]] || return 1
  valid_hostname "$apex" || return 1
  printf '%s/%s\n' "$(cert_store_root)" "$apex"
}

cert_store_meta_path(){
  local dir
  dir=$(cert_store_domain_dir "$1") || return 1
  printf '%s/meta.env\n' "$dir"
}

cert_store_current_cert_path(){
  local dir
  dir=$(cert_store_domain_dir "$1") || return 1
  printf '%s/current/fullchain.pem\n' "$dir"
}

cert_store_current_key_path(){
  local dir
  dir=$(cert_store_domain_dir "$1") || return 1
  printf '%s/current/private.key\n' "$dir"
}

cert_store_lock_path(){
  printf '%s/.lock\n' "$(cert_store_root)"
}

cert_store_valid_owner(){
  [[ ${1-} == sb || ${1-} == acme-nginx || ${1-} == none ]]
}

cert_store_valid_alt(){
  local alt=${1-} apex=${2-}
  [[ -z $alt ]] && return 0
  [[ $alt == "*.$apex" ]] || return 1
  valid_hostname "${alt#\*.}"
}

cert_store_read_meta(){
  local apex=$1 meta line key value
  local version='' domain='' alt='' owner='' issuer='' issued_at='' not_after=''
  local fingerprint='' updated_at='' updated_by=''
  local version_count=0 domain_count=0 alt_count=0 owner_count=0 issuer_count=0
  local issued_at_count=0 not_after_count=0 fingerprint_count=0 updated_at_count=0
  local updated_by_count=0
  # 元数据供 owner/领养/健康检查读取，显式导出而非仅赋值。
  export CERT_STORE_META_VERSION CERT_STORE_META_DOMAIN CERT_STORE_META_ALT \
    CERT_STORE_META_OWNER CERT_STORE_META_ISSUER CERT_STORE_META_ISSUED_AT \
    CERT_STORE_META_NOT_AFTER CERT_STORE_META_FINGERPRINT \
    CERT_STORE_META_UPDATED_AT CERT_STORE_META_UPDATED_BY
  CERT_STORE_META_VERSION=
  CERT_STORE_META_DOMAIN=
  CERT_STORE_META_ALT=
  CERT_STORE_META_OWNER=
  CERT_STORE_META_ISSUER=
  CERT_STORE_META_ISSUED_AT=
  CERT_STORE_META_NOT_AFTER=
  CERT_STORE_META_FINGERPRINT=
  CERT_STORE_META_UPDATED_AT=
  CERT_STORE_META_UPDATED_BY=
  meta=$(cert_store_meta_path "$apex") || return 1
  cert_store_private_file "$meta" || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line && $line == *=* ]] || return 1
    key=${line%%=*}
    value=${line#*=}
    case $key in
      version) version=$value; version_count=$((version_count + 1)) ;;
      domain) domain=$value; domain_count=$((domain_count + 1)) ;;
      alt) alt=$value; alt_count=$((alt_count + 1)) ;;
      owner) owner=$value; owner_count=$((owner_count + 1)) ;;
      issuer) issuer=$value; issuer_count=$((issuer_count + 1)) ;;
      issued_at) issued_at=$value; issued_at_count=$((issued_at_count + 1)) ;;
      not_after) not_after=$value; not_after_count=$((not_after_count + 1)) ;;
      fingerprint) fingerprint=$value; fingerprint_count=$((fingerprint_count + 1)) ;;
      updated_at) updated_at=$value; updated_at_count=$((updated_at_count + 1)) ;;
      updated_by) updated_by=$value; updated_by_count=$((updated_by_count + 1)) ;;
      *) return 1 ;;
    esac
  done < "$meta"
  ((version_count == 1 && domain_count == 1 && alt_count == 1 && owner_count == 1 &&
    issuer_count == 1 && issued_at_count == 1 && not_after_count == 1 &&
    fingerprint_count == 1 && updated_at_count == 1 && updated_by_count == 1)) || return 1
  [[ $version == "$CERT_STORE_VERSION" ]] || return 1
  [[ $domain == "$apex" ]] || return 1
  cert_store_valid_alt "$alt" "$apex" || return 1
  cert_store_valid_owner "$owner" || return 1
  [[ $issuer =~ ^[A-Za-z0-9._-]{1,32}$ ]] || return 1
  [[ $issued_at =~ ^[0-9]{1,12}$ && $not_after =~ ^[0-9]{1,12}$ &&
     $updated_at =~ ^[0-9]{1,12}$ ]] || return 1
  [[ $fingerprint =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ $updated_by == sb || $updated_by == acme-nginx ]] || return 1
  CERT_STORE_META_VERSION=$version
  CERT_STORE_META_DOMAIN=$domain
  CERT_STORE_META_ALT=$alt
  CERT_STORE_META_OWNER=$owner
  CERT_STORE_META_ISSUER=$issuer
  CERT_STORE_META_ISSUED_AT=$issued_at
  CERT_STORE_META_NOT_AFTER=$not_after
  CERT_STORE_META_FINGERPRINT=$fingerprint
  CERT_STORE_META_UPDATED_AT=$updated_at
  CERT_STORE_META_UPDATED_BY=$updated_by
}

cert_store_root_is_valid(){
  cert_store_private_dir "$(cert_store_root)"
}

cert_store_domain_dir_is_valid(){
  local apex=$1 dir current generation
  dir=$(cert_store_domain_dir "$apex") || return 1
  cert_store_private_dir "$dir" || return 1
  [[ -L $dir/current ]] || return 1
  current=$(readlink "$dir/current" 2>/dev/null) || return 1
  [[ $current =~ ^generations/gen\.[A-Za-z0-9]+$ ]] || return 1
  generation="$dir/$current"
  cert_store_private_dir "$generation" || return 1
  cert_store_private_file "$generation/fullchain.pem" || return 1
  cert_store_private_file "$generation/private.key" || return 1
  cert_store_private_file "$dir/meta.env"
}

cert_store_certificate_state(){
  local apex=$1 wildcard=${2-} dir current cert key fingerprint
  # 这两个路径供领养方（shared 模式/测试）读取，因此显式导出而非仅赋值。
  export CERT_STORE_CERT CERT_STORE_KEY
  CERT_STORE_CERT=
  CERT_STORE_KEY=
  cert_store_read_meta "$apex" || return 1
  cert_store_root_is_valid || return 1
  cert_store_domain_dir_is_valid "$apex" || return 1
  [[ ${CERT_STORE_META_DOMAIN,,} == "$apex" ]] || return 1
  [[ ${CERT_STORE_META_ALT,,} == "${wildcard,,}" ]] || return 1
  dir=$(cert_store_domain_dir "$apex") || return 1
  current=$(readlink "$dir/current" 2>/dev/null) || return 1
  cert="$dir/$current/fullchain.pem"
  key="$dir/$current/private.key"
  load_certificate_metadata "$cert" "$key" || return 1
  [[ $CERT_META_STATE == valid ]] || return 1
  certificate_identity_matches "$cert" "$apex" || return 1
  if [[ -n $wildcard ]]; then
    certificate_dns_names "$cert" 2>/dev/null | tr ',' '\n' |
      sed 's/^[[:space:]]*//' | grep -Fxiq -- "$wildcard" || return 1
  fi
  fingerprint=$(sha256sum "$cert" 2>/dev/null | awk '{print $1}') || return 1
  [[ $fingerprint == "${CERT_STORE_META_FINGERPRINT,,}" ]] || return 1
  CERT_STORE_CERT="$dir/current/fullchain.pem"
  CERT_STORE_KEY="$dir/current/private.key"
}

cert_store_can_adopt(){
  cert_store_certificate_state "${1-}" "${2-}" >/dev/null 2>&1
}

cert_store_acquire_lock(){
  local root lock fd
  [[ ${CERT_STORE_LOCK_HELD:-0} -eq 1 ]] && return 0
  root=$(cert_store_root) || return 1
  if [[ -e $root || -L $root ]]; then
    cert_store_private_dir "$root" || return 1
  else
    mkdir "$root" || return 1
    chmod 700 "$root" || return 1
  fi
  lock="$root/.lock"
  if [[ -e $lock || -L $lock ]]; then
    cert_store_private_file "$lock" || return 1
  fi
  exec {fd}> "$lock" || return 1
  if ! chmod 600 "$lock" || ! flock -w 30 "$fd"; then
    exec {fd}>&-
    return 1
  fi
  CERT_STORE_LOCK_FD=$fd
  CERT_STORE_LOCK_HELD=1
}

cert_store_release_lock(){
  local fd=${CERT_STORE_LOCK_FD:-}
  if [[ -z $fd ]]; then
    CERT_STORE_LOCK_HELD=0
    return 0
  fi
  if ! flock -u "$fd"; then
    exec {fd}>&-
    CERT_STORE_LOCK_FD=
    CERT_STORE_LOCK_HELD=0
    return 1
  fi
  exec {fd}>&-
  CERT_STORE_LOCK_FD=
  CERT_STORE_LOCK_HELD=0
}

cert_store_with_lock(){
  local owned=0 status
  if [[ ${CERT_STORE_LOCK_HELD:-0} -ne 1 ]]; then
    cert_store_acquire_lock || {
      echo "sb: 共享证书库锁获取失败" >&2
      return 1
    }
    owned=1
  fi
  if "$@"; then status=0; else status=$?; fi
  if [[ $owned -eq 1 ]] && ! cert_store_release_lock; then
    [[ $status -ne 0 ]] || status=1
  fi
  return "$status"
}

cert_store_publish(){
  local apex=$1 cert=$2 key=$3 alt=${4-} owner=${5:-${CERT_STORE_SELF:-sb}}
  local issuer=${6:-letsencrypt} fingerprint
  [[ $apex == "${apex,,}" ]] || return 1
  valid_hostname "$apex" || return 1
  cert_store_valid_alt "$alt" "$apex" || return 1
  cert_store_valid_owner "$owner" || return 1
  [[ $owner != none ]] || return 1
  [[ $issuer =~ ^[A-Za-z0-9._-]{1,32}$ ]] || return 1
  [[ -f $cert && ! -L $cert && -f $key && ! -L $key ]] || return 1
  load_certificate_metadata "$cert" "$key" || return 1
  [[ $CERT_META_STATE == valid ]] || return 1
  certificate_identity_matches "$cert" "$apex" || return 1
  if [[ -n $alt ]]; then
    certificate_dns_names "$cert" 2>/dev/null | tr ',' '\n' |
      sed 's/^[[:space:]]*//' | grep -Fxiq -- "$alt" || return 1
  fi
  fingerprint=$(sha256sum "$cert" 2>/dev/null | awk '{print $1}') || return 1
  [[ $fingerprint =~ ^[0-9a-f]{64}$ ]] || return 1
  cert_store_with_lock cert_store_publish_locked \
    "$apex" "$cert" "$key" "$alt" "$owner" "$issuer" "$fingerprint"
}

cert_store_publish_locked(){
  local apex=$1 cert=$2 key=$3 alt=$4 owner=$5 issuer=$6 fingerprint=$7
  local root dir generations gen current now meta_tmp generation current_target old_current
  root=$(cert_store_root) || return 1
  dir=$(cert_store_domain_dir "$apex") || return 1
  if [[ -e $root || -L $root ]]; then
    cert_store_private_dir "$root" || return 1
  else
    mkdir "$root" || return 1
    chmod 700 "$root" || return 1
  fi
  if [[ -e $dir || -L $dir ]]; then
    cert_store_private_dir "$dir" || return 1
  else
    mkdir "$dir" || return 1
    chmod 700 "$dir" || return 1
  fi
  generations="$dir/generations"
  if [[ -e $generations || -L $generations ]]; then
    cert_store_private_dir "$generations" || return 1
  else
    mkdir "$generations" || return 1
    chmod 700 "$generations" || return 1
  fi
  gen=$(mktemp -d "$generations/gen.XXXXXX") || return 1
  chmod 700 "$gen" || return 1
  if ! cp -- "$cert" "$gen/fullchain.pem" || ! cp -- "$key" "$gen/private.key" ||
     ! chmod 600 "$gen/fullchain.pem" "$gen/private.key"; then
    rm -rf -- "$gen"
    return 1
  fi
  if ! load_certificate_metadata "$gen/fullchain.pem" "$gen/private.key" ||
     [[ $CERT_META_STATE != valid ]] ||
     ! certificate_identity_matches "$gen/fullchain.pem" "$apex" ||
     [[ $(sha256sum "$gen/fullchain.pem" | awk '{print $1}') != "$fingerprint" ]]; then
    rm -rf -- "$gen"
    return 1
  fi
  old_current=$(readlink "$dir/current" 2>/dev/null || true)
  current=$(mktemp "$dir/.current.XXXXXX") || {
    rm -rf -- "$gen"
    return 1
  }
  rm -f -- "$current" || {
    rm -rf -- "$gen"
    return 1
  }
  if ! ln -s -- "generations/${gen##*/}" "$current" ||
     ! mv -Tf -- "$current" "$dir/current"; then
    rm -f -- "$current"
    rm -rf -- "$gen"
    return 1
  fi
  now=$(date +%s) || {
    rm -rf -- "$gen"
    return 1
  }
  meta_tmp=$(mktemp "$dir/.meta.XXXXXX") || {
    rm -rf -- "$gen"
    return 1
  }
  if ! {
    printf 'version=%s\n' "$CERT_STORE_VERSION"
    printf 'domain=%s\n' "$apex"
    printf 'alt=%s\n' "$alt"
    printf 'owner=%s\n' "$owner"
    printf 'issuer=%s\n' "$issuer"
    printf 'issued_at=%s\n' "$now"
    printf 'not_after=%s\n' "${CERT_META_NOT_AFTER_EPOCH:-0}"
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'updated_at=%s\n' "$now"
    printf 'updated_by=%s\n' "$owner"
  } > "$meta_tmp" || ! chmod 600 "$meta_tmp" ||
     ! mv -Tf -- "$meta_tmp" "$dir/meta.env"; then
    rm -f -- "$meta_tmp"
    if [[ -n $old_current ]]; then
      current=$(mktemp "$dir/.current.XXXXXX") || true
      if [[ -n ${current:-} ]]; then
        rm -f -- "$current"
        ln -s -- "$old_current" "$current" && mv -Tf -- "$current" "$dir/current"
      fi
    else
      rm -f -- "$dir/current"
    fi
    rm -rf -- "$gen"
    return 1
  fi
  current_target=$(readlink "$dir/current" 2>/dev/null || true)
  for generation in "$generations"/gen.*; do
    [[ -e $generation || -L $generation ]] || continue
    [[ $generation == "$dir/$current_target" ]] && continue
    rm -rf -- "$generation" || true
  done
  cert_store_certificate_state "$apex" "$alt"
}

cert_store_set_owner_locked(){
  local apex=$1 owner=$2 dir meta_tmp now updated_by
  cert_store_read_meta "$apex" || return 1
  dir=$(cert_store_domain_dir "$apex") || return 1
  now=$(date +%s) || return 1
  updated_by=$owner
  [[ $owner == none ]] && updated_by=$CERT_STORE_META_UPDATED_BY
  meta_tmp=$(mktemp "$dir/.meta.XXXXXX") || return 1
  if ! {
    printf 'version=%s\n' "$CERT_STORE_META_VERSION"
    printf 'domain=%s\n' "$CERT_STORE_META_DOMAIN"
    printf 'alt=%s\n' "$CERT_STORE_META_ALT"
    printf 'owner=%s\n' "$owner"
    printf 'issuer=%s\n' "$CERT_STORE_META_ISSUER"
    printf 'issued_at=%s\n' "$CERT_STORE_META_ISSUED_AT"
    printf 'not_after=%s\n' "$CERT_STORE_META_NOT_AFTER"
    printf 'fingerprint=%s\n' "$CERT_STORE_META_FINGERPRINT"
    printf 'updated_at=%s\n' "$now"
    printf 'updated_by=%s\n' "$updated_by"
  } > "$meta_tmp" || ! chmod 600 "$meta_tmp" ||
     ! mv -Tf -- "$meta_tmp" "$dir/meta.env"; then
    rm -f -- "$meta_tmp"
    return 1
  fi
  cert_store_read_meta "$apex" >/dev/null
}

cert_store_take_ownership(){
  local apex=$1 owner=$2
  cert_store_valid_owner "$owner" || return 1
  [[ $owner != none ]] || return 1
  cert_store_with_lock cert_store_set_owner_locked "$apex" "$owner"
}

cert_store_owner(){
  cert_store_read_meta "${1-}" >/dev/null || return 1
  printf '%s\n' "$CERT_STORE_META_OWNER"
}

cert_store_list_adoptable(){
  local root dir apex alt
  root=$(cert_store_root) || return 1
  [[ -d $root && ! -L $root ]] || return 1
  for dir in "$root"/*/; do
    [[ -d $dir && ! -L $dir ]] || continue
    dir=${dir%/}
    apex=${dir##*/}
    valid_hostname "$apex" || continue
    cert_store_read_meta "$apex" >/dev/null 2>&1 || continue
    alt=$CERT_STORE_META_ALT
    cert_store_certificate_state "$apex" "$alt" >/dev/null 2>&1 || continue
    printf '%s|%s|%s|%s\n' "$apex" "$alt" "$CERT_STORE_META_OWNER" "$CERT_STORE_META_NOT_AFTER"
  done
}

cert_store_owner_present(){
  case ${1-} in
    sb) [[ -s $ACME_IDENTITY ]] ;;
    acme-nginx) [[ -d /etc/acme-nginx || -x /usr/local/bin/acme-nginx ]] ;;
    *) return 1 ;;
  esac
}

# 卸载/重装时交还续期权，避免留下"名义 owner"。
cert_store_release_ownership(){
  local owner=$1 root dir apex
  cert_store_valid_owner "$owner" || return 1
  [[ $owner != none ]] || return 1
  root=$(cert_store_root) || return 1
  [[ -d $root && ! -L $root ]] || return 0
  for dir in "$root"/*/; do
    [[ -d $dir && ! -L $dir ]] || continue
    dir=${dir%/}
    apex=${dir##*/}
    valid_hostname "$apex" || continue
    cert_store_read_meta "$apex" >/dev/null 2>&1 || continue
    [[ $CERT_STORE_META_OWNER == "$owner" ]] || continue
    cert_store_with_lock cert_store_set_owner_locked "$apex" none >/dev/null 2>&1 || true
  done
}

# 领养时对账：owner 指向 sb 但本机没有签发状态（重装）→ 交还为 none。
cert_store_reconcile_ownership(){
  local apex=$1
  cert_store_read_meta "$apex" >/dev/null 2>&1 || return 0
  [[ $CERT_STORE_META_OWNER == sb ]] || return 0
  [[ -s $ACME_IDENTITY ]] && return 0
  cert_store_with_lock cert_store_set_owner_locked "$apex" none >/dev/null 2>&1 || true
  yellow "共享证书库的续期负责人已失效，已标记为无 owner；请重新签发以接管续期"
}

cert_shared(){
  local apex=$1 wildcard=${2-}
  if ! cert_store_certificate_state "$apex" "$wildcard"; then
    red "共享证书库中没有可用证书：$apex"
    return 1
  fi
  certificatec_hy2=$CERT_STORE_CERT
  certificatep_hy2=$CERT_STORE_KEY
  use_acme_cert=0
  cert_store_reconcile_ownership "$apex" || true
}

config_uses_shared_certificate(){
  local root cert key cert_rest key_rest
  [[ -s $SB_CONFIG ]] || return 1
  root=$(cert_store_root) || return 1
  cert=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") |
    .tls.certificate_path | select(type == "string")' "$SB_CONFIG" 2>/dev/null) || return 1
  key=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") |
    .tls.key_path | select(type == "string")' "$SB_CONFIG" 2>/dev/null) || return 1
  [[ $cert == "$root"/*/current/fullchain.pem &&
     $key == "$root"/*/current/private.key ]] || return 1
  cert_rest=${cert#"$root"/}
  key_rest=${key#"$root"/}
  [[ ${cert_rest%%/*} == "${key_rest%%/*}" ]]
}

shared_certificate_domain(){
  local root cert rest apex
  [[ -s $SB_CONFIG ]] || return 1
  root=$(cert_store_root) || return 1
  cert=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") |
    .tls.certificate_path | select(type == "string")' "$SB_CONFIG" 2>/dev/null) || return 1
  [[ $cert == "$root"/*/current/fullchain.pem ]] || return 1
  rest=${cert#"$root"/}
  apex=${rest%%/*}
  valid_hostname "$apex" || return 1
  printf '%s\n' "$apex"
}

# 检测到本机 nginx 时，自动创建续期后的 reload 钩子（不覆盖自定义钩子；自动创建的钩子会随内容升级重写）。
ensure_nginx_shared_cert_reload_hook(){
  local hook="$SB_DIR/acme_post_reload.sh" tmp
  command -v nginx >/dev/null 2>&1 || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  [[ -d /run/systemd/system ]] || return 0
  systemctl is-active --quiet nginx 2>/dev/null || return 0
  config_uses_acme_certificate || config_uses_shared_certificate || return 0
  tmp=$(mktemp "$SB_DIR/.acme_post_reload.XXXXXX") || return 1
  if ! cat > "$tmp" <<'HOOK'
#!/bin/bash
# shared-cert-store peer hook v2 (auto-created): reload nginx when it uses the shared cert
nginx -T 2>/dev/null | grep -qE '(/etc/cert-store/|/etc/sb/acme-cert\.pem)' || exit 0
nginx -t >/dev/null 2>&1 && systemctl reload nginx
HOOK
  then
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 700 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -e $hook || -L $hook ]]; then
    if [[ ! -f $hook || -L $hook ]]; then
      rm -f "$tmp"
      return 0
    fi
    if grep -Fq -- 'shared-cert-store peer hook' "$hook" 2>/dev/null; then
      if cmp -s -- "$tmp" "$hook"; then
        rm -f "$tmp"
        return 0
      fi
    else
      rm -f "$tmp"
      return 0
    fi
  fi
  if ! mv -fT -- "$tmp" "$hook"; then
    rm -f "$tmp"
    return 1
  fi
}

# acme-nginx 已安装时，自动创建"证书部署后重启 sb"的对端钩子（不覆盖自定义钩子；自动创建的钩子会随内容升级重写）。
ensure_acme_nginx_sb_restart_hook(){
  local hook="/etc/acme-nginx/post_reload.sh" tmp
  [[ -d /etc/acme-nginx && ! -L /etc/acme-nginx ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  [[ -d /run/systemd/system ]] || return 0
  systemctl cat sb >/dev/null 2>&1 || return 0
  tmp=$(mktemp "/etc/acme-nginx/.post_reload.XXXXXX") || return 1
  if ! cat > "$tmp" <<'HOOK'
#!/bin/bash
# shared-cert-store peer hook v2 (auto-created): restart sb when it uses the shared cert
cfg=/etc/sb/sb.json
command -v jq >/dev/null 2>&1 || exit 0
[[ -r $cfg ]] || exit 0
cert=$(jq -r '[.inbounds[] | select(.type=="hysteria2") | .tls.certificate_path] | first // empty' "$cfg" 2>/dev/null) || exit 0
case $cert in /etc/cert-store/*) systemctl restart sb ;; esac
HOOK
  then
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 700 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -e $hook || -L $hook ]]; then
    if [[ ! -f $hook || -L $hook ]]; then
      rm -f "$tmp"
      return 0
    fi
    if grep -Fq -- 'shared-cert-store peer hook' "$hook" 2>/dev/null; then
      if cmp -s -- "$tmp" "$hook"; then
        rm -f "$tmp"
        return 0
      fi
    else
      rm -f "$tmp"
      return 0
    fi
  fi
  if ! mv -fT -- "$tmp" "$hook"; then
    rm -f "$tmp"
    return 1
  fi
}

# 干净机器检测到对端消费者工具时，自动创建共享库并发布当前 ACME 证书（不重新签发）。
ensure_shared_cert_store_published(){
  local root identity cert key alt
  root=$(cert_store_root) || return 0
  [[ -d $root && ! -L $root ]] && return 0
  config_uses_acme_certificate || return 0
  identity=$(read_acme_identity 2>/dev/null) || return 0
  load_certificate_metadata "$ACME_CERT" "$ACME_KEY" 2>/dev/null || return 0
  [[ $CERT_META_STATE == valid ]] || return 0
  cert=$ACME_CERT
  key=$ACME_KEY
  [[ -L $cert ]] && cert=$(readlink -f -- "$cert")
  [[ -L $key ]] && key=$(readlink -f -- "$key")
  alt=
  if certificate_dns_names "$ACME_CERT" 2>/dev/null | tr ',' '\n' |
       sed 's/^[[:space:]]*//' | grep -Fxiq -- "*.$identity"; then
    alt="*.$identity"
  fi
  cert_store_publish "$identity" "$cert" "$key" "$alt" sb letsencrypt >/dev/null 2>&1 || return 0
  yellow "检测到对端证书消费者，已自动创建共享证书库并发布当前证书（owner: sb）"
}

shared_certificate_is_valid(){
  local apex wildcard
  config_uses_shared_certificate || return 1
  apex=$(shared_certificate_domain 2>/dev/null) || return 1
  cert_store_read_meta "$apex" >/dev/null 2>&1 || return 1
  wildcard=$CERT_STORE_META_ALT
  cert_store_certificate_state "$apex" "$wildcard" >/dev/null 2>&1 || return 1
  [[ $CERT_STORE_CERT == "$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.certificate_path' "$SB_CONFIG" 2>/dev/null)" ]]
}

choose_shared_certificate(){
  local entry apex alt owner not_after choice index=0
  local -a entries=()
  mapfile -t entries < <(cert_store_list_adoptable 2>/dev/null)
  if [[ ${#entries[@]} -eq 0 ]]; then
    red "共享证书库中没有可用证书"
    return 1
  fi
  green "共享证书库中的可用证书："
  for entry in "${entries[@]}"; do
    index=$((index + 1))
    IFS='|' read -r apex alt owner not_after <<< "$entry"
    printf '  %s：%s%s（owner: %s，到期: %s）\n' "$index" "$apex" \
      "${alt:+ + $alt}" "${owner:-未知}" "$(format_epoch_utc "$not_after" 2>/dev/null || echo 未知)"
  done
  readp "请选择要使用的证书【1-${#entries[@]}】（回车取消）：" choice || return 3
  [[ -n $choice ]] || return 3
  if [[ ! $choice =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#entries[@]})); then
    red "输入无效"
    return 1
  fi
  entry=${entries[$((choice - 1))]}
  IFS='|' read -r apex alt owner not_after <<< "$entry"
  cert_shared "$apex" "$alt" || return 1
  green "已选择共享证书：$apex${alt:+ + $alt}（owner: ${owner:-未知}）"
}

publish_acme_certificate_to_store(){
  local identity alt='' wildcard
  if ! config_uses_acme_certificate; then
    red "当前未使用 sb 自己签发的 ACME 证书"
    return 1
  fi
  identity=$(read_acme_identity 2>/dev/null) || {
    red "无法读取 ACME 身份文件"
    return 1
  }
  if ! load_certificate_metadata "$ACME_CERT" "$ACME_KEY" || [[ $CERT_META_STATE != valid ]]; then
    red "当前 ACME 证书无效"
    return 1
  fi
  wildcard="*.$identity"
  if certificate_dns_names "$ACME_CERT" 2>/dev/null | tr ',' '\n' |
       sed 's/^[[:space:]]*//' | grep -Fxiq -- "$wildcard"; then
    alt=$wildcard
  fi
  local cert_path=$ACME_CERT key_path=$ACME_KEY
  if [[ -L $cert_path ]]; then
    cert_path=$(readlink -f -- "$cert_path") || return 1
  fi
  if [[ -L $key_path ]]; then
    key_path=$(readlink -f -- "$key_path") || return 1
  fi
  if ! cert_store_publish "$identity" "$cert_path" "$key_path" "$alt" sb letsencrypt; then
    red "发布到共享证书库失败"
    return 1
  fi
  green "当前 ACME 证书已发布到共享证书库（owner: sb）"
}

install_official_acme(){
  local temp_dir archive source_dir actual_sha256 installed_version provider plugin
  provider=${1:-cloudflare}
  valid_dns_provider "$provider" || return 1
  plugin=$(dns_provider_plugin_file "$provider") || return 1
  if [[ -x $ACME_BIN ]]; then
    installed_version=$(HOME="$SB_DIR" "$ACME_BIN" --version 2>/dev/null)
    if printf '%s\n' "$installed_version" | grep -Fxq "v$ACME_VERSION"; then
      if [[ $provider == huaweicloud ]]; then
        if write_huawei_aksk_plugin; then
          return 0
        fi
      elif [[ -f $ACME_HOME/dnsapi/$plugin ]]; then
        return 0
      fi
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
     { [[ $provider != huaweicloud ]] && [[ ! -f $source_dir/dnsapi/$plugin ]]; } || \
     ! (cd "$source_dir" && HOME="$SB_DIR" bash ./acme.sh --install \
       --home "$ACME_HOME" --config-home "$ACME_HOME" --cert-home "$ACME_HOME/certs" \
       --no-cron --no-profile); then
    rm -rf "$temp_dir"
    red "官方 acme.sh 安装失败"
    return 1
  fi
  rm -rf "$temp_dir"
  installed_version=$(HOME="$SB_DIR" "$ACME_BIN" --version 2>/dev/null)
  if [[ ! -x $ACME_BIN ]] || \
     { [[ $provider != huaweicloud ]] && [[ ! -f $ACME_HOME/dnsapi/$plugin ]]; } || \
     ! printf '%s\n' "$installed_version" | grep -Fxq "v$ACME_VERSION"; then
    red "官方 acme.sh 安装不完整"
    return 1
  fi
  chmod 700 "$ACME_HOME" "$ACME_BIN"
  if [[ $provider == huaweicloud ]]; then
    write_huawei_aksk_plugin || return 1
  fi
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
# shellcheck disable=SC2317,SC2329
# sb-acme-reload-v3
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
post_reload="/etc/sb/acme_post_reload.sh"
store_root="/etc/cert-store"

cleanup_deploy_files(){
  [[ -z $stage_cert ]] || rm -f -- "$stage_cert"
  [[ -z $stage_key ]] || rm -f -- "$stage_key"
}

# 证书成功切换后执行可选的第二个消费者钩子（例如 reload nginx）。
# 只接受 root 所有、非符号链接、可执行、组/他人不可写的常规文件；失败只告警。
warn_post_reload(){
  echo "sb: $1" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t sb "acme post-reload: $1" 2>/dev/null || true
  fi
}

run_post_reload_hook(){
  local owner mode
  [[ -e $post_reload || -L $post_reload ]] || return 0
  if [[ ! -f $post_reload || -L $post_reload || ! -x $post_reload ]]; then
    warn_post_reload "ignoring untrusted post-reload hook: $post_reload"
    return 0
  fi
  owner=$(stat -c '%u' "$post_reload" 2>/dev/null) || return 0
  mode=$(stat -c '%a' "$post_reload" 2>/dev/null) || return 0
  if [[ $owner != "$(id -u)" ]] || (( (8#$mode & 0022) != 0 )); then
    warn_post_reload "ignoring untrusted post-reload hook: $post_reload"
    return 0
  fi
  if ! "$post_reload"; then
    warn_post_reload "post-reload hook failed: $post_reload"
  fi
  return 0
}

# 证书成功切换后把当前证书发布到共享证书库（/etc/cert-store）。
# 仅当库已存在且该域名的 owner 为 sb/none/空时发布；失败只告警，不影响部署结果。
store_publish(){
  local identity=$1 store_dir generations gen current meta_tmp fingerprint not_after owner
  local now alt old_current generation current_target enddate not_after_epoch
  [[ -d $store_root && ! -L $store_root ]] || return 0
  [[ $identity =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || return 0
  store_dir="$store_root/$identity"
  if [[ -f $store_dir/meta.env && ! -L $store_dir/meta.env ]]; then
    owner=$(sed -n 's/^owner=//p' "$store_dir/meta.env" 2>/dev/null | head -n 1)
    case $owner in
      sb|none|'') ;;
      *) return 0 ;;
    esac
  fi
  (
    set -u
    umask 077
    exec 7> "$store_root/.lock" || exit 1
    chmod 600 "$store_root/.lock" || exit 1
    flock -w 30 7 || exit 1
    if [[ -e $store_dir || -L $store_dir ]]; then
      [[ -d $store_dir && ! -L $store_dir ]] || exit 1
    else
      mkdir "$store_dir" || exit 1
      chmod 700 "$store_dir" || exit 1
    fi
    generations="$store_dir/generations"
    if [[ -e $generations || -L $generations ]]; then
      [[ -d $generations && ! -L $generations ]] || exit 1
    else
      mkdir "$generations" || exit 1
      chmod 700 "$generations" || exit 1
    fi
    gen=$(mktemp -d "$generations/gen.XXXXXX") || exit 1
    chmod 700 "$gen" || exit 1
    cp -- "$cert" "$gen/fullchain.pem" || exit 1
    cp -- "$key" "$gen/private.key" || exit 1
    chmod 600 "$gen/fullchain.pem" "$gen/private.key" || exit 1
    openssl x509 -in "$gen/fullchain.pem" -noout >/dev/null 2>&1 || exit 1
    openssl pkey -in "$gen/private.key" -pubout >/dev/null 2>&1 || exit 1
    fingerprint=$(sha256sum "$gen/fullchain.pem" | awk '{print $1}') || exit 1
    [[ $fingerprint =~ ^[0-9a-f]{64}$ ]] || exit 1
    not_after=0
    if enddate=$(openssl x509 -in "$gen/fullchain.pem" -noout -enddate 2>/dev/null); then
      not_after_epoch=$(date -d "${enddate#notAfter=}" +%s 2>/dev/null) && not_after=$not_after_epoch
    fi
    alt=
    if openssl x509 -in "$gen/fullchain.pem" -noout -text 2>/dev/null |
         grep -qE "DNS:\*\.$identity([,[:space:]]|$)"; then
      alt="*.$identity"
    fi
    old_current=$(readlink "$store_dir/current" 2>/dev/null || true)
    current=$(mktemp "$store_dir/.current.XXXXXX") || exit 1
    rm -f -- "$current" || exit 1
    ln -s -- "generations/${gen##*/}" "$current" || exit 1
    mv -Tf -- "$current" "$store_dir/current" || exit 1
    now=$(date +%s) || exit 1
    meta_tmp=$(mktemp "$store_dir/.meta.XXXXXX") || exit 1
    if ! printf '%s\n' \
      "version=1" \
      "domain=$identity" \
      "alt=$alt" \
      "owner=sb" \
      "issuer=letsencrypt" \
      "issued_at=$now" \
      "not_after=$not_after" \
      "fingerprint=$fingerprint" \
      "updated_at=$now" \
      "updated_by=sb" > "$meta_tmp" ||
       ! chmod 600 "$meta_tmp" ||
       ! mv -Tf -- "$meta_tmp" "$store_dir/meta.env"; then
      rm -f -- "$meta_tmp"
      if [[ -n $old_current ]]; then
        current=$(mktemp "$store_dir/.current.XXXXXX") || exit 1
        rm -f -- "$current"
        ln -s -- "$old_current" "$current" && mv -Tf -- "$current" "$store_dir/current"
      else
        rm -f -- "$store_dir/current"
      fi
      rm -rf -- "$gen"
      exit 1
    fi
    current_target=$(readlink "$store_dir/current" 2>/dev/null || true)
    for generation in "$generations"/gen.*; do
      [[ -e $generation || -L $generation ]] || continue
      [[ $generation == "$store_dir/$current_target" ]] && continue
      rm -rf -- "$generation" || true
    done
    exit 0
  ) || warn_post_reload "shared certificate store publish failed: $identity"
  return 0
}

finalize_deployment(){
  store_publish "$identity" || true
  run_post_reload_hook
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
    finalize_deployment
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
  finalize_deployment
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
  fragment=$(systemctl show sb.service -p FragmentPath --value 2>/dev/null || true)
  [[ -z $fragment || $fragment == "$systemd_unit" ]] || { rollback_deployment || true; exit 1; }
  # Allow systemd drop-ins (systemctl edit sb) — ownership of the main unit still
  # guarantees this is the managed service; drop-ins only extend it.
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
  finalize_deployment
  exit 0
fi
if ! managed_service_active; then
  commit_deployment
  finalize_deployment
  exit 0
fi
if restart_managed_service && sleep 1 && managed_service_active; then
  commit_deployment
  finalize_deployment
  exit 0
fi
if rollback_deployment; then
  restart_managed_service >/dev/null 2>&1 || true
  sleep 1
  if ! managed_service_active >/dev/null 2>&1; then
    echo "sb: certificate rollback finished but the service is not running" >&2
  fi
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
  # shellcheck disable=SC2016
  [[ -f $ACME_RELOAD && ! -L $ACME_RELOAD && -x $ACME_RELOAD ]] &&
    [[ $(grep -Fxc "$ACME_RELOAD_IDENTITY" "$ACME_RELOAD" 2>/dev/null || true) -eq 1 ]] &&
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
    ' "$ACME_RELOAD" &&
    grep -Fqx 'post_reload="/etc/sb/acme_post_reload.sh"' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'store_root="/etc/cert-store"' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'run_post_reload_hook(){' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'store_publish(){' "$ACME_RELOAD" 2>/dev/null &&
    grep -Fqx 'finalize_deployment(){' "$ACME_RELOAD" 2>/dev/null &&
    [[ $(grep -Fxc '  finalize_deployment' "$ACME_RELOAD" 2>/dev/null || true) -eq 4 ]] &&
    grep -Fqx '    finalize_deployment' "$ACME_RELOAD" 2>/dev/null &&
    [[ $(grep -Fxc '  run_post_reload_hook' "$ACME_RELOAD" 2>/dev/null || true) -eq 1 ]] &&
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
  local identity provider plugin
  provider=$(acme_dns_provider_detected 2>/dev/null) || return 1
  plugin=$(dns_provider_plugin_file "$provider") || return 1
  [[ -x $ACME_BIN && -f $ACME_HOME/dnsapi/$plugin && ! -L $ACME_HOME/dnsapi/$plugin ]] ||
    return 1
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
  local staged_fingerprint deployed_fingerprint
  managed_acme_live_layout_is_valid &&
    acme_deployment_config_is_current "$identity" || return 1
  # 只有"当前生效的证书就是这次安装进暂存区的那份"才算部署成功：hook 失败会回滚到
  # 旧 generation，旧证书本身仍然有效，只校验它会把回滚误判成成功。
  staged_fingerprint=$(certificate_file_fingerprint "$ACME_STAGE_CERT") || return 1
  deployed_fingerprint=$(certificate_file_fingerprint "$ACME_CERT") || return 1
  [[ $staged_fingerprint == "$deployed_fingerprint" ]] || return 1
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
    acme_credentials_present &&
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
  ACME_INFLIGHT_BACKUP=$backup
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
  local current force=${1:-0}
  if [[ $force != 1 ]] && config_references_acme_state; then
    red "当前服务正在使用 ACME 证书，请先切换为自签证书"
    return 1
  fi
  if [[ $force == 1 && -z ${ACME_STATE_BACKUP:-} ]]; then
    red "未找到 ACME 状态备份，拒绝强制清理正在使用的证书"
    return 1
  fi
  load_current_crontab || return 1
  current=$CURRENT_CRONTAB
  if crontab_has_acme_entries "$current"; then
    remove_acme_renew_cron || return 1
  fi
  discard_acme_state
}

# 凭据通过 bash 动态作用域写回调用方声明的局部变量：助手自己不能再声明同名 local，
# 否则读到的值会落在助手自己的局部变量上、调用方拿不到。
prompt_cloudflare_acme_credentials(){
  while true; do
    readp "请输入 Cloudflare Account ID：" account_id || return 3
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
  readp "请输入 Cloudflare API Token：" cf_token || return 3
  if [[ -z $cf_token ]]; then
    red "API Token 不能为空"
    return 1
  fi
}

prompt_huaweicloud_region(){
  local region_choice
  while true; do
    green "请选择华为云 Region（决定 DNS API 域名 dns.<region>.myhuaweicloud.com）"
    green "1：北京 cn-north-4（默认）"
    green "2：上海 cn-east-3"
    green "3：广州 cn-south-1"
    green "4：香港 ap-southeast-1"
    green "5：手动输入 Region ID"
    readp "请选择【1-5】（回车默认 1）：" region_choice || return 3
    case $region_choice in
      ""|1) hw_region=cn-north-4; return 0 ;;
      2) hw_region=cn-east-3; return 0 ;;
      3) hw_region=cn-south-1; return 0 ;;
      4) hw_region=ap-southeast-1; return 0 ;;
      5)
        while true; do
          readp "请输入华为云 Region ID（如 cn-north-4）：" hw_region || return 3
          hw_region=$(printf '%s' "$hw_region" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
          if valid_huaweicloud_region "$hw_region"; then
            return 0
          fi
          red "Region 格式错误：应为 2-32 位字母、数字、下划线或连字符（如 cn-north-4）"
        done
        ;;
      *) red "请输入1、2、3、4或5" ;;
    esac
  done
}

prompt_huaweicloud_acme_credentials(){
  yellow "华为云 AK/SK 在控制台「我的凭证」→「访问密钥」创建，建议使用仅授 DNS 云解析权限的子账号"
  yellow "Region 决定 DNS API 域名 dns.<region>.myhuaweicloud.com"
  yellow "AK/SK 将由 acme.sh 保存在仅 root 可读的 $ACME_HOME 配置中，用于自动续期"
  while true; do
    readp "请输入华为云 Access Key ID：" hw_access_key || return 3
    hw_access_key=$(printf '%s' "$hw_access_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if valid_huaweicloud_access_key_id "$hw_access_key"; then
      break
    fi
    red "Access Key ID 格式错误：应为 16-64 位字母、数字、下划线或连字符"
  done
  while true; do
    readp "请输入华为云 Secret Access Key：" hw_secret_key || return 3
    hw_secret_key=$(printf '%s' "$hw_secret_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if valid_huaweicloud_secret_access_key "$hw_secret_key"; then
      break
    fi
    red "Secret Access Key 格式错误：应为 16-128 位字母、数字、+、/、=、_ 或连字符"
  done
  prompt_huaweicloud_region || return $?
}

issue_acme_certificate(){
  local domain_input provider choice label plugin account_id cf_token
  local hw_access_key hw_secret_key hw_region backup_path
  local initial_install=${1:-0} retain_backup=${2:-0} reuse_backup=${3:-0}
  local -a issue_args
  [[ $initial_install == 0 || $initial_install == 1 ]] || return 1
  [[ $retain_backup == 0 || $retain_backup == 1 ]] || return 1
  [[ $reuse_backup == 0 || $reuse_backup == 1 ]] || return 1
  while true; do
    readp "请输入域名（example.com 默认同时申请 example.com + *.example.com；泛域名请写成 *.example.com）：" domain_input || return 3
    if normalize_acme_domain "$domain_input"; then
      break
    fi
    red "域名格式错误，请输入 example.com、sub.example.com 或 *.example.com"
  done
  # 默认双域名：输入主域名时也同时申请泛域名，可用 n 显式只申请单域名。
  if [[ -n ${ACME_PRIMARY_DOMAIN:-} && -z ${ACME_WILDCARD_DOMAIN:-} ]]; then
    while true; do
      readp "是否同时申请泛域名 *.${ACME_PRIMARY_DOMAIN}（回车默认是，输入 n 仅单域名）：" choice || return 3
      case $choice in
        ""|y|Y|yes|是) ACME_WILDCARD_DOMAIN="*.${ACME_PRIMARY_DOMAIN}"; break ;;
        n|N|no|否) break ;;
        *) red "请输入回车或 n" ;;
      esac
    done
  fi
  while true; do
    readp "请选择 DNS 供应商（1：Cloudflare 2：华为云，回车默认 Cloudflare）：" choice || return 3
    case $choice in
      ""|1) provider=cloudflare; break ;;
      2) provider=huaweicloud; break ;;
      *) red "请输入1或2" ;;
    esac
  done
  label=$(dns_provider_label "$provider") || return 1
  plugin=$(dns_provider_plugin_file "$provider") || return 1
  if [[ $provider == huaweicloud ]]; then
    prompt_huaweicloud_acme_credentials || return $?
  else
    prompt_cloudflare_acme_credentials || return $?
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
  if [[ $reuse_backup == 1 ]]; then
    if ! reset_acme_state 1; then
      restore_acme_state_backup || red "恢复 ACME 状态失败，请立即检查 $SB_DIR"
      return 1
    fi
  else
    if ! reset_acme_state; then
      restore_acme_state_backup || red "恢复 ACME 状态失败，请立即检查 $SB_DIR"
      return 1
    fi
  fi
  if ! install_official_acme "$provider"; then
    cf_token='' hw_access_key='' hw_secret_key='' hw_region=''
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  fi
  if ! write_acme_reload_hook; then
    cf_token='' hw_access_key='' hw_secret_key='' hw_region=''
    discard_acme_state
    restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
    return 1
  fi
  issue_args=(--home "$ACME_HOME" --config-home "$ACME_HOME" --issue --server letsencrypt \
    --dns "${plugin%.sh}" --keylength ec-256 -d "$ACME_PRIMARY_DOMAIN")
  if [[ -n $ACME_WILDCARD_DOMAIN ]]; then
    issue_args+=(-d "$ACME_WILDCARD_DOMAIN")
    blue "将申请：$ACME_PRIMARY_DOMAIN + $ACME_WILDCARD_DOMAIN"
  else
    blue "将申请单域名证书：$ACME_PRIMARY_DOMAIN"
  fi
  if [[ $provider == huaweicloud ]]; then
    if ! HOME="$SB_DIR" HUAWEICLOUD_ACCESS_KEY_ID="$hw_access_key" \
        HUAWEICLOUD_SECRET_ACCESS_KEY="$hw_secret_key" HUAWEICLOUD_REGION="$hw_region" \
        "$ACME_BIN" "${issue_args[@]}"; then
      cf_token='' hw_access_key='' hw_secret_key='' hw_region=''
      discard_acme_state
      restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
      red "${label} DNS 验证或证书签发失败"
      return 1
    fi
  else
    if ! HOME="$SB_DIR" CF_Token="$cf_token" CF_Account_ID="$account_id" \
        CF_Zone_ID='' CF_Key='' CF_Email='' \
        "$ACME_BIN" "${issue_args[@]}"; then
      cf_token='' hw_access_key='' hw_secret_key='' hw_region=''
      discard_acme_state
      restore_acme_state_backup || red "恢复旧 ACME 状态失败，请立即检查 $SB_DIR"
      red "${label} DNS 验证或证书签发失败"
      return 1
    fi
  fi
  cf_token='' hw_access_key='' hw_secret_key='' hw_region=''
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
  green "${label} DNS API 证书申请完成"
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
  local menu acme_name max adoptable_count
  local auto_apex auto_alt auto_owner
  local -a adoptable_entries=()
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
  mapfile -t adoptable_entries < <(cert_store_list_adoptable 2>/dev/null)
  adoptable_count=${#adoptable_entries[@]}
  # 共享证书库只有一张可用证书时直接领养（零手工步骤），多张时进入下方菜单选择。
  if ((adoptable_count == 1)); then
    IFS="|" read -r auto_apex auto_alt auto_owner <<< "${adoptable_entries[0]}"
    if cert_shared "$auto_apex" "$auto_alt"; then
      green "检测到共享证书库证书，已自动领养：$auto_apex${auto_alt:+ + $auto_alt}（owner: ${auto_owner:-未知}）"
      return 0
    fi
  fi
  if acme_name=$(detect_acme_identity); then
    yellow "检测到可用的 ACME 域名证书：$acme_name"
    green "请选择 Hysteria2 证书模式"
    yellow "1：否！使用自签的证书 (回车默认)"
    yellow "2：使用已有的 $acme_name 域名证书"
    yellow "3：通过 DNS API 重新申请（Cloudflare / 华为云）"
    yellow "   重新申请会删除本脚本现有的 ACME 证书与续期配置"
    max=3
    if ((adoptable_count > 0)); then
      yellow "4：使用共享证书库中的证书（领养，不再申请）"
      max=4
    fi
    while true; do
      readp "请选择【1-${max}】：" menu || return 1
      if [[ $menu =~ ^[0-9]+$ ]] && ((menu > max)); then
        red "请输入1-${max}"
        continue
      fi
      case "$menu" in
        ""|1) cert_self_signed; break ;;
        2)
          if cert_acme; then
            break
          fi
          ;;
        3)
          if issue_acme_certificate 1; then break; fi
          yellow "继续使用自签证书"
          cert_self_signed
          break
          ;;
        4)
          if choose_shared_certificate; then break; fi
          ;;
        *) red "请输入1-${max}" ;;
      esac
    done
  else
    green "请选择 Hysteria2 证书模式"
    yellow "1：使用自签证书 (回车默认)"
    yellow "2：使用官方 acme.sh + DNS API 申请域名证书（Cloudflare / 华为云）"
    max=2
    if ((adoptable_count > 0)); then
      yellow "3：使用共享证书库中的证书（领养，不再申请）"
      max=3
    fi
    while true; do
      readp "请选择【1-${max}】：" menu || return 1
      if [[ $menu =~ ^[0-9]+$ ]] && ((menu > max)); then
        red "请输入1-${max}"
        continue
      fi
      case "$menu" in
        ""|1) cert_self_signed; break ;;
        2)
          if issue_acme_certificate 1; then break; fi
          yellow "证书申请失败，继续使用自签证书"
          cert_self_signed
          break
          ;;
        3)
          if choose_shared_certificate; then break; fi
          ;;
        *) red "请输入1-${max}" ;;
      esac
    done
  fi
}
