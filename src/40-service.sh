# sb-module: 40-service
managed_path_is_trusted(){
  local path=$1 expected_owner owner mode
  [[ -e $path && ! -L $path ]] || return 1
  expected_owner=$(id -u 2>/dev/null) || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
  [[ $owner == "$expected_owner" && $mode =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

managed_regular_file_is_trusted(){
  local path=$1
  [[ -f $path && ! -L $path ]] && managed_path_is_trusted "$path"
}

managed_symlink_is_trusted(){
  local path=$1 expected_owner owner
  [[ -L $path ]] || return 1
  expected_owner=$(id -u 2>/dev/null) || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  [[ $owner == "$expected_owner" ]]
}

atomic_write_private_text(){
  local destination=$1 value=$2 candidate name
  name=${destination##*/}
  [[ ${destination%/*} == "$SB_DIR" && $name =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ -d $SB_DIR && ! -L $SB_DIR ]] && managed_path_is_trusted "$SB_DIR" || return 1
  candidate=$(mktemp "$SB_DIR/.managed-write.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$candidate" || ! chmod 600 "$candidate" ||
     ! mv -fT -- "$candidate" "$destination"; then
    rm -f -- "$candidate"
    return 1
  fi
}

atomic_copy_private_file(){
  local source=$1 destination=$2 candidate name
  name=${destination##*/}
  [[ -f $source && ! -L $source && ${destination%/*} == "$SB_DIR" &&
     $name =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ -d $SB_DIR && ! -L $SB_DIR ]] && managed_path_is_trusted "$SB_DIR" || return 1
  candidate=$(mktemp "$SB_DIR/.managed-copy.XXXXXX") || return 1
  if ! cp -- "$source" "$candidate" || ! chmod 600 "$candidate" ||
     ! mv -fT -- "$candidate" "$destination"; then
    rm -f -- "$candidate"
    return 1
  fi
}

write_managed_marker_at(){
  local directory=$1 marker_tmp marker="$1/.sb-managed"
  [[ ! -e $directory || -d $directory && ! -L $directory ]] || return 1
  mkdir -p "$directory" || return 1
  chmod 700 "$directory" || return 1
  marker_tmp=$(mktemp "$directory/.sb-managed.XXXXXX") || return 1
  if ! printf '%s\n' 'managed_by=sb.sh' 'identity=sb' 'directory=/etc/sb' > "$marker_tmp" ||
     ! chmod 600 "$marker_tmp" || ! mv -fT -- "$marker_tmp" "$marker"; then
    rm -f "$marker_tmp"
    return 1
  fi
}

write_managed_marker(){
  write_managed_marker_at "$SB_DIR"
}

managed_directory_is_owned(){
  [[ -d $SB_DIR && ! -L $SB_DIR && -f $SB_MANAGED_MARKER && ! -L $SB_MANAGED_MARKER ]] || return 1
  managed_path_is_trusted "$SB_DIR" && managed_regular_file_is_trusted "$SB_MANAGED_MARKER" || return 1
  grep -Fqx 'managed_by=sb.sh' "$SB_MANAGED_MARKER" 2>/dev/null &&
    grep -Fqx 'identity=sb' "$SB_MANAGED_MARKER" 2>/dev/null &&
    grep -Fqx 'directory=/etc/sb' "$SB_MANAGED_MARKER" 2>/dev/null
}

prepare_managed_directory(){
  if [[ ! -e $SB_DIR && ! -L $SB_DIR ]]; then
    write_managed_marker
  elif managed_directory_is_owned; then
    chmod 700 "$SB_DIR"
  else
    red "检测到不属于本脚本的 $SB_DIR，拒绝覆盖"
    return 1
  fi
}

systemd_unit_is_owned(){
  local unit=$1 directory=$2 binary=$3 config=$4 marker_pattern=$5 service_name fragment dropins
  [[ -f $unit && ! -L $unit ]] || return 1
  service_name=$(basename "$unit" .service)
  systemd_service_has_other_units "$service_name" "$unit" && return 1
  systemd_service_has_dropins "$service_name" && return 1
  fragment=$(systemctl show "${service_name}.service" -p FragmentPath --value 2>/dev/null || true)
  dropins=$(systemctl show "${service_name}.service" -p DropInPaths --value 2>/dev/null || true)
  [[ -z $fragment || $fragment == "$unit" ]] || return 1
  [[ -z $dropins ]] || return 1
  grep -Eq "$marker_pattern" "$unit" 2>/dev/null &&
    grep -Fqx "WorkingDirectory=$directory" "$unit" 2>/dev/null &&
    grep -Fqx "ExecStart=$binary run -c $config" "$unit" 2>/dev/null
}

systemd_service_has_other_units(){
  local service=$1 expected=$2 base unit
  for base in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system \
    /usr/lib/systemd/system /lib/systemd/system; do
    unit="$base/${service}.service"
    [[ $unit == "$expected" ]] && continue
    [[ -e $unit || -L $unit ]] && return 0
  done
  return 1
}

systemd_service_has_dropins(){
  local service=$1 base directory entry
  for base in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system \
    /usr/lib/systemd/system /lib/systemd/system; do
    directory="$base/${service}.service.d"
    if [[ -L $directory || -e $directory && ! -d $directory ]]; then
      return 0
    fi
    if [[ -d $directory ]]; then
      for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        [[ -e $entry || -L $entry ]] && return 0
      done
    fi
  done
  return 1
}

systemd_service_definition_present(){
  local service=$1 base unit
  systemd_service_has_dropins "$service" && return 0
  for base in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system \
    /usr/lib/systemd/system /lib/systemd/system; do
    unit="$base/${service}.service"
    [[ -e $unit || -L $unit ]] && return 0
  done
  command -v systemctl >/dev/null 2>&1 && systemctl cat "$service" >/dev/null 2>&1
}

openrc_unit_is_owned(){
  local unit=$1 binary=$2 config=$3 marker_pattern=$4
  [[ -f $unit && ! -L $unit ]] || return 1
  grep -Eq "$marker_pattern" "$unit" 2>/dev/null &&
    grep -Fqx "command=\"$binary\"" "$unit" 2>/dev/null &&
    grep -Fqx "command_args=\"run -c $config\"" "$unit" 2>/dev/null
}

systemd_service_definition_is_repairable(){
  local unit=${1:-$SYSTEMD_UNIT}
  [[ -f $unit && ! -L $unit ]] || return 1
  grep -Fqx '# Managed by sb.sh' "$unit" 2>/dev/null || return 1
  systemd_service_has_other_units "$SB_SERVICE" "$unit" && return 1
  systemd_service_has_dropins "$SB_SERVICE" && return 1
  [[ ! -e $OPENRC_UNIT && ! -L $OPENRC_UNIT ]]
}

openrc_service_definition_is_repairable(){
  [[ -f $OPENRC_UNIT && ! -L $OPENRC_UNIT ]] || return 1
  grep -Fqx '# Managed by sb.sh' "$OPENRC_UNIT" 2>/dev/null || return 1
  ! systemd_service_definition_present "$SB_SERVICE"
}

service_definition_is_repairable(){
  if command -v apk >/dev/null 2>&1; then
    openrc_service_definition_is_repairable
  else
    systemd_service_definition_is_repairable "$SYSTEMD_UNIT"
  fi
}

write_service_definition(){
  local unit_tmp
  if command -v apk >/dev/null 2>&1; then
    unit_tmp=$(mktemp "/etc/init.d/.${SB_SERVICE}.XXXXXX") || return 1
    if ! cat > "$unit_tmp" <<EOF
#!/sbin/openrc-run
# Managed by sb.sh
description="sb sing-box service"
command="$SB_BIN"
command_args="run -c $SB_CONFIG"
command_background=true
pidfile="/var/run/${SB_SERVICE}.pid"
EOF
    then
      rm -f "$unit_tmp"
      return 1
    fi
    if ! chmod 700 "$unit_tmp" || ! mv -fT -- "$unit_tmp" "$OPENRC_UNIT"; then
      rm -f "$unit_tmp"
      return 1
    fi
  else
    unit_tmp=$(mktemp "/etc/systemd/system/.${SB_SERVICE}.service.XXXXXX") || return 1
    if ! cat > "$unit_tmp" <<EOF
[Unit]
# Managed by sb.sh
Description=sb sing-box service
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=$SB_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_BIN run -c $SB_CONFIG
ExecReload=/usr/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
    then
      rm -f "$unit_tmp"
      return 1
    fi
    if ! chmod 600 "$unit_tmp" || ! mv -fT -- "$unit_tmp" "$SYSTEMD_UNIT"; then
      rm -f "$unit_tmp"
      return 1
    fi
  fi
}

sbservice(){
  if service_name_conflict; then
    red "检测到不属于sb.sh的同名 $SB_SERVICE 服务，拒绝覆盖"
    return 1
  fi
  if ! "$SB_BIN" check -c "$SB_CONFIG" >/dev/null 2>&1; then
    red "Sing-box配置检查失败，未创建服务"
    "$SB_BIN" check -c "$SB_CONFIG"
    return 1
  fi
  if ! write_service_definition; then
    red "写入 $SB_SERVICE 服务文件失败"
    return 1
  fi
  if command -v apk >/dev/null 2>&1; then
    if ! rc-update add "$SB_SERVICE" default >/dev/null 2>&1 || ! rc-service "$SB_SERVICE" start; then
      if cleanup_service; then
        red "创建或启动 $SB_SERVICE 服务失败，已清理服务文件"
      else
        red "创建或启动 $SB_SERVICE 服务失败，且自动清理未完成，请手动检查"
      fi
      return 1
    fi
  else
    if ! systemctl daemon-reload || ! systemctl enable --now "$SB_SERVICE"; then
      if cleanup_service; then
        red "创建或启动 $SB_SERVICE 服务失败，已清理服务文件"
      else
        red "创建或启动 $SB_SERVICE 服务失败，且自动清理未完成，请手动检查"
      fi
      return 1
    fi
  fi
  if ! service_is_active; then
    if cleanup_service; then
      red "$SB_SERVICE 服务启动后未保持运行，已清理服务文件"
    else
      red "$SB_SERVICE 服务启动后未保持运行，且自动清理未完成，请手动检查"
    fi
    return 1
  fi
  return 0
}

repair_managed_service(){
  if service_name_conflict && ! service_definition_is_repairable; then
    red "检测到不属于sb.sh的同名 $SB_SERVICE 服务，拒绝覆盖"
    return 1
  fi
  if ! installed_core_is_current || [[ ! -s $SB_CONFIG ]] ||
     ! "$SB_BIN" check -c "$SB_CONFIG" >/dev/null 2>&1; then
    red "内核或配置仍未通过检查，不能重建服务"
    return 1
  fi
  write_service_definition || return 1
  if command -v apk >/dev/null 2>&1; then
    rc-update add "$SB_SERVICE" default >/dev/null 2>&1 ||
      rc-update show default 2>/dev/null | grep -qE "(^|[[:space:]])${SB_SERVICE}([[:space:]]|$)" || return 1
    if service_is_active; then
      rc-service "$SB_SERVICE" restart >/dev/null 2>&1 || return 1
    else
      rc-service "$SB_SERVICE" start >/dev/null 2>&1 || return 1
    fi
  else
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable "$SB_SERVICE" >/dev/null 2>&1 || return 1
    systemctl restart "$SB_SERVICE" >/dev/null 2>&1 || return 1
  fi
  sleep 1
  service_is_active
}

restartsb(){
  if command -v apk >/dev/null 2>&1; then
    rc-service "$SB_SERVICE" restart
  else
    systemctl restart "$SB_SERVICE"
  fi
}

service_is_active(){
  if command -v apk >/dev/null 2>&1; then
    rc-service "$SB_SERVICE" status 2>/dev/null | grep -q "started"
  else
    systemctl is-active "$SB_SERVICE" 2>/dev/null | grep -qx "active"
  fi
}

service_is_owned(){
  if command -v apk >/dev/null 2>&1; then
    systemd_service_definition_present "$SB_SERVICE" && return 1
    openrc_unit_is_owned "$OPENRC_UNIT" "$SB_BIN" "$SB_CONFIG" '^# Managed by sb\.sh$'
  else
    [[ ! -e $OPENRC_UNIT && ! -L $OPENRC_UNIT ]] || return 1
    systemd_unit_is_owned "$SYSTEMD_UNIT" "$SB_DIR" "$SB_BIN" "$SB_CONFIG" '^# Managed by sb\.sh$'
  fi
}

formal_service_present(){
  [[ -e $OPENRC_UNIT || -L $OPENRC_UNIT ]] ||
    systemd_service_definition_present "$SB_SERVICE"
}

service_name_conflict(){
  formal_service_present || return 1
  service_is_owned && return 1
  service_definition_is_repairable && return 1
  return 0
}

service_exists(){
  service_is_owned
}

is_installed(){
  managed_directory_is_owned && service_exists && [[ -x $SB_BIN && -s $SB_CONFIG ]]
}

managed_install_data_present(){
  [[ -x $SB_BIN || -s $SB_CONFIG || -s $SB_DIR/private.key || -s $SB_DIR/cert.pem ||
     -s $ACME_KEY || -s $ACME_CERT || -s $SB_DIR/public.key ||
     -s ${SB_LAST_GOOD:-$SB_DIR/sb.json.last-good} ]]
}

installed_core_is_current(){
  local installed_core
  [[ -f $SB_BIN && ! -L $SB_BIN && -x $SB_BIN ]] || return 1
  managed_regular_file_is_trusted "$SB_BIN" || return 1
  installed_core=$("$SB_BIN" version 2>/dev/null | awk '/version/{print $NF}')
  [[ $installed_core == "$CORE_VERSION" ]]
}

managed_config_file_is_valid(){
  local source=$1
  [[ -s $source ]] && managed_regular_file_is_trusted "$source" || return 1
  installed_core_is_current || return 1
  "$SB_BIN" check -c "$source" >/dev/null 2>&1
}

save_last_good_config(){
  local source=${1:-$SB_CONFIG} destination=${SB_LAST_GOOD:-$SB_DIR/sb.json.last-good} candidate
  managed_config_file_is_valid "$source" || return 1
  if [[ -e $destination || -L $destination ]]; then
    [[ -f $destination && ! -L $destination ]] || return 1
    if cmp -s -- "$source" "$destination"; then
      chmod 600 "$destination"
      return
    fi
  fi
  candidate=$(mktemp "$SB_DIR/.sb.json.last-good.XXXXXX") || return 1
  if ! cp -p -- "$source" "$candidate" || ! chmod 600 "$candidate" ||
     ! mv -fT -- "$candidate" "$destination"; then
    rm -f "$candidate"
    return 1
  fi
}

installed_config_is_valid(){
  installed_core_is_current && [[ -s $SB_CONFIG ]] || return 1
  "$SB_BIN" check -c "$SB_CONFIG" >/dev/null 2>&1
}

cleanup_service(){
  local failed=0
  service_name_conflict && return 1
  if command -v apk >/dev/null 2>&1; then
    rc-service "$SB_SERVICE" stop >/dev/null 2>&1 || true
    service_is_active && return 1
    rc-update del "$SB_SERVICE" default >/dev/null 2>&1 || true
    rc-update show default 2>/dev/null | grep -qE "(^|[[:space:]])${SB_SERVICE}([[:space:]]|$)" && failed=1
    rm -f "$OPENRC_UNIT" || failed=1
    [[ ! -e $OPENRC_UNIT ]] || failed=1
  else
    systemctl stop "$SB_SERVICE" >/dev/null 2>&1 || true
    service_is_active && return 1
    systemctl disable "$SB_SERVICE" >/dev/null 2>&1 || true
    systemctl is-enabled "$SB_SERVICE" >/dev/null 2>&1 && failed=1
    rm -f "$SYSTEMD_UNIT" || failed=1
    [[ ! -e $SYSTEMD_UNIT ]] || failed=1
    systemctl daemon-reload >/dev/null 2>&1 || failed=1
  fi
  return "$failed"
}

sbactive(){
  if [[ ! -s $SB_CONFIG ]]; then
    red "配置文件 $SB_CONFIG 不存在，请重新安装"
    return 1
  fi
  if ! service_is_active; then
    red "Sing-box服务未运行，请检查日志"
    return 1
  fi
}

commit_config(){
  local candidate=$1 backup
  if [[ ! -s $candidate ]]; then
    red "候选配置不存在或为空"
    rm -f "$candidate"
    return 1
  fi
  if ! "$SB_BIN" check -c "$candidate" >/dev/null 2>&1; then
    red "新配置未通过 Sing-box v${CORE_VERSION} 检查，已取消修改"
    "$SB_BIN" check -c "$candidate"
    rm -f "$candidate"
    return 1
  fi
  backup=$(mktemp "$SB_DIR/.sb.json.backup.XXXXXX") || { rm -f "$candidate"; return 1; }
  if ! cp -p "$SB_CONFIG" "$backup"; then
    rm -f "$candidate" "$backup"
    return 1
  fi
  chmod 600 "$candidate"
  if ! mv -fT -- "$candidate" "$SB_CONFIG"; then
    rm -f "$candidate" "$backup"
    return 1
  fi
  if restartsb >/dev/null 2>&1 && sleep 1 && service_is_active; then
    rm -f "$backup"
    save_last_good_config "$SB_CONFIG" || yellow "配置已生效，但最后可用配置快照更新失败"
    return 0
  fi
  red "服务未能使用新配置启动，正在回滚"
  if cp -p "$backup" "$SB_CONFIG" && chmod 600 "$SB_CONFIG" && \
     restartsb >/dev/null 2>&1 && sleep 1 && service_is_active; then
    rm -f "$backup"
    red "已恢复修改前的配置和服务"
    return 1
  fi
  red "自动回滚失败！请立即检查服务；原配置备份保留在 $backup"
  return 2
}
