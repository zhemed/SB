# Version & Upstream Pin Synchronization

The project pins **every** external dependency. A version or digest change is a multi-file change,
and `tests/verify.sh` asserts the literal strings so a partial edit fails the gate rather than
shipping.

Run `bash tests/verify.sh` after any change in this document's scope.

---

## 1. Script version lives in four places

`VERSION` is the single source of truth; the other three are asserted against it.

| Location | Value form | Asserted by |
|----------|-----------|-------------|
| `VERSION` | `3.1.0` (bare semver, single trailing newline) | `scripts/build.sh:67-68`, `tests/verify.sh:50-51` |
| `src/00-bootstrap.sh:96` | `sb_version="v3.1.0"` | `scripts/build.sh:155-156`, `tests/verify.sh:48-49` |
| `README.md` "当前项目版本" line | `` 当前项目版本：`3.1.0` `` | `tests/verify.sh:52-53` |

The build derives the required literal from `VERSION` itself:

```bash
# scripts/build.sh:67-68
version=$(<"$VERSION_FILE")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must contain one semantic version"
```

```bash
# scripts/build.sh:155-156
[[ $(grep -Fxc -- "sb_version=\"v$version\"" "$candidate" || true) -eq 1 ]] ||
  fail "VERSION and sb_version do not match"
```

`VERSION` must be a regular file, not a symlink, and must contain exactly one semver
(`scripts/build.sh:64,68`).

### Version bump procedure

1. Write the new semver to `VERSION` (nothing else on the line).
2. Update `sb_version` in `src/00-bootstrap.sh`.
3. Update the "当前项目版本" line in `README.md`.
4. `bash scripts/build.sh && bash tests/verify.sh`.
5. `bash scripts/check-version-bump.sh` to confirm the rule below is satisfied.

### 推到 main 就必须升版

Pushing to `main` **is** a release: `sb.sh` is served from `main`, and installed hosts re-read it
through the shortcut fallback. So any change under `src/` or to the checked-in `sb.sh` must carry a
new `VERSION` in the same change, otherwise two different builds advertise the same version number
and a user cannot tell which one they have.

`scripts/check-version-bump.sh [base-ref]` enforces this (base defaults to `origin/main`, then
`HEAD^`). It also rejects a version that moves backwards. CI runs it before `tests/verify.sh`.

**This rule is not enforced by `tests/verify.sh`** — that gate must still run from a tarball or a
shallow copy, where there is no history to compare against, so the check lives in its own script
and gets its own CI step.

History note: before this guard existed, `051ac67` and `84975fd` were both labelled `2.0.0`, and one
of them carried a Clash default-routing regression. That is the failure mode the guard prevents.

`README.md` also points developers at this procedure for release checks.

---

## 2. Pinned upstream components

```bash
# src/00-bootstrap.sh:8-15
CORE_VERSION="1.10.7"
ACME_VERSION="3.1.4"
CORE_SHA256_AMD64="1951a078..."
CORE_SHA256_ARM64="15b43a0a..."
CORE_SHA256_ARMV7="691882d6..."
ACME_ARCHIVE_SHA256="e5f8e187..."
SS_METHOD="2022-blake3-aes-256-gcm"
IPV6_SYSCTL_ROOT="/proc/sys/net/ipv6"
```

`tests/verify.sh:27-38` pins the two versions and the four digests as literal lines — the exact
`grep -Fxc` count is 1 for each. Changing the sing-box version therefore means three digest updates,
not one.

`SS_METHOD="2022-blake3-aes-256-gcm"` is asserted at `tests/verify.sh:46-47`: the Shadowsocks-2022
cipher is intentionally fixed, and only its key is randomized. `IPV6_SYSCTL_ROOT` is pinned inside
the Shadowsocks-2022 integration list (`tests/verify.sh:95-129`, entries
`IPV6_SYSCTL_ROOT="/proc/sys/net/ipv6"` and `server_listen_address()`), so the sysctl root the listen
address is probed from is a gate-enforced literal too.

---

## 3. Download policy is enforced, not just documented

All upstream downloads must be HTTPS-only, digest-verified, and use the project's own archive URLs.

```bash
# src/00-bootstrap.sh:230-232
if ! curl --fail --location --proto '=https' --proto-redir '=https' --retry 2 \
  --connect-timeout 10 --max-time 180 -o "$archive" \
  "https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz"; then
```

`tests/verify.sh:39-45` asserts:

- the literal `--proto '=https' --proto-redir '=https'` policy string exists;
- the acme.sh source archive URL
  `https://codeload.github.com/acmesh-official/acme.sh/tar.gz/refs/tags/` exists;
- the string `--install-online` is **absent** — acme.sh's unverified online installer is
  deliberately not used.

