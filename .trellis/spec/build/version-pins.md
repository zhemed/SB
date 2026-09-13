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
| `VERSION` | `2.0.1` (bare semver, single trailing newline) | `scripts/build.sh:67-68`, `tests/verify.sh:50-51` |
| `src/00-bootstrap.sh:95` | `sb_version="v2.0.1"` | `scripts/build.sh:155-156`, `tests/verify.sh:48-49` |
| `README.md` "当前项目版本" line | `` 当前项目版本：`2.0.1` `` | `tests/verify.sh:52-53` |

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
(`scripts/build.sh:64`).

### Version bump procedure

1. Write the new semver to `VERSION` (nothing else on the line).
2. Update `sb_version` in `src/00-bootstrap.sh`.
3. Update the "当前项目版本" line in `README.md`.
4. `bash scripts/build.sh && bash tests/verify.sh`.

`README.md:90` also points developers at this procedure for release checks.

---

## 2. Pinned upstream components

```bash
# src/00-bootstrap.sh:8-14
CORE_VERSION="1.10.7"
ACME_VERSION="3.1.4"
CORE_SHA256_AMD64="1951a078..."
CORE_SHA256_ARM64="15b43a0a..."
CORE_SHA256_ARMV7="691882d6..."
ACME_ARCHIVE_SHA256="e5f8e187..."
SOCKS_USERNAME="sb"
```

`tests/verify.sh:27-38` pins **all seven** as literal lines — the exact `grep -Fxc` count is 1 for
each. Changing the sing-box version therefore means three digest updates, not one.

`SOCKS_USERNAME="sb"` is asserted at `tests/verify.sh:46-47`: the SOCKS5 username is intentionally
fixed and is **not** randomized, unlike its password.

---

## 3. Download policy is enforced, not just documented

All upstream downloads must be HTTPS-only, digest-verified, and use the project's own archive URLs.

```bash
# src/00-bootstrap.sh:211-213
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
(`src/00-bootstrap.sh:217-222`) and the extracted binary's reported version before and after the
atomic replacement (`src/00-bootstrap.sh:228-233`, `244-257`). Never relax these to "make install
work" — a digest mismatch means the download is wrong or tampered with.

---

## 4. Client-facing security settings are pinned strings too

`tests/verify.sh:136-150` pins secure-client defaults and **forbids** the insecure variants:

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

- Hysteria2 uses a UUID as its password; SOCKS5 has its own random password.
- `tests/verify.sh:113-118` extracts the `changeuuid()` body and fails if it mentions `socks5-sb`,
  i.e. changing the UUID must not touch SOCKS5 credentials.
- SOCKS5 must not participate in automatic testing or load balancing. The generated client
  configuration contains **no** automatic-selection groups at all, and `tests/verify.sh` asserts
  their absence (`"type": "urltest"`, `"tag": "auto"`, `type: load-balance`, `type: url-test`,
  `负载均衡`, `自动选择`) plus that the sing-box proxy selector does not default to a removed group.
- SOCKS5 is TCP-only and plaintext; `tests/verify.sh:152-155` requires the UDP block route and the
  `SOCKS5本身不加密` warning to remain.
- `tests/verify.sh:72-80` pins `SHORTCUT="/usr/bin/sb"` and requires the Cloudflare API Token prompt
  to be **visible** (`readp`), not hidden with `read -s`.

---

## Common mistakes

- Bumping `CORE_VERSION` without regenerating all three architecture digests.
- Bumping `VERSION` but forgetting `README.md` — `verify.sh` fails on the README assertion.
- Regenerating a digest by hashing a locally repacked archive instead of the upstream release asset.
- Editing `sb.sh` to fix a pin — the change is reverted by the next build. Edit `src/`.
