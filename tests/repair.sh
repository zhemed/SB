#!/usr/bin/env bash
# The repair harness deliberately rebinds globals and mocks functions inside
# subshells; production code consumes those names indirectly after sourcing.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
set -Eeuo pipefail

export LC_ALL=C
TEMP_DIR=$(mktemp -d)
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly TEMP_DIR ROOT_DIR
trap 'rm -rf -- "$TEMP_DIR"' EXIT

passed=0
pass(){ passed=$((passed + 1)); printf 'ok %d - %s\n' "$passed" "$1"; }
skip(){ passed=$((passed + 1)); printf 'ok %d - %s # SKIP %s\n' "$passed" "$1" "$2"; }
fail(){ printf 'not ok %d - %s\n' "$((passed + 1))" "$1" >&2; exit 1; }
expect_success(){ local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
expect_failure(){ local name=$1; shift; if "$@"; then fail "$name"; else pass "$name"; fi; }

rejects_simulated_foreign_owner(){
  local foreign_path=$1
  shift
  (
    stat(){
      if [[ ${1-} == -c && ${2-} == '%u' && ${3-} == "$foreign_path" ]]; then
        printf '%s\n' "$(( $(id -u) + 1 ))"
      else
        command stat "$@"
      fi
    }
    ! "$@"
  )
}

repairs_core_path_that_is_a_directory(){
  (
    local source_core=$SB_BIN case_dir="$TEMP_DIR/core-directory-case"
    SB_DIR="$case_dir/sb"
    SB_BIN="$SB_DIR/sing-box"
    SB_CONFIG="$SB_DIR/sb.json"
    SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
    mkdir -p "$SB_BIN"
    printf '%s\n' keep-me > "$SB_BIN/sentinel"
    initialize_repair_report
    inssb(){
      cp -- "$source_core" "$SB_BIN" && chmod 755 "$SB_BIN"
    }
    quarantine_invalid_core_path && inssb && installed_core_is_current || return 1
    [[ -n $REPAIR_CORE_QUARANTINE && -d $REPAIR_CORE_QUARANTINE &&
       -f $REPAIR_CORE_QUARANTINE/sentinel && -f $SB_BIN && ! -L $SB_BIN ]]
  )
}


server_ip_symlink_is_replaced_without_following(){
  (
    local outside="$TEMP_DIR/server-ip-outside"
    valid_ipv4(){ [[ ${1-} == 192.0.2.10 ]]; }
    printf '%s\n' outside-sentinel > "$outside"
    rm -rf -- "$SB_DIR/server_ip.log"
    ln -s -- "$outside" "$SB_DIR/server_ip.log" || return 1
    save_server_ip 192.0.2.10 || return 1
    [[ -f $SB_DIR/server_ip.log && ! -L $SB_DIR/server_ip.log &&
       $(<"$SB_DIR/server_ip.log") == 192.0.2.10 &&
       $(<"$outside") == outside-sentinel ]]
  )
}

server_ip_directory_is_rejected(){
  (
    local status=0
    valid_ipv4(){ [[ ${1-} == 192.0.2.11 ]]; }
    rm -rf -- "$SB_DIR/server_ip.log"
    mkdir "$SB_DIR/server_ip.log" || return 1
    save_server_ip 192.0.2.11 >/dev/null 2>&1 && status=1
    [[ -d $SB_DIR/server_ip.log && ! -L $SB_DIR/server_ip.log ]] || status=1
    rm -rf -- "$SB_DIR/server_ip.log"
    save_server_ip 192.0.2.11 || status=1
    return "$status"
  )
}

sha256_symlink_is_replaced_without_following(){
  local outside="$TEMP_DIR/sha256-outside" value
  value=$(printf 'a%.0s' {1..64})
  printf '%s\n' outside-sentinel > "$outside"
  rm -rf -- "$SB_DIR/SHA256.txt"
  ln -s -- "$outside" "$SB_DIR/SHA256.txt" || return 1
  atomic_write_private_text "$SB_DIR/SHA256.txt" "$value" || return 1
  [[ -f $SB_DIR/SHA256.txt && ! -L $SB_DIR/SHA256.txt &&
     $(<"$SB_DIR/SHA256.txt") == "$value" &&
     $(<"$outside") == outside-sentinel ]]
}

sha256_directory_is_rejected(){
  local status=0 value
  value=$(printf 'b%.0s' {1..64})
  rm -rf -- "$SB_DIR/SHA256.txt"
  mkdir "$SB_DIR/SHA256.txt" || return 1
  atomic_write_private_text "$SB_DIR/SHA256.txt" "$value" >/dev/null 2>&1 && status=1
  [[ -d $SB_DIR/SHA256.txt && ! -L $SB_DIR/SHA256.txt ]] || status=1
  rm -rf -- "$SB_DIR/SHA256.txt"
  return "$status"
}

valid_acme_certificate_survives_maintenance_failure(){
  (
    REPAIR_CERT_MODE=acme
    REPAIR_CERT_PATH=$ACME_CERT
    REPAIR_KEY_PATH=$ACME_KEY
    detect_acme_identity(){ printf '%s\n' example.com; }
    active_acme_pair_is_trusted(){ return 0; }
    acme_maintenance_components_are_trusted(){ return 1; }
    ensure_repair_certificate || return 1
    [[ $REPAIR_CERT_MODE == acme && $REPAIR_CERT_PATH == "$ACME_CERT" &&
       $REPAIR_KEY_PATH == "$ACME_KEY" && $REPAIR_CERT_FELL_BACK -eq 0 &&
       $REPAIR_ACME_MAINTENANCE_OK -eq 0 &&
       $REPAIR_CERT_ACTION == "ACME证书有效；续期维护组件待修复" ]]
  )
}

unrecoverable_acme_certificate_falls_back_safely(){
  (
    local acme_config="$TEMP_DIR/acme-fallback-config.json" cert_path key_path
    case $(uname -s) in
      MINGW*|MSYS*)
        ACME_CERT=$(cygpath -m -- "$ACME_CERT") || return 1
        ACME_KEY=$(cygpath -m -- "$ACME_KEY") || return 1
        ;;
    esac
    ACME_CERT_VALUE=$ACME_CERT ACME_KEY_VALUE=$ACME_KEY jq '
      (.inbounds[] | select(.tag == "hy2-sb") | .tls.certificate_path) = env.ACME_CERT_VALUE |
      (.inbounds[] | select(.tag == "hy2-sb") | .tls.key_path) = env.ACME_KEY_VALUE
    ' "$SB_CONFIG" > "$acme_config" || return 1
    chmod 600 "$acme_config" || return 1
    SB_CONFIG=$acme_config
    repair_acme_certificate_from_storage(){ return 1; }
    try_repair_config_source "$SB_CONFIG" "ACME fallback fixture" || return 1
    cert_path=$(jq -er '.inbounds[] | select(.tag == "hy2-sb") | .tls.certificate_path' \
      "$SB_CONFIG") || return 1
    key_path=$(jq -er '.inbounds[] | select(.tag == "hy2-sb") | .tls.key_path' \
      "$SB_CONFIG") || return 1
    [[ $cert_path == "$SB_DIR/cert.pem" && $key_path == "$SB_DIR/private.key" ]] || return 1
    [[ $REPAIR_CERT_FELL_BACK -eq 1 ]]
  )
}