The sing-box kernel is verified twice: the archive digest before extraction
(`src/00-bootstrap.sh:237-242`) and the extracted binary's reported version before and after the
atomic replacement (`src/00-bootstrap.sh:248-253`, `264-277`). Never relax these to "make install
work" — a digest mismatch means the download is wrong or tampered with.

---

## 4. Client-facing security settings are pinned strings too

`tests/verify.sh:211-225` pins secure-client defaults and **forbids** the insecure variants:

```
allow-lan: false
listen: "127.0.0.1:1053"
"insecure": false
skip-cert-verify: false
insecure=0&allowInsecure=0
```

and fails if `"insecure": true` or `skip-cert-verify: true` reappears. Changing client output
formatting is fine; weakening these values is a gate failure by design.

---

## 5. Protocol credentials are pinned

- Hysteria2 uses a UUID as its password; Shadowsocks-2022 uses a 44-character padded base64 key
  (32 raw bytes). The key is generated by `generate_ss_password` and accepted by `valid_ss_password`
  (`src/20-ports.sh:17-27`); the cipher is the pinned `SS_METHOD` constant
  (`src/00-bootstrap.sh:14`).
- `tests/verify.sh:153-158` extracts the `changeuuid()` body, bracketed by the neighbouring
  `change_ss_password()`, and fails if it mentions `ss-sb`, i.e. changing the UUID must not touch
  Shadowsocks-2022 credentials.
- The optional upstream credential lives in the state file `$SB_DIR/relay.conf` (mode 600, exactly
  three `server=` / `port=` / `password=` lines), written only through `save_relay_settings` →
  `atomic_write_private_text` (`src/40-service.sh:95-102`) and re-read by `render_server_config` on
  every render. `tests/verify.sh:95-129` requires `relay_settings_present()`,
  `load_relay_settings()`, `save_relay_settings()`, `"tag": "relay"`, `"final": "${route_final}"`
  and `relay.conf`.
- Neither Shadowsocks-2022 nor Hysteria2 may participate in automatic testing or load balancing. The
  generated client configuration contains **no** automatic-selection groups at all, and
  `tests/verify.sh` asserts their absence (`"type": "urltest"`, `"tag": "auto"`,
  `type: load-balance`, `type: url-test`, `负载均衡`, `自动选择`) plus that the sing-box proxy selector
  does not default to a removed group (`tests/verify.sh:160-173`), does not default to the
  Shadowsocks-2022 proxy (`:196-198`), and that the Clash select group defaults to the encrypted
  Hysteria2 proxy (`:199-209`).
- The Shadowsocks-2022 inbound is **optional** (3.1.0): a new install creates hysteria2 only. The
  gate proves that by extracting `insport` and failing if its body mentions `ss_password`, `port_ss`,
  `ss-sb` or `generate_ss_password` (`tests/verify.sh:152-161`), and by requiring
  `choose_ss_port()`, `ss_entry_is_enabled()`, `ss_entry_candidate_with_inbound()` and
  `ss_entry_candidate_without_inbound()`. When it is enabled, the inbound is TCP-only
  (`"network": "tcp"`, `src/30-server-config.sh:65`) because the UDP half of the shared port belongs
  to Hysteria2; `tests/verify.sh:229-234` requires the UDP block route (`"network": "udp"` from the
  `ss-sb` inbound) and the key-loss / clock warnings (`密钥不可推导`, `时间戳抗重放`).
  Whether that inbound should also carry UDP was evaluated and **rejected** in 2026-09 (see
  `.trellis/tasks/archive/2026-09/09-17-ss-entry-udp-eval/research.md`): an extra UDP port or moving
  hysteria2 off 443, the `quic`/`stun` block still eating most UDP, and — decisively — it cannot fix
  the "UDP is throttled" case the entry exists for. Revisit only if QUIC is specifically interfered
  with while plain UDP works, and reach for `udp_over_tcp` first.
- `tests/verify.sh:132-145` fails if the retired plaintext SOCKS5 integration comes back
  (`"tag": "socks5-sb"`, `"type": "socks"`, `type: socks5`, `SOCKS_USERNAME`,
  `valid_socks_password`, `change_socks_password`, `ressocks5`, `socks5.txt`) or if the dead
  comma-joined route rule `"network": "udp,tcp"` reappears.
- `tests/verify.sh:73-81` pins `SHORTCUT="/usr/bin/sb"` and requires the Cloudflare API Token prompt
  to be **visible** (`readp`), not hidden with `read -s`.

---

## Common mistakes

- Bumping `CORE_VERSION` without regenerating all three architecture digests.
- Bumping `VERSION` but forgetting `README.md` — `verify.sh` fails on the README assertion.
- Regenerating a digest by hashing a locally repacked archive instead of the upstream release asset.
- Editing `sb.sh` to fix a pin — the change is reverted by the next build. Edit `src/`.
