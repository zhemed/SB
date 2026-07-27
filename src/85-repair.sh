# sb-module: 85-repair
# Diagnose and repair an owned sb installation without deleting node data.
load_repair_config_values(){
  local source=$1 hy2_uuid
  REPAIR_UUID=
  REPAIR_VLESS_PORT=
  REPAIR_SOCKS_PORT=
  REPAIR_HY2_PORT=
  REPAIR_SNI=
  REPAIR_PRIVATE_KEY=
  REPAIR_SHORT_ID=
  REPAIR_SOCKS_PASSWORD=
  REPAIR_STRATEGY=
  REPAIR_CERT_PATH=
  REPAIR_KEY_PATH=
  REPAIR_CERT_MODE=
  [[ -s $source ]] && managed_regular_file_is_trusted "$source" || return 1
  jq -e '
    type == "object" and (.inbounds | type == "array") and
    ([.inbounds[] | select(.type == "vless" and .tag == "vless-sb")] | length) == 1 and
    ([.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb")] | length) == 1 and
    ([.inbounds[] | select(.type == "socks" and .tag == "socks5-sb")] | length) == 1 and
    ([.outbounds[] | select(.type == "direct" and .tag == "direct")] | length) == 1
  ' "$source" >/dev/null 2>&1 || return 1
  REPAIR_UUID=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .users[0].uuid | select(type == "string")' "$source") || return 1
  hy2_uuid=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .users[0].password | select(type == "string")' "$source") || return 1
  REPAIR_VLESS_PORT=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .listen_port | select(type == "number")' "$source") || return 1
  REPAIR_SOCKS_PORT=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | .listen_port | select(type == "number")' "$source") || return 1
  REPAIR_HY2_PORT=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .listen_port | select(type == "number")' "$source") || return 1
  REPAIR_SNI=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.server_name | select(type == "string")' "$source") || return 1
  REPAIR_PRIVATE_KEY=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.reality.private_key | select(type == "string")' "$source") || return 1
  REPAIR_SHORT_ID=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.reality.short_id[0] | select(type == "string")' "$source") || return 1
  REPAIR_SOCKS_PASSWORD=$(jq -er '.inbounds[] | select(.type == "socks" and .tag == "socks5-sb") | select(.users[0].username == "sb") | .users[0].password | select(type == "string")' "$source") || return 1
  REPAIR_STRATEGY=$(jq -er '.outbounds[] | select(.type == "direct" and .tag == "direct") | .domain_strategy | select(type == "string")' "$source") || return 1
  REPAIR_CERT_PATH=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.certificate_path | select(type == "string")' "$source") || return 1
  REPAIR_KEY_PATH=$(jq -er '.inbounds[] | select(.type == "hysteria2" and .tag == "hy2-sb") | .tls.key_path | select(type == "string")' "$source") || return 1
  valid_uuid "$REPAIR_UUID" && [[ $hy2_uuid == "$REPAIR_UUID" ]] || return 1
  valid_port "$REPAIR_VLESS_PORT" && valid_port "$REPAIR_SOCKS_PORT" &&
    valid_port "$REPAIR_HY2_PORT" || return 1
  [[ $REPAIR_VLESS_PORT != "$REPAIR_SOCKS_PORT" ]] || return 1
  valid_hostname "$REPAIR_SNI" || return 1
  valid_reality_key "$REPAIR_PRIVATE_KEY" || return 1
  valid_short_id "$REPAIR_SHORT_ID" || return 1
  valid_socks_password "$REPAIR_SOCKS_PASSWORD" || return 1
  [[ $REPAIR_STRATEGY =~ ^(prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only)$ ]] || return 1
  if [[ $REPAIR_CERT_PATH == "$SB_DIR/cert.pem" && $REPAIR_KEY_PATH == "$SB_DIR/private.key" ]]; then
    REPAIR_CERT_MODE=self_signed
  elif [[ $REPAIR_CERT_PATH == "$ACME_CERT" && $REPAIR_KEY_PATH == "$ACME_KEY" ]]; then
    REPAIR_CERT_MODE=acme
  else
    return 1
  fi
}

render_repair_config(){
  local output=$1
  local uuid=$REPAIR_UUID port_vl_re=$REPAIR_VLESS_PORT port_socks5=$REPAIR_SOCKS_PORT
  # render_server_config consumes these locals through Bash dynamic scope.
  # shellcheck disable=SC2034
  local port_hy2=$REPAIR_HY2_PORT ym_vl_re=$REPAIR_SNI private_key=$REPAIR_PRIVATE_KEY
  local short_id=$REPAIR_SHORT_ID socks_password=$REPAIR_SOCKS_PASSWORD ipv=$REPAIR_STRATEGY
  # shellcheck disable=SC2034
  local certificatec_hy2=$REPAIR_CERT_PATH certificatep_hy2=$REPAIR_KEY_PATH
  render_server_config "$output"
}

managed_tree_is_trusted(){
  local root=$1 path
  [[ -d $root && ! -L $root ]] && managed_path_is_trusted "$root" || return 1
  (
    shopt -s dotglob nullglob globstar
    for path in "$root"/**; do
      [[ ! -L $path ]] || exit 1
      managed_path_is_trusted "$path" || exit 1
    done
  )
}

active_acme_pair_is_trusted(){
  if [[ -L $ACME_CERT || -L $ACME_KEY ]]; then
    managed_symlink_is_trusted "$ACME_CERT" && managed_symlink_is_trusted "$ACME_KEY" &&
      managed_acme_live_layout_is_valid
  else
    managed_regular_file_is_trusted "$ACME_CERT" &&
      managed_regular_file_is_trusted "$ACME_KEY"
  fi
}

acme_maintenance_components_are_trusted(){
  local identity=$1 conf
  valid_hostname "$identity" || return 1
  conf=$(acme_domain_conf_path "$identity") || return 1
  managed_tree_is_trusted "$ACME_HOME" &&
    managed_regular_file_is_trusted "$ACME_BIN" &&
    managed_regular_file_is_trusted "$ACME_HOME/dnsapi/dns_cf.sh" &&
    managed_regular_file_is_trusted "$ACME_HOME/account.conf" &&
    managed_regular_file_is_trusted "$conf"
}

repair_acme_certificate_from_storage(){
  local identity stored_cert stored_key
  REPAIR_ACME_MAINTENANCE_OK=1
  if identity=$(detect_acme_identity 2>/dev/null) && active_acme_pair_is_trusted; then
    if ! acme_maintenance_components_are_trusted "$identity" ||
       ! write_acme_reload_hook ||
       { { ! managed_acme_live_layout_is_valid ||
           ! acme_deployment_config_is_current "$identity"; } &&
         ! register_acme_certificate_deployment "$identity" 0; }; then
      REPAIR_ACME_MAINTENANCE_OK=0
      yellow "ACME证书本身有效，续期或原子部署组件暂未修复；本次继续使用现有证书"
    fi
    return 0
  fi
  identity=$(read_acme_identity 2>/dev/null) || return 1
  acme_maintenance_components_are_trusted "$identity" || return 1
  load_acme_certificate_schedule "$identity" || return 1
  stored_cert="$ACME_HOME/certs/${identity}_ecc/fullchain.cer"
  stored_key="$ACME_HOME/certs/${identity}_ecc/${identity}.key"
  managed_regular_file_is_trusted "$stored_cert" &&
    managed_regular_file_is_trusted "$stored_key" || return 1
  load_certificate_metadata "$stored_cert" "$stored_key" || return 1
  [[ $CERT_META_STATE == valid ]] || return 1
  certificate_identity_matches "$stored_cert" "$identity" || return 1
  write_acme_reload_hook || return 1
  register_acme_certificate_deployment "$identity" 0
}

ensure_repair_certificate(){
  REPAIR_CERT_FELL_BACK=0
  case $REPAIR_CERT_MODE in
    self_signed)
      if managed_regular_file_is_trusted "$SB_DIR/cert.pem" &&
         managed_regular_file_is_trusted "$SB_DIR/private.key" &&
         self_signed_certificate_is_valid; then
        REPAIR_CERT_ACTION="自签证书正常"
      elif generate_self_signed_certificate; then
        REPAIR_CERT_ACTION="已重建自签证书"
      else
        return 1
      fi
      ;;
    acme)
      if repair_acme_certificate_from_storage; then
        if [[ $REPAIR_ACME_MAINTENANCE_OK -eq 1 ]]; then
          REPAIR_CERT_ACTION="ACME证书正常或已从签发记录恢复"
        else
          REPAIR_CERT_ACTION="ACME证书有效；续期维护组件待修复"
        fi
      else
        yellow "ACME证书暂时无法恢复，正在切换到有效自签证书以恢复服务"
        if ! self_signed_certificate_is_valid && ! generate_self_signed_certificate; then
          return 1
        fi
        REPAIR_CERT_PATH="$SB_DIR/cert.pem"
        REPAIR_KEY_PATH="$SB_DIR/private.key"
        REPAIR_CERT_MODE=self_signed
        REPAIR_CERT_FELL_BACK=1
        REPAIR_CERT_ACTION="ACME未删除；服务已临时切换为自签证书"
      fi
      ;;
    *) return 1 ;;
  esac
}

preserve_config_before_repair(){
  local backup
  [[ -z ${REPAIR_CONFIG_BACKUP:-} ]] || return 0
  [[ -e $SB_CONFIG || -L $SB_CONFIG ]] || return 0
  managed_regular_file_is_trusted "$SB_CONFIG" || return 1
  backup=$(mktemp "$SB_DIR/.sb.json.before-repair.XXXXXX") || return 1
  if ! cp -p -- "$SB_CONFIG" "$backup" || ! chmod 600 "$backup"; then
    rm -f "$backup"
    return 1
  fi
  REPAIR_CONFIG_BACKUP=$backup
}

install_repair_config(){
  local candidate=$1 label=$2
  if ! managed_config_file_is_valid "$candidate" ||
     ! preserve_config_before_repair ||
     ! chmod 600 "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  # Mark the transaction before replacement so an interrupt cannot land
  # between mv(1) and the rollback state update.
  REPAIR_CONFIG_CHANGED=1
  if ! mv -fT -- "$candidate" "$SB_CONFIG"; then
    rm -f "$candidate"
    return 1
  fi
  REPAIR_CONFIG_ACTION=$label
  if [[ $REPAIR_CERT_FELL_BACK -eq 1 ]]; then
    REPAIR_CONFIG_ACTION+="，并切换为自签证书"
  fi
}

try_repair_config_source(){
  local source=$1 label=$2 candidate
  load_repair_config_values "$source" || return 1
  ensure_repair_certificate || return 1
  if [[ $source == "$SB_CONFIG" && $REPAIR_CERT_FELL_BACK -eq 0 ]] &&
     managed_config_file_is_valid "$source"; then
    REPAIR_CONFIG_ACTION="当前配置正常，节点参数保持不变"
    return 0
  fi
  candidate=$(mktemp "$SB_DIR/.sb.json.repair.XXXXXX") || return 1
  if ! render_repair_config "$candidate" || ! chmod 600 "$candidate" ||
     ! managed_config_file_is_valid "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  install_repair_config "$candidate" "$label"
}

repair_or_restore_config(){
  local path index latest latest_index last_good=${SB_LAST_GOOD:-$SB_DIR/sb.json.last-good}
  local -a candidates=()
  if try_repair_config_source "$SB_CONFIG" "已从当前节点参数重建标准配置"; then
    return 0
  fi
  if [[ $last_good != "$SB_CONFIG" ]] &&
     try_repair_config_source "$last_good" "已恢复最后一次可用配置"; then
    return 0
  fi
  for path in "$SB_DIR"/.sb.json.backup.* "$SB_DIR"/.sb.json.before-repair.*; do
    [[ -e $path || -L $path ]] || continue
    [[ $path != "${REPAIR_CONFIG_BACKUP:-}" ]] || continue
    managed_regular_file_is_trusted "$path" || continue
    candidates+=("$path")
  done
  while ((${#candidates[@]})); do
    latest=
    latest_index=
    for index in "${!candidates[@]}"; do
      if [[ -z $latest || ${candidates[$index]} -nt $latest ]]; then
        latest=${candidates[$index]}
        latest_index=$index
      fi
    done
    unset "candidates[$latest_index]"
    if try_repair_config_source "$latest" "已从最近的保留配置备份恢复"; then
      return 0
    fi
  done
  return 1
}

derive_reality_public_key(){
  local private_key=$1 encoded temp_dir result
  valid_reality_key "$private_key" || return 1
  temp_dir=$(mktemp -d "$SB_DIR/.reality-key.XXXXXX") || return 1
  encoded=$(printf '%s' "$private_key" | tr '_-' '/+')=
  if ! printf '%s' "$encoded" | base64 -d > "$temp_dir/raw.key" 2>/dev/null ||
     [[ $(stat -c '%s' "$temp_dir/raw.key" 2>/dev/null) != 32 ]]; then
    rm -rf "$temp_dir"
    return 1
  fi
  printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20' > "$temp_dir/private.der"
  cat "$temp_dir/raw.key" >> "$temp_dir/private.der" || { rm -rf "$temp_dir"; return 1; }
  if ! openssl pkey -inform DER -in "$temp_dir/private.der" -pubout -outform DER \
       -out "$temp_dir/public.der" 2>/dev/null ||
     [[ $(stat -c '%s' "$temp_dir/public.der" 2>/dev/null) != 44 ]]; then
    rm -rf "$temp_dir"
    return 1
  fi
  result=$(tail -c 32 "$temp_dir/public.der" | base64 | tr '+/' '-_' | tr -d '=\r\n')
  rm -rf "$temp_dir"
  valid_reality_key "$result" || return 1
  printf '%s\n' "$result"
}

repair_reality_public_key(){
  local private_key public_key expected_public_key public_tmp
  private_key=$(jq -er '.inbounds[] | select(.type == "vless" and .tag == "vless-sb") | .tls.reality.private_key' "$SB_CONFIG" 2>/dev/null) || return 1
  expected_public_key=$(derive_reality_public_key "$private_key") || return 1
  if managed_regular_file_is_trusted "$SB_DIR/public.key" &&
     public_key=$(cat "$SB_DIR/public.key" 2>/dev/null) &&
     [[ $public_key == "$expected_public_key" ]]; then
    chmod 600 "$SB_DIR/public.key"
    REPAIR_PUBLIC_KEY_ACTION="Reality公钥正常"
    return 0
  fi
  public_tmp=$(mktemp "$SB_DIR/.public.key.XXXXXX") || return 1
  if ! printf '%s\n' "$expected_public_key" > "$public_tmp" || ! chmod 600 "$public_tmp" ||
     ! mv -fT -- "$public_tmp" "$SB_DIR/public.key"; then
    rm -f "$public_tmp"
    return 1
  fi
  REPAIR_PUBLIC_KEY_ACTION="已从Reality私钥恢复公钥"
}

rebuild_config_in_place(){
  local confirmation key_pair private_key public_key short_id candidate acme_identity
  red "现有配置和恢复副本都无法提取完整节点参数"
  yellow "可以保留证书与ACME账户，在原目录生成全新节点；旧客户端配置将失效"
  readp "请输入 REBUILD 确认原地重建，其他输入取消：" confirmation || return 1
  [[ $confirmation == REBUILD ]] || return 1
  if ! self_signed_certificate_is_valid && ! generate_self_signed_certificate; then
    red "无法准备自签回退证书"
    return 1
  fi
  if acme_identity=$(detect_acme_identity 2>/dev/null); then
    REPAIR_CERT_PATH=$ACME_CERT
    REPAIR_KEY_PATH=$ACME_KEY
    REPAIR_CERT_MODE=acme
    REPAIR_CERT_ACTION="继续使用ACME证书 ($acme_identity)"
  else
    REPAIR_CERT_PATH="$SB_DIR/cert.pem"
    REPAIR_KEY_PATH="$SB_DIR/private.key"
    REPAIR_CERT_MODE=self_signed
    REPAIR_CERT_ACTION="使用已重建的自签证书"
  fi
  insport || return 1
  key_pair=$("$SB_BIN" generate reality-keypair 2>/dev/null) || return 1
  private_key=$(printf '%s\n' "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
  public_key=$(printf '%s\n' "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
  valid_reality_key "$private_key" && valid_reality_key "$public_key" || return 1
  short_id=$("$SB_BIN" generate rand --hex 4 2>/dev/null) || return 1
  valid_short_id "$short_id" || return 1
  v6only
  REPAIR_UUID=$uuid
  REPAIR_VLESS_PORT=$port_vl_re
  REPAIR_SOCKS_PORT=$port_socks5
  REPAIR_HY2_PORT=$port_hy2
  REPAIR_SNI=apple.com
  REPAIR_PRIVATE_KEY=$private_key
  REPAIR_SHORT_ID=$short_id
  REPAIR_SOCKS_PASSWORD=$socks_password
  REPAIR_STRATEGY=$ipv
  REPAIR_CERT_FELL_BACK=0
  candidate=$(mktemp "$SB_DIR/.sb.json.rebuild.XXXXXX") || return 1
  if ! render_repair_config "$candidate" || ! chmod 600 "$candidate" ||
     ! managed_config_file_is_valid "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  install_repair_config "$candidate" "已原地生成全新节点配置" || return 1
  atomic_write_private_text "$SB_DIR/public.key" "$public_key" || return 1
  REPAIR_PUBLIC_KEY_ACTION="已生成新的Reality公钥"
  REPAIR_NODE_REBUILT=1
}

repair_managed_permissions(){
  local path last_good=${SB_LAST_GOOD:-$SB_DIR/sb.json.last-good}
  managed_directory_is_owned || return 1
  chmod 700 "$SB_DIR" || return 1
  managed_regular_file_is_trusted "$SB_CONFIG" &&
    managed_regular_file_is_trusted "$SB_BIN" || return 1
  chmod 600 "$SB_MANAGED_MARKER" "$SB_CONFIG" || return 1
  chmod 755 "$SB_BIN" || return 1
  for path in "$last_good" "$SB_DIR/public.key" "$SB_DIR/cert.pem" "$SB_DIR/private.key"; do
    [[ -e $path || -L $path ]] || continue
    managed_regular_file_is_trusted "$path" || return 1
    chmod 600 "$path" || return 1
  done
  repair_acme_permissions
}

repair_acme_permissions(){
  local path
  if [[ ! -e $ACME_HOME && ! -L $ACME_HOME &&
        ! -e $ACME_CERT && ! -L $ACME_CERT &&
        ! -e $ACME_KEY && ! -L $ACME_KEY ]]; then
    return 0
  fi
  if [[ -e $ACME_HOME || -L $ACME_HOME ]]; then
    managed_tree_is_trusted "$ACME_HOME" || return 1
    (
      shopt -s dotglob nullglob globstar
      for path in "$ACME_HOME" "$ACME_HOME"/**; do
        if [[ -d $path ]]; then
          chmod 700 "$path" || exit 1
        elif [[ -f $path && ! -L $path ]]; then
          if [[ -x $path ]]; then chmod 700 "$path"; else chmod 600 "$path"; fi || exit 1
        else
          exit 1
        fi
      done
    ) || return 1
  fi
  if [[ -L $ACME_CERT || -L $ACME_KEY ]]; then
    active_acme_pair_is_trusted || return 1
  else
    for path in "$ACME_CERT" "$ACME_KEY"; do
      [[ -e $path || -L $path ]] || continue
      managed_regular_file_is_trusted "$path" || return 1
      chmod 600 "$path" || return 1
    done
  fi
  for path in "$ACME_IDENTITY" "$SB_DIR/acme_renew.state"; do
    [[ -e $path || -L $path ]] || continue
    managed_regular_file_is_trusted "$path" || return 1
    chmod 600 "$path" || return 1
  done
  for path in "$ACME_RELOAD" "$SB_DIR/acme_renew.sh"; do
    [[ -e $path || -L $path ]] || continue
    managed_regular_file_is_trusted "$path" || return 1
    chmod 700 "$path" || return 1
  done
}

initialize_repair_report(){
  REPAIR_CORE_ACTION="未执行"
  REPAIR_CONFIG_ACTION="未执行"
  REPAIR_CERT_ACTION="未执行"
  REPAIR_SERVICE_ACTION="未执行"
  REPAIR_PUBLIC_KEY_ACTION="未执行"
  REPAIR_SHORTCUT_ACTION="未执行"
  REPAIR_ACME_ACTION="未执行"
  REPAIR_CRON_ACTION="未执行"
  REPAIR_SHARE_ACTION="未执行"
  REPAIR_PERMISSION_ACTION="未执行"
  REPAIR_DEPENDENCY_ACTION="核心依赖待检查"
  REPAIR_CONFIG_BACKUP=
  REPAIR_CORE_BACKUP=
  REPAIR_SERVICE_BACKUP=
  REPAIR_SERVICE_BACKUP_MODE=
  REPAIR_SERVICE_BACKUP_PATH=
  REPAIR_CORE_QUARANTINE=
  REPAIR_RECOVERED_CONFIG=
  REPAIR_RECOVERED_CORE=
  REPAIR_TARGET_CONFIG_SNAPSHOT=
  REPAIR_TARGET_CORE_SNAPSHOT=
  REPAIR_ROLLBACK_STATE=not_attempted
  REPAIR_CORE_REPLACED=0
  REPAIR_CONFIG_CHANGED=0
  REPAIR_SERVICE_CHANGED=0
  REPAIR_ORIGINAL_STACK_VALID=0
  REPAIR_NODE_REBUILT=0
  REPAIR_TRANSACTION_FINALIZING=0
}

cleanup_repair_temporary_files(){
  local path failed=0
  cleanup_core_download_temp >/dev/null 2>&1 || failed=1
  for path in "$SB_DIR"/.sing-box.* "$SB_DIR"/.sb.json.repair.* \
    "$SB_DIR"/.sb.json.rebuild.* "$SB_DIR"/.sb.json.rollback.* \
    "$SB_DIR"/.public.key.* "$SB_DIR"/.reality-key.* \
    "$SB_DIR"/.repair-old-* "$SB_DIR"/.repair-target-*; do
    [[ -e $path || -L $path ]] || continue
    if [[ $path == "${REPAIR_TARGET_CORE_SNAPSHOT:-}" ||
          $path == "${REPAIR_TARGET_CONFIG_SNAPSHOT:-}" ]]; then
      continue
    fi
    rm -rf -- "$path" || failed=1
  done
  return "$failed"
}

begin_repair_transaction(){
  local backup service_path service_mode
  REPAIR_TRANSACTION_ACTIVE=1
  if [[ -e $SB_CONFIG || -L $SB_CONFIG ]] && managed_regular_file_is_trusted "$SB_CONFIG"; then
    preserve_config_before_repair || return 1
  fi
  if managed_regular_file_is_trusted "$SB_BIN" && [[ -x $SB_BIN ]]; then
    backup=$(mktemp "$SB_DIR/.repair-core-backup.XXXXXX") || return 1
    if ! cp -p -- "$SB_BIN" "$backup" || ! chmod 700 "$backup"; then
      rm -f -- "$backup"
      return 1
    fi
    REPAIR_CORE_BACKUP=$backup
  fi
  if service_exists || service_definition_is_repairable; then
    if command -v apk >/dev/null 2>&1; then
      service_path=$OPENRC_UNIT
    else
      service_path=$SYSTEMD_UNIT
    fi
    if managed_regular_file_is_trusted "$service_path"; then
      service_mode=$(stat -c '%a' "$service_path" 2>/dev/null) || return 1
      [[ $service_mode =~ ^[0-7]{3,4}$ ]] || return 1
      backup=$(mktemp "$SB_DIR/.repair-service-backup.XXXXXX") || return 1
      if ! cp -p -- "$service_path" "$backup" || ! chmod 600 "$backup"; then
        rm -f -- "$backup"
        return 1
      fi
      REPAIR_SERVICE_BACKUP=$backup
      REPAIR_SERVICE_BACKUP_MODE=$service_mode
      REPAIR_SERVICE_BACKUP_PATH=$service_path
    fi
  fi
  if [[ -n ${REPAIR_CORE_BACKUP:-} && -n ${REPAIR_CONFIG_BACKUP:-} &&
        -n ${REPAIR_SERVICE_BACKUP:-} ]] && service_is_active &&
     "$REPAIR_CORE_BACKUP" check -c "$REPAIR_CONFIG_BACKUP" >/dev/null 2>&1; then
    REPAIR_ORIGINAL_STACK_VALID=1
  fi
}

quarantine_invalid_core_path(){
  local quarantine
  [[ -e $SB_BIN || -L $SB_BIN ]] || return 0
  [[ ! -d $SB_BIN || -L $SB_BIN ]] && return 0
  quarantine=$(mktemp "$SB_DIR/.repair-core-invalid.XXXXXX") || return 1
  rm -f -- "$quarantine" || return 1
  if ! mv -T -- "$SB_BIN" "$quarantine"; then
    return 1
  fi
  REPAIR_CORE_QUARANTINE=$quarantine
}

restore_repair_service_definition(){
  local candidate
  [[ -n ${REPAIR_SERVICE_BACKUP:-} && -n ${REPAIR_SERVICE_BACKUP_PATH:-} &&
     ${REPAIR_SERVICE_BACKUP_MODE:-} =~ ^[0-7]{3,4}$ ]] || return 1
  managed_regular_file_is_trusted "$REPAIR_SERVICE_BACKUP" || return 1
  candidate=$(mktemp "${REPAIR_SERVICE_BACKUP_PATH}.repair.XXXXXX") || return 1
  if ! install -m "$REPAIR_SERVICE_BACKUP_MODE" "$REPAIR_SERVICE_BACKUP" "$candidate" ||
     ! mv -fT -- "$candidate" "$REPAIR_SERVICE_BACKUP_PATH"; then
    rm -f -- "$candidate"
    return 1
  fi
  if ! command -v apk >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || return 1
  fi
}

preserve_repair_target_core_snapshot(){
  local source=$1 recovered
  [[ -f $source && ! -L $source ]] || return 1
  recovered=$(mktemp "$SB_DIR/sing-box.recovered.XXXXXX") || return 1
  if ! install -m 700 "$source" "$recovered"; then
    rm -f -- "$recovered"
    return 1
  fi
  REPAIR_RECOVERED_CORE=$recovered
  rm -f -- "$source" || return 1
}

preserve_repair_target_config_snapshot(){
  local source=$1 recovered
  [[ -f $source && ! -L $source ]] || return 1
  recovered=$(mktemp "$SB_DIR/.sb.json.recovered.XXXXXX") || return 1
  if ! install -m 600 "$source" "$recovered"; then
    rm -f -- "$recovered"
    return 1
  fi
  REPAIR_RECOVERED_CONFIG=$recovered
  rm -f -- "$source" || return 1
}

restore_repair_target_config_snapshot(){
  local source=$1
  if mv -fT -- "$source" "$SB_CONFIG" >/dev/null 2>&1; then
    REPAIR_TARGET_CONFIG_SNAPSHOT=
    return 0
  fi
  if preserve_repair_target_config_snapshot "$source"; then
    REPAIR_TARGET_CONFIG_SNAPSHOT=
    return 2
  fi
  return 1
}

restore_original_repair_stack(){
  local old_core old_config target_core='' target_config='' rollback_ok=0
  local target_core_restored=0 target_config_restored=0 cleanup_failed=0 snapshot_status
  REPAIR_ROLLBACK_STATE=unresolved
  [[ ${REPAIR_ORIGINAL_STACK_VALID:-0} -eq 1 && -n ${REPAIR_CORE_BACKUP:-} &&
     -n ${REPAIR_CONFIG_BACKUP:-} ]] || return 2
  old_core=$(mktemp "$SB_DIR/.repair-old-core.XXXXXX") || return 1
  old_config=$(mktemp "$SB_DIR/.repair-old-config.XXXXXX") || { rm -f "$old_core"; return 1; }
  if ! install -m 700 "$REPAIR_CORE_BACKUP" "$old_core" ||
     ! cp -p -- "$REPAIR_CONFIG_BACKUP" "$old_config" || ! chmod 600 "$old_config" ||
     ! "$old_core" check -c "$old_config" >/dev/null 2>&1; then
    rm -f "$old_core" "$old_config"
    return 1
  fi
  if managed_regular_file_is_trusted "$SB_BIN"; then
    target_core=$(mktemp "$SB_DIR/.repair-target-core.XXXXXX") || target_core=
    if [[ -n $target_core ]] && ! install -m 755 "$SB_BIN" "$target_core"; then
      rm -f "$target_core"
      target_core=
    fi
    REPAIR_TARGET_CORE_SNAPSHOT=$target_core
  fi
  if managed_regular_file_is_trusted "$SB_CONFIG"; then
    target_config=$(mktemp "$SB_DIR/.repair-target-config.XXXXXX") || target_config=
    if [[ -n $target_config ]] &&
       { ! cp -p -- "$SB_CONFIG" "$target_config" || ! chmod 600 "$target_config"; }; then
      rm -f "$target_config"
      target_config=
    fi
    REPAIR_TARGET_CONFIG_SNAPSHOT=$target_config
  fi
  if mv -fT -- "$old_core" "$SB_BIN" && mv -fT -- "$old_config" "$SB_CONFIG" &&
     restore_repair_service_definition &&
     restartsb >/dev/null 2>&1 && sleep 1 && service_is_active; then
    rollback_ok=1
  fi
  if [[ $rollback_ok -eq 0 ]]; then
    if [[ -n $target_core ]]; then
      if mv -fT -- "$target_core" "$SB_BIN" >/dev/null 2>&1; then
        target_core=
        REPAIR_TARGET_CORE_SNAPSHOT=
        target_core_restored=1
      elif preserve_repair_target_core_snapshot "$target_core"; then
        target_core=
        REPAIR_TARGET_CORE_SNAPSHOT=
      fi
    fi
    if [[ -n $target_config ]]; then
      if restore_repair_target_config_snapshot "$target_config"; then
        snapshot_status=0
      else
        snapshot_status=$?
      fi
      if [[ $snapshot_status -eq 0 ]]; then
        target_config=
        target_config_restored=1
      elif [[ $snapshot_status -eq 2 ]]; then
        target_config=
      fi
    fi
    rm -f "$old_core" "$old_config"
    if [[ $target_core_restored -eq 1 && $target_config_restored -eq 1 ]] &&
       installed_core_is_current && managed_config_file_is_valid "$SB_CONFIG" &&
       repair_managed_service >/dev/null 2>&1; then
      REPAIR_ROLLBACK_STATE=target_restored
      REPAIR_SERVICE_ACTION="修复前状态恢复失败；已重新启用修复后内核、配置和服务"
      repair_reality_public_key || true
    fi
    return 1
  fi
  REPAIR_ROLLBACK_STATE=original_restored
  if [[ -n $target_core ]]; then
    if rm -f "$target_core"; then
      REPAIR_TARGET_CORE_SNAPSHOT=
    else
      cleanup_failed=1
    fi
  fi
  if [[ -n $target_config ]]; then
    if rm -f "$target_config"; then
      REPAIR_TARGET_CONFIG_SNAPSHOT=
    else
      cleanup_failed=1
    fi
  fi
  REPAIR_CORE_ACTION="目标内核未能完成修复，已恢复修复前内核"
  REPAIR_CONFIG_ACTION+="；已恢复修复前可用配置"
  REPAIR_SERVICE_ACTION="已恢复修复前服务定义并确认运行"
  REPAIR_NODE_REBUILT=0
  repair_reality_public_key || true
  return "$cleanup_failed"
}

abort_repair_transaction(){
  local status=0
  [[ ${REPAIR_TRANSACTION_ACTIVE:-0} -eq 1 ]] || return 0
  REPAIR_TRANSACTION_FINALIZING=1
  if [[ ${REPAIR_CORE_REPLACED:-0} -eq 1 || ${REPAIR_CONFIG_CHANGED:-0} -eq 1 ||
        ${REPAIR_SERVICE_CHANGED:-0} -eq 1 ]]; then
    if [[ ${REPAIR_ORIGINAL_STACK_VALID:-0} -eq 1 ]]; then
      restore_original_repair_stack || status=1
    else
      REPAIR_ROLLBACK_STATE=not_available
    fi
  else
    REPAIR_ROLLBACK_STATE=not_needed
  fi
  if [[ $REPAIR_ROLLBACK_STATE == original_restored ]]; then
    if [[ -n ${REPAIR_CORE_BACKUP:-} ]]; then
      if rm -f -- "$REPAIR_CORE_BACKUP"; then REPAIR_CORE_BACKUP=; else status=1; fi
    fi
    if [[ -n ${REPAIR_SERVICE_BACKUP:-} ]]; then
      if rm -f -- "$REPAIR_SERVICE_BACKUP"; then REPAIR_SERVICE_BACKUP=; else status=1; fi
    fi
  fi
  cleanup_repair_temporary_files || status=1
  REPAIR_TRANSACTION_ACTIVE=0
  REPAIR_TRANSACTION_FINALIZING=0
  return "$status"
}

commit_repair_transaction(){
  local status=0
  [[ ${REPAIR_TRANSACTION_ACTIVE:-0} -eq 1 ]] || return 1
  REPAIR_TRANSACTION_FINALIZING=1
  if [[ -n ${REPAIR_CORE_BACKUP:-} ]]; then
    if rm -f -- "$REPAIR_CORE_BACKUP"; then REPAIR_CORE_BACKUP=; else status=1; fi
  fi
  if [[ -n ${REPAIR_SERVICE_BACKUP:-} ]]; then
    if rm -f -- "$REPAIR_SERVICE_BACKUP"; then REPAIR_SERVICE_BACKUP=; else status=1; fi
  fi
  cleanup_repair_temporary_files || status=1
  REPAIR_TRANSACTION_ACTIVE=0
  REPAIR_TRANSACTION_FINALIZING=0
  return "$status"
}

show_repair_report(){
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  green "修复报告"
  printf '内核: %s\n' "$REPAIR_CORE_ACTION"
  printf '配置: %s\n' "$REPAIR_CONFIG_ACTION"
  printf '证书: %s\n' "$REPAIR_CERT_ACTION"
  printf '服务: %s\n' "$REPAIR_SERVICE_ACTION"
  printf 'Reality公钥: %s\n' "$REPAIR_PUBLIC_KEY_ACTION"
  printf '快捷命令: %s\n' "$REPAIR_SHORTCUT_ACTION"
  printf '证书续期: %s\n' "$REPAIR_ACME_ACTION"
  printf '每日任务: %s\n' "$REPAIR_CRON_ACTION"
  printf '节点文件: %s\n' "$REPAIR_SHARE_ACTION"
  printf '文件权限: %s\n' "$REPAIR_PERMISSION_ACTION"
  printf '依赖组件: %s\n' "$REPAIR_DEPENDENCY_ACTION"
  [[ -z $REPAIR_CONFIG_BACKUP ]] || printf '原配置保留: %s\n' "$REPAIR_CONFIG_BACKUP"
  [[ -z ${REPAIR_CORE_QUARANTINE:-} ]] || printf '异常内核路径保留: %s\n' "$REPAIR_CORE_QUARANTINE"
  [[ -z ${REPAIR_CORE_BACKUP:-} ]] || printf '修复前内核保留: %s\n' "$REPAIR_CORE_BACKUP"
  [[ -z ${REPAIR_SERVICE_BACKUP:-} ]] || printf '修复前服务定义保留: %s\n' "$REPAIR_SERVICE_BACKUP"
  [[ -z ${REPAIR_RECOVERED_CONFIG:-} ]] || printf '修复配置副本: %s\n' "$REPAIR_RECOVERED_CONFIG"
  [[ -z ${REPAIR_RECOVERED_CORE:-} ]] || printf '修复内核副本: %s\n' "$REPAIR_RECOVERED_CORE"
  [[ -z ${REPAIR_TARGET_CONFIG_SNAPSHOT:-} ]] || printf '待恢复的修复配置: %s\n' "$REPAIR_TARGET_CONFIG_SNAPSHOT"
  [[ -z ${REPAIR_TARGET_CORE_SNAPSHOT:-} ]] || printf '待恢复的修复内核: %s\n' "$REPAIR_TARGET_CORE_SNAPSHOT"
  red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

repair_singbox_locked(){
  local maintenance_failed=0 identity
  initialize_repair_report
  REPAIR_DEPENDENCY_ACTION="核心修复依赖正常，维护依赖待检查"
  if ! begin_repair_transaction; then
    REPAIR_CORE_ACTION="无法建立修复恢复点"
    REPAIR_SERVICE_ACTION="未修改"
    commit_repair_transaction || REPAIR_DEPENDENCY_ACTION="恢复点建立失败；部分临时文件或备份未清理"
    show_repair_report
    return 1
  fi
  if installed_core_is_current; then
    REPAIR_CORE_ACTION="Sing-box v${CORE_VERSION} 正常"
  else
    green "正在恢复固定版本 Sing-box v${CORE_VERSION} 内核……"
    # inssb performs the final mv itself; set the flag first so signals and
    # post-replacement verification failures still restore a usable old stack.
    REPAIR_CORE_REPLACED=1
    if ! quarantine_invalid_core_path || ! inssb; then
      REPAIR_CORE_ACTION="固定版本内核恢复失败"
      abort_repair_transaction || true
      show_repair_report
      return 1
    fi
    REPAIR_CORE_ACTION="已重新安装 Sing-box v${CORE_VERSION}"
  fi
  if ! repair_or_restore_config; then
    if ! rebuild_config_in_place; then
      REPAIR_CONFIG_ACTION="无法恢复配置，已取消原地重建"
      abort_repair_transaction || true
      case $REPAIR_ROLLBACK_STATE in
        original_restored) REPAIR_SERVICE_ACTION="已恢复修复前可用服务" ;;
        target_restored) REPAIR_SERVICE_ACTION="修复前状态未恢复；已保留并重新启用本次修复状态" ;;
        *) REPAIR_SERVICE_ACTION="未能建立可运行的新配置；原数据与恢复副本仍保留" ;;
      esac
      show_repair_report
      return 1
    fi
  fi
  if ! repair_reality_public_key; then
    REPAIR_PUBLIC_KEY_ACTION="恢复失败；服务可运行，但节点文件无法刷新"
    maintenance_failed=1
  fi
  REPAIR_SERVICE_CHANGED=1
  if repair_managed_service; then
    REPAIR_SERVICE_ACTION="服务定义已重写并确认运行"
  else
    abort_repair_transaction || true
    case $REPAIR_ROLLBACK_STATE in
      original_restored)
        REPAIR_SERVICE_ACTION="新服务启动失败；已恢复修复前内核、配置和服务"
        ;;
      target_restored)
        REPAIR_SERVICE_ACTION="修复前状态恢复失败；已重新启用修复后的内核、配置和服务"
        ;;
      *)
        if [[ ${REPAIR_CONFIG_CHANGED:-0} -eq 1 ]]; then
          REPAIR_SERVICE_ACTION="恢复未完成；修复后的有效配置或副本已保留，损坏原件未重新启用"
        else
          REPAIR_SERVICE_ACTION="恢复未完成；本次未替换配置，请检查保留的恢复点"
        fi
        ;;
    esac
    show_repair_report
    return 1
  fi
  if ! commit_repair_transaction; then
    REPAIR_DEPENDENCY_ACTION="核心服务已恢复；修复临时文件清理不完整"
    maintenance_failed=1
  fi
  if ! save_last_good_config "$SB_CONFIG"; then
    yellow "服务已恢复，但最后可用配置快照保存失败"
    maintenance_failed=1
  fi
  if repair_managed_permissions; then
    REPAIR_PERMISSION_ACTION="受管文件属主、类型与权限正常"
  else
    REPAIR_PERMISSION_ACTION="检查或修复失败；未执行不可信的ACME组件"
    maintenance_failed=1
  fi
  if dependencies_ready; then
    REPAIR_DEPENDENCY_ACTION="核心与维护依赖正常"
  else
    yellow "核心服务已恢复，正在补齐cron、flock或二维码等维护组件……"
    if install_dependencies; then
      REPAIR_DEPENDENCY_ACTION="核心与维护依赖已补齐"
    else
      REPAIR_DEPENDENCY_ACTION="核心服务可用；部分维护依赖仍不可用"
      maintenance_failed=1
    fi
  fi
  if update_shortcut; then
    REPAIR_SHORTCUT_ACTION="sb 快捷命令已更新"
  else
    REPAIR_SHORTCUT_ACTION="更新失败"
    maintenance_failed=1
  fi
  identity=
  if config_uses_acme_certificate; then
    identity=$(detect_acme_identity 2>/dev/null || true)
  fi
  if config_uses_acme_certificate &&
     { [[ -z $identity ]] || ! acme_maintenance_components_are_trusted "$identity"; }; then
    REPAIR_ACME_ACTION="当前证书有效，但自动续期组件不可信或不完整"
    maintenance_failed=1
  elif ensure_acme_renew_cron; then
    if config_uses_acme_certificate; then
      REPAIR_ACME_ACTION="自动续期组件正常"
    else
      REPAIR_ACME_ACTION="当前使用自签证书，ACME任务已暂停"
    fi
  else
    REPAIR_ACME_ACTION="检查或修复失败"
    maintenance_failed=1
  fi
  if cronsb; then
    REPAIR_CRON_ACTION="每日重启任务正常"
  else
    REPAIR_CRON_ACTION="设置失败"
    maintenance_failed=1
  fi
  if refresh_share_files_after_change; then
    REPAIR_SHARE_ACTION="已刷新"
  else
    REPAIR_SHARE_ACTION="刷新失败，可稍后使用菜单[3]重试"
    maintenance_failed=1
  fi
  show_repair_report
  if [[ $REPAIR_NODE_REBUILT -eq 1 ]]; then
    yellow "节点凭据已重新生成，请更新所有客户端配置"
  fi
  if [[ $maintenance_failed -eq 0 ]]; then
    green "sb 全部检查项修复完成"
    return 0
  fi
  yellow "sb 核心服务已恢复，但上方部分维护项仍需处理"
  return 1
}

repair_singbox(){
  local repair_status
  if ! managed_directory_is_owned ||
     { ! managed_install_data_present && ! service_definition_is_repairable; }; then
    red "未检测到可修复的sb安装数据，请使用菜单[1]安装"
    readp "按回车返回主菜单..."
    return 1
  fi
  if service_name_conflict && ! service_definition_is_repairable; then
    red "检测到不属于sb.sh的同名服务，拒绝修复"
    readp "按回车返回主菜单..."
    return 1
  fi
  if ! core_dependencies_ready; then
    yellow "核心修复依赖不完整，正在尝试补齐……"
    install_dependencies || true
    if ! core_dependencies_ready; then
      red "核心修复依赖仍不完整，无法安全处理内核、配置或服务"
      readp "按回车返回主菜单..."
      return 1
    fi
  fi
  if with_lifecycle_acme_lock repair_singbox_locked; then
    repair_status=0
  else
    repair_status=$?
  fi
  readp "按回车返回主菜单..."
  return "$repair_status"
}
