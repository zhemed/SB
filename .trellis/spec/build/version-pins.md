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
| `VERSION` | `5.0.0` (bare semver, single trailing newline) | `scripts/build.sh:67-68`, `tests/verify.sh:50-51` |
| `src/00-bootstrap.sh:113` | `sb_version="v5.0.0"` | `scripts/build.sh:155-156`, `tests/verify.sh:48-49` |
| `README.md` "当前项目版本" line | `` 当前项目版本：`5.0.0` `` | `tests/verify.sh:52-53` |

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
SOCKS_USERNAME="sb"
RELAY_METHOD="2022-blake3-aes-256-gcm"
IPV6_SYSCTL_ROOT="/proc/sys/net/ipv6"
```

`tests/verify.sh:27-38` pins the two versions and the four digests as literal lines — the exact
`grep -Fxc` count is 1 for each. Changing the sing-box version therefore means three digest updates,
not one.

`SOCKS_USERNAME="sb"` is asserted at `tests/verify.sh:46-47`: the SOCKS5 username is fixed and is
**not** randomized, unlike its password. `RELAY_METHOD="2022-blake3-aes-256-gcm"` covers the
*upstream* hop, which is still Shadowsocks-2022 (server-to-server); the client-facing entry became
SOCKS5 in 4.0.0 and is the only optional entry since 5.0.0. `IPV6_SYSCTL_ROOT` is pinned inside the integration list, so the sysctl root the
listen address is probed from is a gate-enforced literal too.

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

- Hysteria2 uses a UUID as its password; the optional **SOCKS5 entry** uses the fixed username
  `SOCKS_USERNAME="sb"` plus a random password generated by `generate_socks_password` and validated
  by `valid_socks_password` (16–128 characters of `[A-Za-z0-9._~-]`).
- The **upstream/relay hop is still Shadowsocks-2022** (`RELAY_METHOD="2022-blake3-aes-256-gcm"`,
  a 44-character padded base64 key validated by `valid_ss_password`). That is a server-to-server
  link with no client-compatibility constraint, which is why it kept the AEAD-2022 cipher when the
  client-facing entry went back to SOCKS5 in 4.0.0 — and why it is the one place `valid_ss_password`
  still applies after the entry itself was removed in 5.0.0.
- `tests/verify.sh` extracts the `changeuuid()` body, bracketed by the neighbouring
  `change_socks_password()`, and fails if it mentions `socks5-sb`, i.e. changing the UUID must not
  touch the entry's credentials.
- The optional upstream credential lives in the state file `$SB_DIR/relay.conf` (mode 600, exactly
  three `server=` / `port=` / `password=` lines), written only through `save_relay_settings` →
  `atomic_write_private_text` (`src/40-service.sh:95-102`) and re-read by `render_server_config` on
  every render. The gate requires `relay_settings_present()`, `load_relay_settings()`,
  `save_relay_settings()`, `"tag": "relay"`, `"final": "${route_final}"` and `relay.conf`.
- Neither entry may participate in automatic testing or load balancing. The generated client
  configuration contains **no** automatic-selection groups at all, the sing-box selector defaults to
  `hy2-<hostname>` (never to the plaintext entry), and the Clash select group is
  `[hysteria2, <optional entries…>, DIRECT]` with Hysteria2 first.
- The entry is **optional** since 3.1.0: a new install creates hysteria2 only. The gate proves that
  by extracting `insport` and failing if its body mentions `socks_password`, `port_socks5`,
  `socks5-sb` or `generate_socks_password`. When it is enabled, the inbound is TCP-only (sing-box's
  `socks` inbound has no `network` field at all — unlike `shadowsocks`, which listens on both unless
  `"network": "tcp"` is set, the trap that broke 3.0.0's first draft), and the gate requires the UDP
  block route (`"network": "udp"` from the `socks5-sb` inbound) plus the plaintext warning
  (`SOCKS5 不加密`). Whether that inbound should also carry UDP was evaluated and **rejected** in
  2026-09 (see `.trellis/tasks/archive/2026-09/09-17-ss-entry-udp-eval/research.md`).
- **5.0.0 removed the Shadowsocks-2022 entry outright**: 4.0.0 had preserved a pre-existing `ss-sb`
  inbound for one release as a transition, and that path (parsing, verbatim re-emission, and the
  menu [8] removal flow) is gone. What remains is a **read-only probe** (`retired_ss_entry_port`)
  plus two warnings — `render_server_config` says the entry it is about to drop is no longer
  supported, and the menu [8] landing page repeats it — because silently cutting people off is not
  acceptable. The gate bans the retired names (`preserved_entry_inbound`, `preserved_ss_*`,
  `remove_preserved_ss_entry`, `resss`, `REPAIR_PRESERVED_*`) so the compatibility layer cannot
  creep back, and `config_contains_removed_protocol` counts `ss-sb` as removed so repair rewrites
  such a config instead of calling it healthy. Background:
  `.trellis/tasks/archive/2026-09/09-20-socks5-vs-ss-eval/research.md` and
  `.trellis/tasks/archive/2026-09/09-20-drop-ss-entry-compat/design.md`.
- The dead comma-joined route rule `"network": "udp,tcp"` must stay gone.
- `tests/verify.sh` pins `SHORTCUT="/usr/bin/sb"` and requires the Cloudflare API Token prompt
  to be **visible** (`readp`), not hidden with `read -s`.

---

## Common mistakes

- Bumping `CORE_VERSION` without regenerating all three architecture digests.
- Bumping `VERSION` but forgetting `README.md` — `verify.sh` fails on the README assertion.
- Regenerating a digest by hashing a locally repacked archive instead of the upstream release asset.
- Editing `sb.sh` to fix a pin — the change is reverted by the next build. Edit `src/`.
