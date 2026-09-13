# Service Management (systemd & OpenRC)

The script supports both init systems with the **same observable behaviour**. Every service-touching
function contains both branches, adjacent, and they must stay semantically identical.

---

## 1. Detection: `command -v apk`, not `systemctl`

Alpine implies OpenRC. The check is used consistently for the branch, never `systemctl --version`:

```bash
# src/40-service.sh:181-185
  if command -v apk >/dev/null 2>&1; then
    openrc_service_definition_is_repairable
  else
    systemd_service_definition_is_repairable "$SYSTEMD_UNIT"
  fi
```

Also at `src/40-service.sh:173`, `237`, `278`, `296`, `304`, `312`, `388` and
`src/80-lifecycle.sh:313`.

The one systemd-specific *probe* is a capability check for the core's dependencies, not a branch
selector (`systemd` + `/run/systemd/system`).

**The two init systems are mutually exclusive.** Presence of the other one's unit is treated as a
conflict, not as "both installed":

```bash
# src/40-service.sh:330-334 (abridged)
    systemd_service_definition_present "$SB_SERVICE" && return 1
    openrc_unit_is_owned "$OPENRC_UNIT" ...
  else
    [[ ! -e $OPENRC_UNIT && ! -L $OPENRC_UNIT ]] || return 1
```

---

## 2. Unit files

Both generators write a **dot-prefixed temporary inside the unit directory** so the init system
never observes a half-written unit, then rename:

```bash
# src/40-service.sh:191 / 210
    unit_tmp=$(mktemp "/etc/init.d/.${SB_SERVICE}.XXXXXX") || return 1
    unit_tmp=$(mktemp "/etc/systemd/system/.${SB_SERVICE}.service.XXXXXX") || return 1
```

Modes differ deliberately: OpenRC units are executables (700), systemd units are not (600).

```bash
# src/40-service.sh:205 / 233
    if ! chmod 700 "$unit_tmp" || ! mv -fT -- "$unit_tmp" "$OPENRC_UNIT"; then
    if ! chmod 600 "$unit_tmp" || ! mv -fT -- "$unit_tmp" "$SYSTEMD_UNIT"; then
```

Both carry the literal single line `# Managed by sb.sh` as the ownership marker, and the exec line
is fixed:

```
ExecStart=$SB_BIN run -c $SB_CONFIG
command="$SB_BIN"  +  command_args="run -c $SB_CONFIG"
```

Changing either string breaks the ownership check at `src/40-service.sh:96-98` / `143-145`, which
matches them with `grep -Fqx`.

---

## 3. Never trust an init-system exit code

Both init systems return success in situations that do not mean "done". The code re-reads state
instead:

```bash
# src/40-service.sh:296-297
    rc-update add "$SB_SERVICE" default >/dev/null 2>&1 ||
      rc-update show default 2>/dev/null | grep -qE "(^|[[:space:]])${SB_SERVICE}([[:space:]]|$)" || return 1
```

```bash
# src/40-service.sh:415-416
    systemctl disable "$SB_SERVICE" >/dev/null 2>&1 || true
    systemctl is-enabled "$SB_SERVICE" >/dev/null 2>&1 && failed=1
```

And always **sleep before judging liveness**:

```bash
# src/40-service.sh:308-309
  sleep 1
  service_is_active
```

Equivalent helper for plain restart, used by `commit_config`:

```bash
# src/40-service.sh:312-318
restartsb(){
  if command -v apk >/dev/null 2>&1; then
    rc-service "$SB_SERVICE" restart
  else
    systemctl restart "$SB_SERVICE"
  fi
}
```

---

## 4. Start-up must be verified, and self-clean on failure

`sbservice` validates the config, writes the unit, starts it, and then re-checks. A failure triggers
cleanup with **two distinct messages** depending on whether cleanup itself succeeded:

```bash
# src/40-service.sh:264-280 (abridged)
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
    ... same two-outcome pattern ...
```

Never report a bare "failed" when a cleanup ran — the user needs to know whether the system is clean.

---

## 5. Destructive cleanup accumulates failures

`cleanup_service` must attempt **every** step and report once, rather than bailing at the first
error:

```bash
# src/40-service.sh:402-422 (abridged)
cleanup_service(){
  local failed=0
  service_name_conflict && return 1
  if command -v apk >/dev/null 2>&1; then
    rc-service "$SB_SERVICE" stop >/dev/null 2>&1 || true
    service_is_active && return 1
    rc-update del "$SB_SERVICE" default >/dev/null 2>&1 || true
    rc-update show default ... && failed=1
    rm -f "$OPENRC_UNIT" || failed=1
    [[ ! -e $OPENRC_UNIT ]] || failed=1
  else
    ...
    systemctl daemon-reload >/dev/null 2>&1 || failed=1
  fi
  return "$failed"
}
```

Note `service_is_active && return 1` — a service that refuses to stop is a hard abort, because
continuing would delete the unit of a running service.

---

## 6. Ownership vs repairability

Ownership (`systemd_unit_is_owned`, `openrc_unit_is_owned`) means "this is our unit". Repairability
(`*_service_definition_is_repairable`) is stricter and excludes cases where rebuilding would destroy
user intent:

```bash
# src/40-service.sh:165-172 (abridged)
systemd_service_definition_is_repairable(){
  grep -Fqx '# Managed by sb.sh' "$unit" 2>/dev/null || return 1
  systemd_service_has_other_units "$SB_SERVICE" "$unit" && return 1
  systemd_service_has_dropins "$SB_SERVICE" && return 1
  [[ ! -e $OPENRC_UNIT && ! -L $OPENRC_UNIT ]]
}
```

**A systemd drop-in (`systemctl edit sb`) makes the unit owned but not repairable** — rebuilding the
unit would silently discard the operator's override. This distinction is why
`service_name_conflict` (`src/40-service.sh:326-331`) has three branches: a foreign unit is a
conflict, but an owned-or-repairable one is not.

The same rule applies inside the ACME reload hook, which refuses to restart a service it cannot
prove is ours (`src/10-acme.sh:686-703`, with an explicit comment about drop-ins at `:719-720`).

---

## 7. Reading state

```bash
# src/40-service.sh:320-326
service_is_active(){
  if command -v apk >/dev/null 2>&1; then
    rc-service "$SB_SERVICE" status >/dev/null 2>&1
  else
    systemctl is-active --quiet "$SB_SERVICE"
  fi
}
```

`is_installed` (`src/40-service.sh:337-339`) is the conjunction that gates the whole management menu:
`managed_directory_is_owned && service_exists && [[ -x $SB_BIN && -s $SB_CONFIG ]]`.

---

## Common mistakes

- Adding a service action to only one branch of the init-system `if`.
- Branching on `systemctl` availability instead of `command -v apk`, so an Alpine box with a stray
  systemd shim takes the wrong path.
- Trusting `rc-update del` / `systemctl disable` exit status instead of re-reading state.
- Judging `service_is_active` without the preceding `sleep 1`.
- Treating an owned-but-drop-in unit as repairable and clobbering the operator's override.
- Deleting the unit while the service is still running (`service_is_active && return 1` must come
  before `rm`).
- Writing the unit directly to its final path instead of a dot-prefixed temp in the same directory.
