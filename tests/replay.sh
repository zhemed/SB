#!/bin/bash
# Behavioral replay: drive the menu-level flows of sb.sh in a sandbox and compare
# everything they touch (return code, output, resulting config, leftovers) against
# the committed expectations in tests/replay/expected/.
#
# Why this exists: the unit/repair suites stub commit_config, the ownership checks and
# the install entry, so a green gate never proved that a flow still works. A refactor
# that renamed an argument or swallowed a return code passed every existing check and
# still broke four menu paths — this replay is what caught it.
#
# Usage:
#   bash tests/replay.sh            # compare against the committed expectations
#   bash tests/replay.sh --update   # rewrite the expectations (review the diff!)
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_DIR="$ROOT_DIR/tests/replay/expected"
UPDATE=0
[[ ${1-} == --update ]] && UPDATE=1

WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sb-replay.XXXXXX") || exit 1
trap 'rm -rf "$WORK_ROOT"' EXIT
FUNCS="$WORK_ROOT/functions.sh"

# Pull every function definition out of the generated script, keeping heredoc bodies
# (the ACME hook and the renewal runner live inside them).
extract_functions() {
  awk '
    function heredoc_tag(line, s) {
      if (!match(line, /<<-*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*/)) return ""
      s = substr(line, RSTART, RLENGTH)
      gsub(/^<<-*/, "", s)
      gsub(/['"'"'"]/, "", s)
      return s
    }
    {
      line = $0
      if (!in_function && match(line, /^[A-Za-z_][A-Za-z0-9_]*\(\)\{/)) { in_function = 1; print; next }
      if (in_function) {
        if (in_heredoc != "") {
          print
          if (line == in_heredoc) in_heredoc = ""
          next
        }
        tag = heredoc_tag(line)
        print
        if (tag != "") { in_heredoc = tag }
        else if (line == "}") { in_function = 0 }
      }
    }
  ' "$ROOT_DIR/sb.sh" > "$FUNCS"
  [[ -s $FUNCS ]]
}

# The sandbox: every external command the flows reach for is stubbed, everything they
# write lands under $WORK_ROOT/$flow.
run_flow() {
  local flow=$1
  local work="$WORK_ROOT/$flow"
  mkdir -p "$work" || return 1
  (
    cd "$work" || exit 1
    # shellcheck source=/dev/null
    source "$FUNCS"

    local -a answers=()
    local answer_index=0
    readp() {
      [[ $# -ge 2 ]] || return 1
      [[ $answer_index -ge ${#answers[@]} ]] && return 1
      printf -v "$2" '%s' "${answers[$answer_index]}"
      answer_index=$((answer_index + 1))
      return 0
    }
    confirm_yes() {
      local input
      readp "$1" input || return 1
      case "${input^^}" in "" | Y | YES) return 0 ;; *) return 1 ;; esac
    }
    red() { printf 'RED|%s\n' "$1"; }
    yellow() { printf 'YEL|%s\n' "$1"; }
    green() { printf 'GRN|%s\n' "$1"; }
    blue() { printf 'BLU|%s\n' "$1"; }
    white() { :; }

    SB_DIR="$work/etc/sb"
    SB_CONFIG="$SB_DIR/sb.json"
    SB_LAST_GOOD="$SB_DIR/sb.json.last-good"
    SB_BIN="$work/bin/sing-box"
    SB_SERVICE=sb
    SYSTEMD_UNIT="$work/etc/systemd/sb.service"
    SHORTCUT="$work/usr/bin/sb"
    SB_MANAGED_MARKER="$SB_DIR/.sb-managed"
    SOCKS_USERNAME=sb
    CORE_VERSION=1.10.7
    # 生产环境里这些全局量由 00-bootstrap 初始化；沙箱里照做，这样 set -u 下
    # 再冒出来的未绑定变量就是真问题。
    socks_password=
    socks_port=
    relay_server=
    relay_port=
    relay_password=
    ipv=prefer_ipv4
    mkdir -p "$SB_DIR" "$(dirname "$SB_BIN")" "$(dirname "$SYSTEMD_UNIT")" || exit 1
    chmod 700 "$SB_DIR"

    cat > "$SB_BIN" <<'CORE'
#!/bin/bash
case "${1-}" in
  check) exit "${FAKE_CHECK_RC:-0}" ;;
  version) echo 'sing-box version 1.10.7'; exit 0 ;;
  generate) echo 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; exit 0 ;;
esac
exit 0
CORE
    chmod 755 "$SB_BIN"

    cat > "$SB_CONFIG" <<'JSON'
{"log":{"level":"warn"},"inbounds":[{"type":"hysteria2","tag":"hy2-sb","listen":"::","listen_port":23456,"users":[{"password":"aaaaaaaa-1111-2222-3333-444444444444"}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"/tmp/x.crt","key_path":"/tmp/x.key","min_version":"1.3"}}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","rules":[]}}
JSON
    chmod 600 "$SB_CONFIG"

    sbactive() { return 0; }
    restartsb() { return 0; }
    service_is_active() { return "${FAKE_ACTIVE_RC:-0}"; }
    service_exists() { return 0; }
    refresh_share_files_after_change() { printf 'SHARE_REFRESH\n'; return 0; }
    print_socks_entry_share() { printf 'SHARE_PRINT\n'; return 0; }
    socks_entry_port() { jq -r '[.inbounds[] | select(.tag == "socks5-sb")][0].listen_port // empty' "$SB_CONFIG"; }
    socks_entry_password() { jq -r '[.inbounds[] | select(.tag == "socks5-sb")][0].users[0].password // empty' "$SB_CONFIG"; }
    port_conflict() { return "${FAKE_CONFLICT_RC:-1}"; }
    shuf() { printf '%s\n' "${FAKE_RANDOM_PORT:-34567}"; }
    generate_socks_password() { printf '%s\n' 'FIXEDSOCKS5PASSWORD1234567890'; }
    relay_settings_present() { [[ -f $SB_DIR/relay.conf ]]; }
    relay_config_path() { printf '%s\n' "$SB_DIR/relay.conf"; }
    relay_upstream_reachable() { return "${FAKE_REACHABLE_RC:-0}"; }
    save_last_good_config() { cp -f "$1" "$SB_LAST_GOOD" 2>/dev/null; return 0; }
    systemctl() { return 0; }
    crontab() { return 0; }

    case $flow in
      uuid_ok) answers=("aaaaaaaa-9999-8888-7777-666666666666" ""); run_fn=changeuuid ;;
      uuid_same) answers=("aaaaaaaa-1111-2222-3333-444444444444" ""); run_fn=changeuuid ;;
      uuid_bad) answers=("not-a-uuid" "0" ""); run_fn=changeuuid ;;
      uuid_cancel) answers=("0"); run_fn=changeuuid ;;
      socks_pw_ok) answers=("Socks.Pass_New-1234" ""); run_fn=change_socks_password ;;
      socks_pw_cancel) answers=("0"); run_fn=change_socks_password ;;
      sock_enable_random) answers=("1" ""); run_fn=enable_socks_entry ;;
      sock_enable_custom) answers=("2" "21000" ""); run_fn=enable_socks_entry ;;
      sock_enable_cancel) answers=("0"); run_fn=enable_socks_entry ;;
      sock_enable_commit_fail) answers=("1" "0"); run_fn=enable_socks_entry; FAKE_ACTIVE_RC=1 ;;
      sock_enable_rollback_fail) answers=("1" "0"); run_fn=enable_socks_entry; FAKE_ACTIVE_RC=1 ;;
      sock_disable_yes) answers=("" ""); run_fn=disable_socks_entry ;;
      sock_disable_no) answers=("n"); run_fn=disable_socks_entry ;;
      sock_disable_commit_fail) answers=("" ""); run_fn=disable_socks_entry; FAKE_ACTIVE_RC=1 ;;
      relay_set_ok) answers=("1.2.3.4" "1080" "Socks.Pass_One-234" ""); run_fn=set_relay_upstream ;;
      relay_set_cancel) answers=("0"); run_fn=set_relay_upstream ;;
      relay_clear_ok) answers=(""); run_fn=clear_relay_upstream ;;
      *) echo "unknown flow: $flow" >&2; exit 2 ;;
    esac

    if [[ $flow == sock_disable* || $flow == socks_pw* ]]; then
      jq '.inbounds += [{"type":"socks","tag":"socks5-sb","listen":"::","listen_port":20808,"users":[{"username":"sb","password":"Socks.Pass_Old-0000"}]}]' \
        "$SB_CONFIG" > "$SB_CONFIG.tmp" && mv -fT "$SB_CONFIG.tmp" "$SB_CONFIG"
    fi
    if [[ $flow == relay_clear* ]]; then
      printf 'server=9.9.9.9\nport=2080\npassword=Old.Pass_Value-567' > "$SB_DIR/relay.conf"
      chmod 600 "$SB_DIR/relay.conf"
      jq '.outbounds += [{"type":"socks","tag":"relay","server":"9.9.9.9","server_port":2080,"version":"5","username":"sb","password":"Old.Pass_Value-567","network":"tcp"}] | .route.final = "relay"' \
        "$SB_CONFIG" > "$SB_CONFIG.tmp" && mv -fT "$SB_CONFIG.tmp" "$SB_CONFIG"
    fi

    "$run_fn"
    echo "RC=$?"
    jq -S . "$SB_CONFIG" 2>&1
    printf 'RELAY_CONF=%s\n' "$([[ -f $SB_DIR/relay.conf ]] && tr '\n' ' ' < "$SB_DIR/relay.conf" || echo none)"
    printf 'LEFTOVERS=%s\n' "$(find "$SB_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
  )
}