damaged_original_config_is_not_reactivated(){
  (
    local broken="$SB_DIR/.sb.json.before-repair.broken" retained="$TEMP_DIR/retained-repair.json"
    printf '%s\n' '{broken' > "$broken" || return 1
    chmod 600 "$broken" || return 1
    cp -p -- "$SB_CONFIG" "$retained" || return 1
    initialize_repair_report
    REPAIR_TRANSACTION_ACTIVE=1
    REPAIR_CONFIG_CHANGED=1
    REPAIR_CONFIG_BACKUP=$broken
    cleanup_repair_temporary_files(){ return 0; }
    abort_repair_transaction || return 1
    [[ $REPAIR_ROLLBACK_STATE == not_available ]] && cmp -s -- "$SB_CONFIG" "$retained"
  )
}

optional_dependency_failure_occurs_after_core_service_recovery(){
  (
    local repair_status order=
    begin_repair_transaction(){ return 0; }
    installed_core_is_current(){ return 0; }
    repair_or_restore_config(){ return 0; }
    repair_managed_service(){ order="${order}service "; return 0; }
    commit_repair_transaction(){ return 0; }
    save_last_good_config(){ return 0; }
    repair_managed_permissions(){ return 0; }
    dependencies_ready(){ return 1; }
    install_dependencies(){ order="${order}maintenance "; return 1; }
    update_shortcut(){ return 0; }
    config_uses_acme_certificate(){ return 1; }
    ensure_acme_renew_cron(){ return 0; }
    cronsb(){ return 0; }
    refresh_share_files_after_change(){ return 0; }
    show_repair_report(){ :; }
    if repair_singbox_locked; then repair_status=0; else repair_status=$?; fi
    [[ $repair_status -eq 1 && $order == "service maintenance " &&
       $REPAIR_SERVICE_ACTION == "服务定义已重写并确认运行" &&
       $REPAIR_DEPENDENCY_ACTION == "核心服务可用；部分维护依赖仍不可用" ]]
  )
}

repairable_service_without_node_data_reaches_repair(){
  (
    local repair_reached=0
    managed_directory_is_owned(){ return 0; }
    managed_install_data_present(){ return 1; }
    service_definition_is_repairable(){ return 0; }
    service_name_conflict(){ return 1; }
    core_dependencies_ready(){ return 0; }
    with_lifecycle_acme_lock(){ repair_reached=1; return 0; }
    readp(){ return 0; }
    repair_singbox >/dev/null 2>&1 || return 1
    [[ $repair_reached -eq 1 ]]
  )
}

service_only_transaction_abort_restores_original_stack(){
  (
    local restore_called=0
    initialize_repair_report
    REPAIR_TRANSACTION_ACTIVE=1
    REPAIR_ORIGINAL_STACK_VALID=1
    REPAIR_SERVICE_CHANGED=1
    restore_original_repair_stack(){
      restore_called=1
      REPAIR_ROLLBACK_STATE=original_restored
      return 0
    }
    cleanup_repair_temporary_files(){ return 0; }
    abort_repair_transaction || return 1
    [[ $restore_called -eq 1 && $REPAIR_TRANSACTION_ACTIVE -eq 0 &&
       $REPAIR_TRANSACTION_FINALIZING -eq 0 ]]
  )
}