normalize() {
  sed -E \
    -e "s|$WORK_ROOT/[A-Za-z0-9_]*(/[A-Za-z0-9_.-]*)*|<WORK>|g" \
    -e 's|\.[A-Za-z0-9]{6} |.<RAND> |g' \
    -e 's|f\.sh: line [0-9]+:|f.sh:|'
}

extract_functions || { echo "replay: cannot extract functions from sb.sh"; exit 1; }

FLOWS=(
  uuid_ok uuid_same uuid_bad uuid_cancel
  socks_pw_ok socks_pw_cancel
  sock_enable_random sock_enable_custom sock_enable_cancel
  sock_enable_commit_fail sock_enable_rollback_fail
  sock_disable_yes sock_disable_no sock_disable_commit_fail
  relay_set_ok relay_set_cancel relay_clear_ok
)

mkdir -p "$EXPECTED_DIR"
index=0
failures=0
for flow in "${FLOWS[@]}"; do
  index=$((index + 1))
  actual=$(run_flow "$flow" 2>&1 | normalize)
  expected_file="$EXPECTED_DIR/$flow.txt"
  if [[ $UPDATE -eq 1 ]]; then
    printf '%s\n' "$actual" > "$expected_file"
    printf 'ok %d - %s (updated)\n' "$index" "$flow"
    continue
  fi
  if [[ ! -f $expected_file ]]; then
    printf 'not ok %d - %s (no expectation; run with --update)\n' "$index" "$flow"
    failures=$((failures + 1))
    continue
  fi
  expected=$(cat "$expected_file")
  if [[ $actual == "$expected" ]]; then
    printf 'ok %d - %s\n' "$index" "$flow"
  else
    printf 'not ok %d - %s\n' "$index" "$flow"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed -n '1,12p' | sed 's/^/    /'
    failures=$((failures + 1))
  fi
done

printf '1..%d\n' "$index"
if [[ $failures -gt 0 ]]; then
  echo "replay: $failures flow(s) drifted from the recorded behaviour"
  exit 1
fi
echo "replay: $index flows match the recorded behaviour"