repairable_active_service_definition_is_restored(){
  (
    local case_dir="$TEMP_DIR/repairable-service-rollback"
    local source_core=$SB_BIN source_config=$SB_CONFIG original_service
    SB_DIR="$case_dir/sb"
    SB_CONFIG="$SB_DIR/sb.json"
    SB_LAST_GOOD="$SB_DIR/sb.json.last-good"
    SB_BIN="$SB_DIR/sing-box"
    SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
    CORE_DOWNLOAD_TEMP_DIR=
    SYSTEMD_UNIT="$case_dir/systemd/sb.service"
    OPENRC_UNIT="$case_dir/openrc/sb"
    mkdir -p "$SB_DIR" "${SYSTEMD_UNIT%/*}" "${OPENRC_UNIT%/*}" || return 1
    cp -- "$source_core" "$SB_BIN" || return 1
    cp -- "$source_config" "$SB_CONFIG" || return 1
    chmod 755 "$SB_BIN" || return 1
    chmod 600 "$SB_CONFIG" || return 1
    printf '%s\n' 'managed_by=sb.sh' 'identity=sb' 'directory=/etc/sb' > "$SB_MANAGED_MARKER" || return 1
    chmod 600 "$SB_MANAGED_MARKER" || return 1
    original_service="$case_dir/original.service"
    printf '%s\n' '# Managed by sb.sh' 'ExecStart=/broken' > "$original_service" || return 1
    cp -- "$original_service" "$SYSTEMD_UNIT" || return 1
    chmod 600 "$original_service" "$SYSTEMD_UNIT" || return 1
    systemd_service_has_other_units(){ return 1; }
    systemd_service_has_dropins(){ return 1; }
    systemctl(){ return 0; }
    service_is_active(){ return 0; }
    restartsb(){ return 0; }
    cleanup_core_download_temp(){ return 0; }
    service_exists && return 1
    service_definition_is_repairable || return 1
    initialize_repair_report
    begin_repair_transaction || return 1
    [[ $REPAIR_ORIGINAL_STACK_VALID -eq 1 && -f $REPAIR_SERVICE_BACKUP ]] || return 1
    cmp -s -- "$original_service" "$REPAIR_SERVICE_BACKUP" || return 1
    printf '%s\n' '# Managed by sb.sh' 'ExecStart=/rewritten' > "$SYSTEMD_UNIT" || return 1
    chmod 600 "$SYSTEMD_UNIT" || return 1
    REPAIR_SERVICE_CHANGED=1
    abort_repair_transaction || return 1
    [[ $REPAIR_ROLLBACK_STATE == original_restored ]] || return 1
    cmp -s -- "$original_service" "$SYSTEMD_UNIT"
  )
}

failed_target_config_activation_preserves_snapshot(){
  (
    local case_dir="$TEMP_DIR/failed-target-config" snapshot status
    SB_DIR="$case_dir/sb"
    SB_CONFIG="$SB_DIR/config-destination-directory"
    mkdir -p "$SB_DIR" "$SB_CONFIG" || return 1
    snapshot="$SB_DIR/.repair-target-config.fixture"
    printf '%s\n' 'new-node-config' > "$snapshot" || return 1
    chmod 600 "$snapshot" || return 1
    REPAIR_TARGET_CONFIG_SNAPSHOT=$snapshot
    REPAIR_RECOVERED_CONFIG=
    if restore_repair_target_config_snapshot "$snapshot"; then
      status=0
    else
      status=$?
    fi
    [[ $status -eq 2 && -z $REPAIR_TARGET_CONFIG_SNAPSHOT &&
       -f $REPAIR_RECOVERED_CONFIG && ! -L $REPAIR_RECOVERED_CONFIG &&
       $(<"$REPAIR_RECOVERED_CONFIG") == new-node-config &&
       ! -e $snapshot && -d $SB_CONFIG ]]
  )
}

repair_core_dependencies_include_flock(){
  local function_text
  function_text=$(awk '/^core_dependencies_ready\(\)\{/{inside=1} /^dependencies_ready\(\)\{/{inside=0} inside' \
    "$ROOT_DIR/src/80-lifecycle.sh")
  [[ -n $function_text ]] && grep -Eq '(^|[[:space:]])flock([[:space:]\\]|$)' <<< "$function_text"
}

repair_finalization_consumes_interrupt(){
  local handler_file="$TEMP_DIR/handle-repair-finalizing.sh"
  awk '
    /^handle_install_interrupt\(\)\{/ { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$ROOT_DIR/src/90-main.sh" > "$handler_file" || return 1
  (
    REPAIR_TRANSACTION_FINALIZING=1
    # shellcheck source=/dev/null
    source "$handler_file"
    trap handle_install_interrupt INT
    kill -s INT "$BASHPID"
    return 0
  )
}

repair_signal_restores_stack_and_cleans_temporary_files(){
  local signal=$1 case_dir="$TEMP_DIR/repair-signal-${1,,}"
  local handler_file="$TEMP_DIR/handle-repair-${1,,}.sh"
  local cleanup_file="$TEMP_DIR/cleanup-core-${1,,}.sh"
  local source_core=$SB_BIN source_config=$SB_CONFIG signal_status
  awk '
    /^handle_install_interrupt\(\)\{/ { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$ROOT_DIR/src/90-main.sh" > "$handler_file" || return 1
  awk '
    /^cleanup_core_download_temp\(\)\{/ { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$ROOT_DIR/src/00-bootstrap.sh" > "$cleanup_file" || return 1
  [[ -s $handler_file && -s $cleanup_file ]] || return 1
  if (
    SB_DIR="$case_dir/sb"
    SB_CONFIG="$SB_DIR/sb.json"
    SB_LAST_GOOD="$SB_DIR/sb.json.last-good"
    SB_BIN="$SB_DIR/sing-box"
    SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
    SB_SERVICE=sb
    SYSTEMD_UNIT="$case_dir/systemd/sb.service"
    OPENRC_UNIT="$case_dir/openrc/sb"
    SHORTCUT="$case_dir/bin/sb"
    ACME_HOME="$SB_DIR/acme"
    ACME_BIN="$ACME_HOME/acme.sh"
    ACME_CERT="$SB_DIR/acme-cert.pem"
    ACME_KEY="$SB_DIR/acme-private.key"
    ACME_IDENTITY="$SB_DIR/acme_server_name"
    ACME_RELOAD="$SB_DIR/acme_reload.sh"
    ACME_LIVE="$SB_DIR/acme-live"
    ACME_GENERATIONS="$ACME_LIVE/generations"
    ACME_CURRENT="$ACME_LIVE/current"
    mkdir -p "$SB_DIR" "${SYSTEMD_UNIT%/*}" "${OPENRC_UNIT%/*}"
    cp -- "$source_core" "$SB_BIN"
    cp -- "$source_config" "$SB_CONFIG"
    chmod 755 "$SB_BIN"
    chmod 600 "$SB_CONFIG"
    printf '%s\n' 'managed_by=sb.sh' 'identity=sb' 'directory=/etc/sb' > "$SB_MANAGED_MARKER"
    chmod 600 "$SB_MANAGED_MARKER"
    printf '%s\n' '# original managed service' > "$SYSTEMD_UNIT"
    chmod 600 "$SYSTEMD_UNIT"
    service_exists(){ return 0; }
    service_is_active(){ return 0; }
    restartsb(){ : > "$case_dir/service-restarted"; return 0; }
    systemctl(){ return 0; }
    # shellcheck source=/dev/null
    source "$cleanup_file"
    # shellcheck source=/dev/null
    source "$handler_file"
    initialize_repair_report
    begin_repair_transaction || exit 90
    [[ $REPAIR_ORIGINAL_STACK_VALID -eq 1 ]] || exit 91
    printf '%s\n' '#!/bin/bash' 'exit 1' > "$SB_BIN"
    chmod 755 "$SB_BIN"
    printf '%s\n' '{"changed":true}' > "$SB_CONFIG"
    chmod 600 "$SB_CONFIG"
    REPAIR_CORE_REPLACED=1
    REPAIR_CONFIG_CHANGED=1
    : > "$SB_DIR/.sing-box.signal"
    : > "$SB_DIR/.sb.json.repair.signal"
    # .reality-key.* / .public.key.* have no producer any more, but released
    # versions wrote them; the sweep must still clear pre-upgrade leftovers.
    mkdir "$SB_DIR/.reality-key.signal"
    CORE_DOWNLOAD_TEMP_DIR="$SB_DIR/.core.signal"
    mkdir "$CORE_DOWNLOAD_TEMP_DIR"
    trap handle_install_interrupt INT TERM HUP
    kill -s "$signal" "$BASHPID"
    exit 92
  ); then
    signal_status=0
  else
    signal_status=$?
  fi
  [[ $signal_status -eq 130 ]] || return 1
  cmp -s -- "$source_core" "$case_dir/sb/sing-box" || return 1
  cmp -s -- "$source_config" "$case_dir/sb/sb.json" || return 1
  [[ -f $case_dir/service-restarted ]] || return 1
  for pattern in .core.* .sing-box.* .sb.json.repair.* .sb.json.rebuild.* \
    .public.key.* .reality-key.* .repair-core-backup.* \
    .repair-service-backup.* .repair-old-* .repair-target-*; do
    compgen -G "$case_dir/sb/$pattern" >/dev/null && return 1
  done
  return 0
}

incomplete_managed_directory_is_adopted(){
  (
    local case_dir="$TEMP_DIR/incomplete-managed"
    mkdir -p "$case_dir"

    # (a) an empty directory left by an interrupt between mkdir and the marker rename
    SB_DIR="$case_dir/empty"
    SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
    mkdir -p "$SB_DIR"
    prepare_managed_directory && managed_directory_is_owned || return 1

    # (b) only a stray marker temporary survived
    SB_DIR="$case_dir/stray"
    SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
    mkdir -p "$SB_DIR"
    : > "$SB_DIR/.sb-managed.AbCdEf"
    prepare_managed_directory && managed_directory_is_owned || return 1

    # (c) foreign content is still refused, and left untouched
    SB_DIR="$case_dir/foreign"
    SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
    mkdir -p "$SB_DIR"
    printf '%s\n' keep-me > "$SB_DIR/foreign.txt"
    if prepare_managed_directory >/dev/null 2>&1; then return 1; fi
    [[ -f $SB_DIR/foreign.txt && ! -e $SB_MANAGED_MARKER ]] || return 1

    # (d) an existing but unrecognised marker is still refused, and left untouched
    SB_DIR="$case_dir/badmarker"
    SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
    mkdir -p "$SB_DIR"
    printf '%s\n' 'managed_by=someone-else' > "$SB_MANAGED_MARKER"
    if prepare_managed_directory >/dev/null 2>&1; then return 1; fi
    [[ $(cat "$SB_MANAGED_MARKER") == 'managed_by=someone-else' ]] || return 1
  )
}

interrupt_handler_restores_only_inflight_acme_state(){
  local handler_file="$TEMP_DIR/handle-acme-branch.sh"
  local case_dir="$TEMP_DIR/acme-branch" status=0
  awk '
    /^handle_install_interrupt\(\)\{/ { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$ROOT_DIR/src/90-main.sh" > "$handler_file" || return 1
  [[ -s $handler_file ]] || return 1
  mkdir -p "$case_dir"

  # (a) a recovery point merely discovered at startup must survive an interrupt
  (
    ACME_STATE_BACKUP="$case_dir/discovered"
    ACME_INFLIGHT_BACKUP=
    REPAIR_TRANSACTION_FINALIZING=0
    mkdir -p "$ACME_STATE_BACKUP"
    restore_acme_state_backup(){ printf '%s\n' restored >> "$case_dir/restored.log"; }
    cleanup_core_download_temp(){ return 0; }
    # shellcheck source=/dev/null
    source "$handler_file"
    trap handle_install_interrupt INT
    kill -s INT "$BASHPID"
    return 0
  ) >/dev/null 2>&1
  [[ ! -e $case_dir/restored.log && -d $case_dir/discovered ]] || status=1

  # (b) a recovery point created by the in-flight operation is still restored
  (
    ACME_STATE_BACKUP="$case_dir/inflight"
    ACME_INFLIGHT_BACKUP="$case_dir/inflight"
    REPAIR_TRANSACTION_FINALIZING=0
    mkdir -p "$ACME_STATE_BACKUP"
    restore_acme_state_backup(){ printf '%s\n' restored >> "$case_dir/restored.log"; }
    cleanup_core_download_temp(){ return 0; }
    # shellcheck source=/dev/null
    source "$handler_file"
    trap handle_install_interrupt INT
    kill -s INT "$BASHPID"
    return 0
  ) >/dev/null 2>&1
  [[ -s $case_dir/restored.log ]] || status=1

  return "$status"
}

legacy_vless_config_is_migrated(){
  (
    local case_dir="$TEMP_DIR/legacy-vless" action
    mkdir -p "$case_dir"
    jq --arg uuid "$uuid" '
      .inbounds += [{
        type: "vless", sniff: true, sniff_override_destination: true,
        tag: "vless-sb", listen: "::", listen_port: 443,
        users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
        tls: {enabled: true, server_name: "apple.com",
              reality: {enabled: true,
                        handshake: {server: "apple.com", server_port: 443},
                        private_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                        short_id: ["0123abcd"]}}
      }]
    ' "$SB_CONFIG" > "$case_dir/legacy.json" || return 1
    SB_CONFIG="$case_dir/legacy.json"
    REPAIR_CERT_FELL_BACK=0
    # the retired inbound must not make the config unusable as a repair source
    load_repair_config_values "$SB_CONFIG" || return 1
    config_contains_removed_protocol "$SB_CONFIG" || return 1
    try_repair_config_source "$SB_CONFIG" "已从当前节点参数重建标准配置" || return 1
    action=$REPAIR_CONFIG_ACTION
    # the inbound is gone, the node values survive, and the report says so
    jq -e '[.inbounds[] | select(.type == "vless")] | length == 0' "$SB_CONFIG" >/dev/null || return 1
    jq -e --arg uuid "$uuid"       'any(.inbounds[]; .tag == "hy2-sb" and .users[0].password == $uuid)'       "$SB_CONFIG" >/dev/null || return 1
    [[ $action == *VLESS* ]]
  )
}

hysteria2_only_config_is_preserved(){
  (
    local case_dir="$TEMP_DIR/hy2-only" action
    mkdir -p "$case_dir"
    # The 3.1.0 default shape: no Shadowsocks-2022 inbound at all.
    ss_entry_enabled=0
    port_ss=
    ss_password=
    render_server_config "$case_dir/hy2-only.json" || return 1
    chmod 600 "$case_dir/hy2-only.json"
    jq -e '[.inbounds[] | select(.tag == "ss-sb")] | length == 0' "$case_dir/hy2-only.json" >/dev/null || return 1
    SB_CONFIG="$case_dir/hy2-only.json"
    REPAIR_CERT_FELL_BACK=0
    load_repair_config_values "$SB_CONFIG" || return 1
    [[ $REPAIR_SS_ENABLED -eq 0 && -z $REPAIR_SS_PORT && -z $REPAIR_SS_PASSWORD ]] || return 1
    config_contains_removed_protocol "$SB_CONFIG" && return 1
    try_repair_config_source "$SB_CONFIG" "已从当前节点参数重建标准配置" || return 1
    action=$REPAIR_CONFIG_ACTION
    # repair must not invent an optional entry the operator never enabled
    jq -e '[.inbounds[] | select(.tag == "ss-sb")] | length == 0' "$SB_CONFIG" >/dev/null || return 1
    jq -e --arg uuid "$uuid" \
      'any(.inbounds[]; .tag == "hy2-sb" and .users[0].password == $uuid)' "$SB_CONFIG" >/dev/null || return 1
    jq -e '.route.final == "direct"' "$SB_CONFIG" >/dev/null || return 1
    [[ -n $action ]]
  )
}

pre_v3_socks_config_is_migrated(){
  (
    local case_dir="$TEMP_DIR/pre-v3-socks" action key
    mkdir -p "$case_dir"
    # Rebuild the pre-3.0.0 shape: a plaintext socks inbound where the
    # Shadowsocks-2022 inbound now lives.
    jq '
      .inbounds = [.inbounds[] | if .tag == "ss-sb" then
        {type: "socks", sniff: true, sniff_override_destination: true, tag: "socks5-sb",
         listen: .listen, listen_port: .listen_port,
         users: [{username: "sb", password: "Socks.Pass_Two-7890"}]}
      else . end]
    ' "$SB_CONFIG" > "$case_dir/pre-v3.json" || return 1
    SB_CONFIG="$case_dir/pre-v3.json"
    REPAIR_CERT_FELL_BACK=0
    load_repair_config_values "$SB_CONFIG" || return 1
    # the old shape carries no reusable key
    [[ $REPAIR_SOCKS_INBOUND -eq 1 && -z $REPAIR_SS_PASSWORD ]] || return 1
    config_contains_removed_protocol "$SB_CONFIG" || return 1
    try_repair_config_source "$SB_CONFIG" "已从当前节点参数重建标准配置" || return 1
    action=$REPAIR_CONFIG_ACTION
    jq -e '[.inbounds[] | select(.type == "socks")] | length == 0' "$SB_CONFIG" >/dev/null || return 1
    jq -e --arg uuid "$uuid" \
      'any(.inbounds[]; .tag == "hy2-sb" and .users[0].password == $uuid)' "$SB_CONFIG" >/dev/null || return 1
    # the replacement inbound carries a freshly minted, valid SS-2022 key
    key=$(jq -er '.inbounds[] | select(.tag == "ss-sb") | .password | select(type == "string")' "$SB_CONFIG") || return 1
    valid_ss_password "$key" || return 1
    [[ $action == *SOCKS5* && $action == *Shadowsocks-2022* ]]
  )
}

red(){ :; }
green(){ :; }
yellow(){ :; }
blue(){ :; }
white(){ :; }
valid_ipv4(){ [[ ${1-} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_ipv6(){ return 1; }
# Defined in src/00-bootstrap.sh, which this harness does not source.
server_listen_address(){ printf '%s\n' '::'; }
sanitize_location(){
  tr '\r\n\t' '   ' | sed 's/[[:cntrl:]]//g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-160
}

# shellcheck source=/dev/null
source "$ROOT_DIR/src/10-acme.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/20-ports.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/30-server-config.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/40-service.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/50-client-output.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/src/85-repair.sh"

export CORE_VERSION=1.10.7
export SS_METHOD="2022-blake3-aes-256-gcm"
export IPV6_SYSCTL_ROOT=/proc/sys/net/ipv6
export SB_DIR="$TEMP_DIR/sb"
export SB_CONFIG="$SB_DIR/sb.json"
export SB_LAST_GOOD="$SB_DIR/sb.json.last-good"
export SB_BIN="$SB_DIR/sing-box"
export SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
export SB_SERVICE=sb
export SYSTEMD_UNIT="$TEMP_DIR/systemd/sb.service"
export OPENRC_UNIT="$TEMP_DIR/openrc/sb"
export SHORTCUT="$TEMP_DIR/bin/sb"
export ACME_HOME="$SB_DIR/acme"
export ACME_BIN="$ACME_HOME/acme.sh"
export ACME_CERT="$SB_DIR/acme-cert.pem"
export ACME_KEY="$SB_DIR/acme-private.key"
export ACME_IDENTITY="$SB_DIR/acme_server_name"
export ACME_RELOAD="$SB_DIR/acme_reload.sh"
export ACME_STAGE="$ACME_HOME/sb-stage"
export ACME_STAGE_CERT="$ACME_STAGE/fullchain.pem"
export ACME_STAGE_KEY="$ACME_STAGE/private.key"
export ACME_LIVE="$SB_DIR/acme-live"
export ACME_GENERATIONS="$ACME_LIVE/generations"
export ACME_CURRENT="$ACME_LIVE/current"
mkdir -p "$SB_DIR" "${SYSTEMD_UNIT%/*}" "${OPENRC_UNIT%/*}" "${SHORTCUT%/*}"
printf '%s\n' 'managed_by=sb.sh' 'identity=sb' 'directory=/etc/sb' > "$SB_MANAGED_MARKER"
chmod 600 "$SB_MANAGED_MARKER"

cat > "$SB_BIN" <<'MOCKCORE'
#!/bin/bash
case ${1-} in
  version) printf '%s\n' 'sing-box version 1.10.7' ;;
  check) jq -e . "${3-}" >/dev/null 2>&1 ;;
  *) exit 2 ;;
esac
MOCKCORE
chmod 755 "$SB_BIN"

uuid=123e4567-e89b-42d3-a456-426614174000
# Values below are consumed through Bash dynamic scope by render_server_config.
# The Shadowsocks-2022 entry is optional and off by default; this fixture keeps it
# enabled so the preservation path stays covered.
# shellcheck disable=SC2034
ss_entry_enabled=1
# shellcheck disable=SC2034
port_ss=1080
# shellcheck disable=SC2034
port_hy2=8443
ss_password=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
# shellcheck disable=SC2034
ipv=prefer_ipv4
# shellcheck disable=SC2034
certificatec_hy2="$SB_DIR/cert.pem"
# shellcheck disable=SC2034
certificatep_hy2="$SB_DIR/private.key"
render_server_config "$SB_CONFIG" || fail "cannot create repair fixture"
chmod 600 "$SB_CONFIG"

expect_success "managed directory with a foreign owner is rejected" \
  rejects_simulated_foreign_owner "$SB_DIR" managed_directory_is_owned
expect_success "managed marker with a foreign owner is rejected" \
  rejects_simulated_foreign_owner "$SB_MANAGED_MARKER" managed_directory_is_owned
expect_success "managed core with a foreign owner is rejected before execution" \
  rejects_simulated_foreign_owner "$SB_BIN" installed_core_is_current
expect_success "managed config with a foreign owner is rejected before core check" \
  rejects_simulated_foreign_owner "$SB_CONFIG" managed_config_file_is_valid "$SB_CONFIG"
expect_success "a directory at the core path is quarantined before core recovery" \
  repairs_core_path_that_is_a_directory
expect_success "an incomplete managed directory is adopted while foreign ones stay refused" \
  incomplete_managed_directory_is_adopted

expect_success "managed server values are extracted" load_repair_config_values "$SB_CONFIG"
[[ $REPAIR_UUID == "$uuid" &&
   $REPAIR_SS_PORT == 1080 && $REPAIR_HY2_PORT == 8443 &&
   $REPAIR_CERT_MODE == self_signed &&
   $REPAIR_SS_ENABLED == 1 && $REPAIR_SOCKS_INBOUND == 0 ]] ||
  fail "extracted repair values are incorrect"
pass "managed server extraction preserves node values"

canonical="$TEMP_DIR/canonical.json"
expect_success "canonical repair config is rendered" render_repair_config "$canonical"
jq -e --arg uuid "$uuid" --arg password "$ss_password" '
  any(.inbounds[]; .tag == "hy2-sb" and .users[0].password == $uuid) and
  any(.inbounds[]; .tag == "ss-sb" and .method == "2022-blake3-aes-256-gcm" and .password == $password)
' "$canonical" >/dev/null || fail "canonical repair changed node credentials"
pass "canonical repair keeps protocol credentials"

jq '(.inbounds[] | select(.tag == "hy2-sb") | .users[0].password) = "not-a-uuid"' \
  "$SB_CONFIG" > "$TEMP_DIR/mismatched.json"
expect_failure "a malformed Hysteria2 credential is rejected" \
  load_repair_config_values "$TEMP_DIR/mismatched.json"
jq '(.inbounds[] | select(.tag == "hy2-sb") | .tls.key_path) = "/tmp/key"' \
  "$SB_CONFIG" > "$TEMP_DIR/foreign-cert.json"
expect_failure "foreign certificate paths are rejected" \
  load_repair_config_values "$TEMP_DIR/foreign-cert.json"
jq '.inbounds += [.inbounds[] | select(.tag == "hy2-sb")]' \
  "$SB_CONFIG" > "$TEMP_DIR/duplicate.json"
expect_failure "duplicate managed inbounds are rejected" \
  load_repair_config_values "$TEMP_DIR/duplicate.json"

expect_success "self-signed repair certificate is generated" generate_self_signed_certificate
expect_success "generated self-signed certificate is valid" self_signed_certificate_is_valid

expect_success "last-good configuration is saved" save_last_good_config "$SB_CONFIG"
[[ -f $SB_LAST_GOOD && ! -L $SB_LAST_GOOD ]] || fail "last-good configuration is not regular"
pass "last-good configuration is a regular file"
case $(uname -s) in
  MINGW*|MSYS*) ;;
  *) [[ $(stat -c '%a' "$SB_LAST_GOOD") == 600 ]] || fail "last-good mode is not 600" ;;
esac
pass "last-good configuration is private"

printf '%s\n' '{broken' > "$SB_CONFIG"
expect_success "broken config is restored from last-good state" repair_or_restore_config
jq -e --arg uuid "$uuid" 'any(.inbounds[]; .tag == "hy2-sb" and .users[0].password == $uuid)' \
  "$SB_CONFIG" >/dev/null || fail "last-good restore changed the UUID"
pass "last-good restore preserves the UUID"
[[ -n $REPAIR_CONFIG_BACKUP && -f $REPAIR_CONFIG_BACKUP ]] ||
  fail "broken config was not preserved"
pass "broken config is preserved for inspection"

symlink_probe_target="$TEMP_DIR/symlink-probe-target"
symlink_probe="$TEMP_DIR/symlink-probe"
printf '%s\n' probe > "$symlink_probe_target"
if ln -s -- "$symlink_probe_target" "$symlink_probe" 2>/dev/null && [[ -L $symlink_probe ]]; then
  rm -f -- "$symlink_probe"
  expect_success "server IP symlink is replaced without following its target" \
    server_ip_symlink_is_replaced_without_following
  expect_success "SHA256 symlink is replaced without following its target" \
    sha256_symlink_is_replaced_without_following
else
  rm -f -- "$symlink_probe"
  skip "server IP symlink is replaced without following its target" "symlinks unavailable"
  skip "SHA256 symlink is replaced without following its target" "symlinks unavailable"
fi
expect_success "a directory at the server IP path is rejected and preserved" server_ip_directory_is_rejected
expect_success "a directory at the SHA256 path is rejected and preserved" sha256_directory_is_rejected
grep -Fq 'atomic_write_private_text "$SB_DIR/SHA256.txt" "$SHA256"' \
  "$ROOT_DIR/src/50-client-output.sh" || fail "SHA256 output bypasses the atomic writer"
pass "share generation routes SHA256 output through the atomic writer"

expect_success "valid ACME certificate remains active when maintenance components fail" \
  valid_acme_certificate_survives_maintenance_failure

expect_success "unrecoverable ACME certificate falls back without losing node values" \
  unrecoverable_acme_certificate_falls_back_safely

printf '%s\n' '# Managed by sb.sh' 'ExecStart=/broken' > "$SYSTEMD_UNIT"
systemd_service_has_other_units(){ return 1; }
systemd_service_has_dropins(){ return 1; }
expect_success "damaged marked systemd unit is repairable" service_definition_is_repairable
printf '%s\n' '# foreign unit' > "$SYSTEMD_UNIT"
expect_failure "foreign systemd unit is not repairable" service_definition_is_repairable

initialize_repair_report
for report_value in "$REPAIR_CORE_ACTION" "$REPAIR_CONFIG_ACTION" "$REPAIR_CERT_ACTION" \
  "$REPAIR_SERVICE_ACTION" "$REPAIR_SHORTCUT_ACTION" \
  "$REPAIR_ACME_ACTION" "$REPAIR_CRON_ACTION" "$REPAIR_SHARE_ACTION" \
  "$REPAIR_PERMISSION_ACTION"; do
  [[ $report_value == "未执行" ]] || fail "repair report contains an empty default"
done
pass "repair report defaults are explicit"

cleanup_candidate="$SB_DIR/.sb.json.cleanup-test"
render_repair_config "$cleanup_candidate" || fail "cannot render cleanup candidate"
original_sb_config=$SB_CONFIG
SB_CONFIG="$TEMP_DIR/config-destination-directory"
mkdir "$SB_CONFIG"
expect_failure "failed repair config installation is rejected" \
  install_repair_config "$cleanup_candidate" "cleanup fixture"
[[ ! -e $cleanup_candidate ]] || fail "failed repair config candidate was not removed"
pass "failed repair config candidate is removed"
SB_CONFIG=$original_sb_config

expect_success "service failure never reactivates a known-damaged original config" \
  damaged_original_config_is_not_reactivated
expect_success "missing cron or qrencode cannot block core service recovery" \
  optional_dependency_failure_occurs_after_core_service_recovery
expect_success "a damaged managed service without node data can enter repair" \
  repairable_service_without_node_data_reaches_repair
expect_success "service-only repair failure restores the original stack" \
  service_only_transaction_abort_restores_original_stack
expect_success "repairable active service definition is backed up and restored" \
  repairable_active_service_definition_is_restored
expect_success "failed target config activation preserves the new node snapshot" \
  failed_target_config_activation_preserves_snapshot
expect_success "repair requires flock before entering its transaction" \
  repair_core_dependencies_include_flock
expect_success "repair finalization consumes interrupts without starting a second rollback" \
  repair_finalization_consumes_interrupt
expect_success "a legacy VLESS config is migrated and keeps its node values" \
  legacy_vless_config_is_migrated
expect_success "a pre-3.0.0 SOCKS5 config is migrated to Shadowsocks-2022" \
  pre_v3_socks_config_is_migrated
expect_success "a hysteria2-only config keeps no Shadowsocks-2022 inbound" \
  hysteria2_only_config_is_preserved
expect_success "interrupt restores only the in-flight ACME recovery point" \
  interrupt_handler_restores_only_inflight_acme_state
expect_success "INT restores the original stack and cleans repair temporaries" \
  repair_signal_restores_stack_and_cleans_temporary_files INT
expect_success "TERM restores the original stack and cleans repair temporaries" \
  repair_signal_restores_stack_and_cleans_temporary_files TERM
expect_success "HUP restores the original stack and cleans repair temporaries" \
  repair_signal_restores_stack_and_cleans_temporary_files HUP

repair_function=$(awk '/^repair_singbox_locked\(\)\{/{inside=1} /^repair_singbox\(\)\{/{inside=0} inside' \
  "$ROOT_DIR/src/85-repair.sh")
[[ -n $repair_function ]] || fail "repair orchestration cannot be extracted"
# shellcheck disable=SC2016
if grep -Fq 'cleanup_incomplete_install' <<< "$repair_function" ||
   grep -Fq 'rm -rf "$SB_DIR"' <<< "$repair_function"; then
  fail "repair orchestration still deletes the managed installation"
fi
pass "repair orchestration has no installation deletion path"
grep -Fq 'abort_repair_transaction' <<< "$repair_function" ||
  fail "repair orchestration does not abort its transaction after service failure"
grep -Fq 'restore_original_repair_stack' "$ROOT_DIR/src/85-repair.sh" ||
  fail "repair transaction cannot restore the original core and config stack"
pass "repair orchestration aborts through the full-stack transaction rollback"

printf '1..%d\n' "$passed"
