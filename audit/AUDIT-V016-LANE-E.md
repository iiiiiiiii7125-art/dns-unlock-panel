# Lane E — Adversarial Audit of the v0.1.6 P1 Fix

- **Worktree:** `~/workspace/dns-unlock-panel-v016`, branch `feature/v0.1.6-takeover`, tip `374e7b7`, base v0.1.5 (`main 817c606`)
- **P1 under audit:** "restore breaks system DNS". Fix = `e5dafe6` (stop the agent before restoring, so systemd-resolved can rebind its stub) + `ff006ca` (agent replies via IP_PKTINFO so queries to 127.0.0.53 are not discarded on source check).
- **Method:** read-only audit. Code review of all three copies of the restore script (verified identical for the P1 functions via `scripts/check-restore-sync.sh`, "双份来源一致", exit 0), `install.sh`, `uninstall.sh`, `internal/dnsagent/agent.go`. Live evidence from a purpose-built harness in the nspawn container (rootfs `/var/lib/machines/v016-test`, fake `systemctl` + a real answering stub on 127.0.0.53:53, real `dnsunlock` binaries built from tip `374e7b7` and from `ff006ca^`). Binaries: `/tmp/lane-e/dnsunlock-new` (sha256 `72d67c83…`), `/tmp/lane-e/dnsunlock-old` (sha256 `5d2e84eb…`). Full scenario logs: `/tmp/lane-e/scenarios5.log` (clean suite), `/tmp/lane-e/s-restart.log`, `/tmp/lane-e/nounit2.log`, `/tmp/lane-e/noipv6.log`.
- **Verdict on the core claim:** the fix works for its advertised case (unit-managed agent, wildcard `:53`, resolved present). RED reproduces the defect with the old code; GREEN proves the new code repairs it. **But the fix is narrower than the defect:** five further paths reproduce the same breakage, or break DNS through the fix's own new logic. Two are graded P1, three P2, one P3. All P0/P1 findings below carry red evidence (old code reproduces / new code fails live).

## Scenario table (all live, container, 2026-11-21)

| Scenario | Setup | Result |
|---|---|---|
| RED | old restore + old agent, `:53`, resolved yes | **Defect reproduced**: stub EADDRINUSE ×2, warnings, exit 0, agent alive |
| GREEN | new restore + new agent, `:53`, resolved yes | **PASS**: stub bound ×2, no warnings, agent dead, `dig +tcp @127.0.0.53` answers |
| SS-FALSEPOS | new restore, agent `127.0.0.1:53`, stub pre-started on .53 | **F-01**: abort exit 1, agent left stopped, DNS broken |
| NORESOLVED | new restore, agent `:53`, resolved no, backends=nm | **F-02**: false "resolved re-occupied :53" message, agent left stopped, :53 provably free |
| STOPFAIL | new restore, agent `:53`, `systemctl stop` forced to fail | **PASS**: exit 1 before any file change, agent alive and answering |
| SS-RESTART | new restore, agent `127.0.0.1:53`, no prestub | **PASS**: agent restarted after restore, stub and agent both answer |
| NOUNIT | new restore, new agent running with **no unit** | **F-03**: fix silently skipped, stub fails, exit 0, DNS broken |
| No-IPv6 | Go socket-family probe + setsockopt probe | **F-04**: `v6` misclassified on an IPv4 socket → pktinfo silently disabled (latent) |

---

## F-01 (P1) — The `:53` safety check aborts on listeners that do not conflict, after the agent is already stopped — restore leaves DNS broken

**Files:** `scripts/restore-resolv.sh:113-143` (`record_and_stop_agent`), identical in `internal/panel/assets/install.sh` and `scripts/install.sh`.

```bash
# restore-resolv.sh:129-143 (after systemctl stop already succeeded)
  if command -v ss >/dev/null 2>&1; then
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      if ! ss -tuln 2>/dev/null | grep -qE ':53[[:space:]]'; then return 0; fi
      sleep 1
    done
    echo "错误: agent 已停，但 :53 仍被占（可能是别的服务），还原已中止（未改任何文件）；请先处理占 :53 的服务后重跑" >&2
    exit 1
  fi
```

The grep matches **any** `:53` listener — including `127.0.0.53:53` (resolved's own stub) and any other non-conflicting address — even when the agent listens on a specific address (`127.0.0.1:53`) that cannot conflict with it. Worse, the check runs **after** the agent has already been stopped, and the abort path never reaches `restore_agent_after()`, so the agent is left stopped while `/etc/resolv.conf` still points at it.

**Red evidence** — SS-FALSEPOS (agent `127.0.0.1:53`, resolved's stub pre-started on 127.0.0.53:53), `/tmp/lane-e/scenarios5.log`:

```
restore exit code: 1
还原前 agent 在运行（监听 127.0.0.1:53），先停掉它再重启 systemd-resolved（否则 resolved 抢不到 :53 的 stub）...
错误: agent 已停，但 :53 仍被占（可能是别的服务），还原已中止（未改任何文件）；请先处理占 :53 的服务后重跑
agent: DEAD
resolv.conf: -rw-rw---- ... /etc/resolv.conf
nameserver 127.0.0.1
dig +tcp @127.0.0.53 example.com: 198.18.176.247      # the stub is alive and answering
dig +tcp @127.0.0.1 example.com: ;; Connection to 127.0.0.1#53(127.0.0.1) ... connection refused.
```

Before the restore, the agent answered `127.0.0.1` queries; after the abort, nothing answers it — the restore itself made DNS worse while refusing to proceed. The stub on `.53` is alive, but nothing re-points `resolv.conf` at it.

**Reachability:** needs a pre-existing `:53` listener plus a non-wildcard agent listen. Reachable whenever resolved was never disabled (a failed takeover, resolved re-enabled by an OS update or a manual restart) and the agent listens on `127.0.0.1:53`.

**Fix direction:** check for a *conflicting* listener (same address family / overlapping bind — wildcard vs. the agent's actual listen address), not any `:53`; and on abort, restart the agent you just stopped, or check *before* stopping it.

## F-02 (P2) — `restore_agent_after()` claims resolved re-occupied `:53` when resolved was never restarted; agent left stopped on a free port

**File:** `scripts/restore-resolv.sh:145-158` (`restore_agent_after`), wildcard branch:

```bash
    :53|0.0.0.0:53|[::]:53)
      echo "agent 还原前在运行（监听 $AGENT_LISTEN），现保持停止：systemd-resolved 已重新占用 :53（stub 127.0.0.53），agent 的通配符 :53 无法同时绑定。"
```

The message is keyed only on the listen string. It never verifies that resolved actually bound `:53` — on a machine without resolved (`backends=nm`, `resolved_active=no`) the branch still prints the claim, keeps the agent stopped, and leaves `resolv.conf` pointing at a stub that does not exist.

**Red evidence** — NORESOLVED (agent `:53`, `resolved=no`, `backends=nm`), `/tmp/lane-e/scenarios5.log`:

```
restore exit code: 0
agent 还原前在运行（监听 :53），现保持停止：systemd-resolved 已重新占用 :53（stub 127.0.0.53），agent 的通配符 :53 无法同时绑定。
agent: DEAD
stub bind 127.0.0.53:53: bindcheck: 127.0.0.53:53 udp+tcp bind OK (stub could bind)   # :53 is FREE
wildcard bind 0.0.0.0:53: bindcheck: 0.0.0.0:53 udp+tcp bind OK (stub could bind)
resolv.conf: lrwxrwxrwx ... /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf
nameserver 127.0.0.53
dig +tcp @127.0.0.53 example.com: ;; Connection to 127.0.0.53#53(127.0.0.53) ... connection refused.
dig +tcp @127.0.0.1 example.com: ;; Connection to 127.0.0.1#53(127.0.0.1) ... connection refused.
```

No `restart systemd-resolved` marker appears at all in this run (resolved was never enabled/restarted), yet the message asserts it re-occupied `:53`. The operator is actively misled into believing system DNS works when nothing listens on `.53` or `127.0.0.1`.

**Reachability:** any machine where the restore runs with resolved disabled/unavailable — a configuration the script explicitly supports (`backends=nm`). Graded P2 rather than P1 because the trigger is a non-default backend selection, not the default resolved path.

## F-03 (P2) — An agent running without a systemd unit is invisible to the fix; restore proceeds with `:53` held and fails exactly like pre-fix

**File:** `scripts/restore-resolv.sh:105-115`:

```bash
agent_unit_exists() {
  systemctl cat "$AGENT_UNIT.service" >/dev/null 2>&1 || \
    [ -f "/etc/systemd/system/$AGENT_UNIT.service" ] || \
    [ -f "/usr/lib/systemd/system/$AGENT_UNIT.service" ]
}
record_and_stop_agent() {
  AGENT_WAS_ACTIVE=0; AGENT_WAS_ENABLED=0; AGENT_LISTEN=""
  agent_unit_exists || return 0        # <-- silent return, no stop attempted
```

If the agent was started by hand (`dnsunlock dns-agent`), via another supervisor, or after its unit file was deleted, the gate fails and the restore runs the old, broken sequence: it rewrites `resolv.conf` to the stub target and restarts resolved while the agent still holds `:53`. There is no port-based fallback check anywhere in the fix.

**Red evidence** — NOUNIT demo, new restore + new agent, no unit (`systemctl cat dnsunlock-agent.service` forced to fail, unit file moved aside), `/tmp/lane-e/nounit2.log`:

```
unit file moved aside: 1; systemctl cat check:
  cat: FAIL (no unit, as intended)
agent pid 35385, ss:
udp   UNCONN 0      0                  *:53              *:*
tcp   LISTEN 0      0                  *:53              *:*
--- restore-new.sh output ---
警告: 重新启用 systemd-resolved 失败
警告: 重启 systemd-resolved 失败
已还原软链 /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf，并把备份内容写回目标 /run/systemd/resolve/stub-resolv.conf
已还原但验证未通过（getent hosts example.com 无结果，请检查 DNS 配置）
restore exit code: 0
agent: ALIVE pid 35385
restart systemd-resolved: STUB BIND FAILED (:53 held)
stubdns: UDP bind 127.0.0.53:53 FAILED: [Errno 98] Address already in use
resolv.conf: lrwxrwxrwx ... /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf
nameserver 127.0.0.53
```

No "先停掉它" message appears (the stop was never attempted). The failure signature is byte-identical to the pre-fix RED run. The container's unit file was restored afterwards (`unit file restored`).

**Reachability:** manual agent runs, custom supervisors, deleted unit files. Graded P2 because it needs the agent to run outside systemd; the failure mode, once reached, is the full P1.

## F-04 (P2, latent) — The agent derives the pktinfo family from the *address string*, not the *actual socket*; on an IPv4-only socket it silently disables pktinfo

**File:** `internal/dnsagent/agent.go:1168-1188` (`newUDPPktinfo`):

```go
func newUDPPktinfo(c *net.UDPConn, addr *net.UDPAddr) *udpPktinfo {
	p := &udpPktinfo{v6: addr.IP == nil || addr.IP.To4() == nil}
	...
	if p.v6 {
		setErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_RECVPKTINFO, 1)
	} else {
		setErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_PKTINFO, 1)
	}
	if setErr != nil {
		log.Printf("dns-agent: cannot enable pktinfo (%v); replies to 127.0.0.53 may be dropped on source check", setErr)
		return p        // active stays false; serveUDP falls back to plain WriteToUDP
	}
	p.active = true
```

For listen `:53`, `addr.IP` is nil, so `v6=true` unconditionally. That is correct when Go creates its usual dual-stack socket — but if the kernel cannot create `AF_INET6` sockets (IPv6 disabled, e.g. `ipv6.disable=1`), Go falls back to an `AF_INET` socket, and `IPV6_RECVPKTINFO` on that socket fails. The agent then degrades to plain replies with only a `log.Printf` nobody monitors — P1(b) silently unfixed.

**Evidence:**
- The common case is fine: a Go probe (`famprobe :53`) in a fresh netns with **zero** IPv6 addresses still binds a dual-stack `AF_INET6` socket (`family=10`, `udp6=true`, `[::]:53`). So this needs a kernel that cannot create `AF_INET6` at all, not merely a host without IPv6 addresses.
- The failure mode itself is proven live by a setsockopt probe on an `AF_INET` UDP socket (host sandbox, `/tmp/lane-e/probe/`):

```
IPV6_RECVPKTINFO on AF_INET socket: err=protocol not available (syscall errno 92)
IP_PKTINFO on AF_INET socket: err=<nil>
```

`ENOPROTOOPT` (92) is exactly the `setErr` that makes `newUDPPktinfo` return with `active=false`; `IP_PKTINFO` on the same socket would have worked had the code chosen the right branch.

**Reachability / boundary:** latent on normal hosts (dual-stack socket proven even with no IPv6 addresses assigned). Reachable only when the kernel cannot create `AF_INET6` sockets. No live agent run could be produced for that condition in this sandbox (the container shares the host kernel; it cannot be booted with IPv6 disabled) — the finding rests on the code plus the setsockopt probe, and is marked as such. Fix direction: derive `v6` from the socket's actual family (`Getsockname`) or fall back to `IP_PKTINFO` when `IPV6_RECVPKTINFO` fails.

## F-05 (P2) — Fail-open reporting: a restore that leaves the stub dead still exits 0, and `uninstall.sh` will then delete the agent

**Files:** `scripts/restore-resolv.sh:169-181` (`verify_after_restore`), `:220`, `:323`, `:326`, `:446-448`; `scripts/uninstall.sh:12-23`.

```bash
# restore-resolv.sh:220,323 — restart failures are warning-only
systemctl restart systemd-resolved 2>/dev/null || echo "警告: 重启 systemd-resolved 失败" >&2
systemctl enable --now systemd-resolved 2>/dev/null || echo "警告: 重新启用 systemd-resolved 失败" >&2
# verify_after_restore: every path returns 0; it never changes the exit code
verify_after_restore() { ... return 0 ... }
# main flow:
verify_after_restore
restore_agent_after
exit 0
```

**Red evidence** — RED run (old code, same reporting path as the new code — the new code did not change it), `/tmp/lane-e/scenarios5.log`:

```
restore exit code: 0
警告: 重新启用 systemd-resolved 失败
警告: 重启 systemd-resolved 失败
agent: ALIVE pid 33851
stub bind 127.0.0.53:53: bindcheck: udp 127.0.0.53:53 FAILED: [Errno 98] Address already in use
```

The restore *knows* the stub never bound (it printed both warnings) and still reports success. Downstream, `uninstall.sh:15` aborts only if the restore exits non-zero — so an uninstall after such a restore proceeds to `systemctl disable --now dnsunlock-agent` (line 23) and deletes the agent while system DNS is already broken. The same exit-0-with-dead-stub signature appears in the NOUNIT and NORESOLVED runs above.

**Fix direction:** make a failed resolved re-enable/restart a hard error (non-zero exit), or at minimum have `verify_after_restore` fail the run when the stub cannot be shown to answer.

## F-06 (P1) — The `--temp` exit path reproduces P1: the documented cleanup is `systemctl restart systemd-resolved` while the agent still holds `:53`

**Files:** `scripts/install.sh:459-490` (`apply_temp_dns`), `:482`, `:831-835`; `scripts/restore-resolv.sh:464-466`; rig S15 asserts the message.

```bash
# install.sh:472-482 — temp mode points DNS at the agent and never disables the stub
if [ -n "$iface" ] && resolvectl dns "$iface" 127.0.0.1 2>/dev/null; then
  echo "临时模式：已用 resolvectl 把 $iface 的 DNS 设为 127.0.0.1（agent）。"
...
echo "要立即还原：systemctl restart systemd-resolved（resolved 机器）或重新拉 DHCP ..."
# restore-resolv.sh:466 — the no-backup branch prescribes the same
echo "  - systemd-resolved 的机器：systemctl restart systemd-resolved（resolvectl 设的 DNS 即失效）"
```

Temp mode never writes `DNSStubListener=no`, never stops the agent, and takes no permanent backup. On a resolved machine, the normal temp sub-path (`resolvectl dns $iface 127.0.0.1`) leaves the stub enabled on `127.0.0.53:53` while the agent holds wildcard `:53`. Following the documented exit (`systemctl restart systemd-resolved`) makes resolved try to bind the stub while the agent holds the port — the identical bind conflict the P1 fix was built for — and the restart also clears the per-link `127.0.0.1` DNS, so after the restart neither the stub (bind failed) nor the agent (no longer referenced) answers system DNS.

**Red evidence (by mechanism equivalence + instruction text):** the bind-failure half is proven live by the RED run — a stub binding `127.0.0.53:53` fails with `EADDRINUSE` while the agent holds `:53` (markers `STUB BIND FAILED (:53 held)` ×2, `UDP bind 127.0.0.53:53 FAILED: [Errno 98] Address already in use`); the instruction text is quoted above from the shipped scripts, and the rig's S15 asserts the restore prints it. A literal temp-mode end-to-end run was not executed (it needs a `resolvectl` + NetworkManager environment the harness stubs do not model); the finding is therefore graded on the proven mechanism plus the shipped instruction, not on a full temp-mode run.

**Scope note:** the defect bites the `resolvectl` sub-path (the normal path on resolved machines). The direct-write fallback sub-path (`write_temp_resolv_conf`, when resolvectl fails or resolved is inactive) leaves `resolv.conf` as a plain `nameserver 127.0.0.1` file, which a resolved restart does not touch — that sub-path is not affected.

**Fix direction:** the temp-mode exit must stop the agent (or re-check the bind) before restarting resolved — the same ordering the P1 fix applies to the restore script — or the documented exit must be changed to `resolvectl revert` / restoring the previous per-link DNS without restarting resolved.

## F-07 (P3) — No locking between install and restore: a mid-restore agent (re)start re-creates P1, surfacing only as warnings

**Files:** `scripts/restore-resolv.sh`, `scripts/install.sh` — neither takes any lock (no `flock`, no lockfile) around the stop → rebind → restart sequence.

If the agent is (re)started — by `install.sh`, by `systemctl restart dnsunlock-agent`, or by the unit's `Restart=always, RestartSec=3` — in the window between `record_and_stop_agent` and resolved's rebind, resolved's bind fails exactly as in RED, and the failure surfaces only as the warning-only messages of F-05. Code-level finding; no live race was staged (timing-dependent, and staging it would require instrumenting the window). The window is normally seconds wide, but the `Restart=always` unit makes it reachable in principle whenever a stop is issued while the unit is enabled.

---

## Checked and cleared (verified, no finding)

- **P1(a) core mechanism:** Go UDP sockets do **not** set `SO_REUSEADDR` (probe `sockopt.go`: `ListenPacket`/`ListenUDP` → `SO_REUSEADDR=0`; TCP listener → `1`). A Go `bindhold` on `127.0.0.53:53` blocks a Go `bindprobe` on `:53` and a Python probe *with* `SO_REUSEADDR` — the agent's wildcard UDP socket is the binding constraint regardless of the other side's sockopts. This is why stop-first is necessary, and GREEN proves it sufficient for the unit-managed case.
- **P1(b) reply paths:** `pktprobe3.go` against the gateway `198.19.0.1:53` (connected sockets, the only UDP path the sandbox allows): with `IP_PKTINFO` only on a dual-stack socket the kernel delivers an `IP_PKTINFO` cmsg (`level=0 type=8`, dst `198.19.0.2`), `dstFromOOB` finds it, `WriteMsgUDP` with the IPv4 `replyOOB` returns `err=nil` and the second reply arrives; with `IPV6_RECVPKTINFO` only it delivers `IPV6_PKTINFO` (`level=41 type=50`, `::ffff:198.19.0.2`) and the v4-mapped `replyOOB` also succeeds. Control (neither) delivers `oobn=0`, `dst=nil`. So both the `:53` and the `0.0.0.0:53` listen forms produce correct-source replies for external-IP destinations. **Not re-proven here:** the literal `dig @127.0.0.53` UDP end-to-end (sandbox blocks loopback UDP entirely — see below); the parent context states the P1-fix verification did it in a test-machine container. Taken as stated, not independently re-confirmed.
- **TCP reply path:** unaffected by pktinfo (accepted-connection source = destination address). RED run: `dig +tcp @127.0.0.53 example.com` answers via the *old* agent (`104.20.23.154` / `172.66.147.243`) even though the stub never bound — the pre-fix breakage is UDP-only.
- **`forwardUDP` / `forwardTCP` / check mode:** client-side connected sockets (`net.DialTimeout`); no pktinfo needed. `grep WriteToUDP` finds only the two sites inside `serveUDP()`.
- **Panel-driven changes:** no `exec`/`systemctl` in the panel Go code — there is no panel-driven `:53` race.
- **install.sh re-run:** aborts fail-closed at `can_bind_listen` (line 621) while the agent runs (code).
- **Takeover's resolved restart** (`install.sh:900-901`): writes `DNSStubListener=no` *then* restarts resolved — the stub is being disabled, not re-enabled; no conflict (code).
- **STOPFAIL (live PASS):** forced `systemctl stop` failure → restore exits 1 before any file change; agent stays alive and answering (`dig +tcp @127.0.0.1` = `104.20.23.154`); `resolv.conf` unchanged (`nameserver 127.0.0.1`, regular file).
- **SS-RESTART (live PASS, previously untested branch):** agent on `127.0.0.1:53` is stopped, the stub binds `.53` (markers ×2, `dig +tcp @127.0.0.53` = `198.18.176.247`), and `restore_agent_after` restarts the agent (`agent 已恢复运行（监听 127.0.0.1:53）`, new pid 35868, `dig +tcp @127.0.0.1` = `172.66.147.243`). `/tmp/lane-e/s-restart.log`.
- **`0.0.0.0:53` listen form:** pktinfo delivery proven live (see P1(b) above); the `v6` computation is wrong for this form (`0.0.0.0` → `To4() != nil` → `v6=false`, sets `IP_PKTINFO` on a dual-stack socket) but the probe shows that combination still delivers the destination and replies correctly — a latent code smell, not a live defect.

## Rig FAILs adjudicated (not P1-fix findings)

The rig log on disk (`/var/lib/machines/v016-test/root/rig/logs/typescript`, ended 2026-11-21 11:39:15, exit 1) reads **PASS=125 FAIL=2** — not 126+1 as stated in the handoff summary; the on-disk typescript is authoritative for this session. The two FAILs:

- **S14 `verify_rule_domain 规则 IP 一致 → rc 0`:** not adjudicable from the log — the rig's `assert` swallows the function's own output, so the failure mode (rc 1 wrong-IP vs rc 2 skipped: no config / no address-mode rules) is not determinable. No P1-fix mechanism connects to it: `verify_rule_domain` (`scripts/install.sh:269`) resolves via `getent` with `options use-vc` (TCP), and the P1(b) fix touches only the UDP reply path while P1(a) touches only the restore script; the agent's rule lookup and TCP serving are unchanged by `e5dafe6`/`ff006ca`. Most likely rig-setup/sync causes (no address-mode rule in the panel at rig time, or rule not synced to the agent). No panel/agent processes remain running in the container, so S14 cannot be re-run without re-running the rig's setup — that belongs to the rig lane, with the function's output visible.
- **S9b `清理：还原回 hpve 文件`:** a cleanup-bookkeeping assertion about restoring the hpve-managed file; unrelated to the P1 fix (installer backup/restore bookkeeping, not the stop-first or pktinfo change).

**Process observation (not a product finding):** the rig's fake `restart systemd-resolved` only kills a `bindhold` process — it never attempts a real bind, so it cannot fail when `:53` is held. Rig green therefore proves the stop-then-check logic, not the P1(a) core claim (resolved actually rebinding). The container harness in this lane (real stub bind) was built to close exactly that gap.

## Harness artifacts and inference boundaries (read before re-using the numbers)

- **Sandbox UDP filter:** loopback UDP `sendto` → EPERM; unconnected UDP send → EPERM; connected UDP send works; IPv6-socket UDP send → EPERM. Consequences: `getent` (UDP) can never pass here even when DNS works — every "已还原但验证未通过" in the logs is a sandbox artifact, not a product failure; `dig` is always `+tcp`; the UDP half of P1(b) could not be demonstrated end-to-end in this sandbox.
- **Earlier RED stub-target anomaly — resolved, harness bug, not a product issue:** an early suite run showed the stub target file containing `nameserver 127.0.0.1` instead of `127.0.0.53`. Cause: the harness `setup()` wrote `/etc/resolv.conf` through a leftover symlink from the previous scenario, landing in the old stub target file. Fixed (`rm -f /etc/resolv.conf` before writing); the clean suite (`scenarios5.log`) shows correct content in all scenarios.
- **TIME_WAIT artifact — resolved, harness bug:** `stubdns.py` initially lacked `SO_REUSEADDR`, so its TCP bind failed against TIME_WAIT sockets left by earlier `dig +tcp @127.0.0.53` probes, making one GREEN run look red. `SO_REUSEADDR` was restored to the stub (matching systemd's `socket_address_listen()`, which sets `SO_REUSEADDR` before bind — verified from the systemd/elogind `socket-util.c` source); the clean suite is unaffected. Whether resolved's *stub* path specifically uses that helper was not directly verified (no resolved binary in the sandbox to inspect) — assumed, not proven.
- **bindcheck UDP quirk:** with `SO_REUSEADDR` on both sides, two UDP sockets *can* share the same specific `addr:port` — so the UDP half of `bindcheck.py` is meaningless when the stub itself holds the port; TCP is the discriminator in the postchecks.
- **Container state after this lane:** `/etc/resolv.conf` restored to its pre-session content (`nameserver 198.19.0.1`, regular file); `:53` free; no agent/stub processes left; `/etc/systemd/system/dnsunlock-agent.service` (present from another lane's rig run, dated 11:38) was moved aside for the NOUNIT demo and restored. `/root/lane-e/` in the container is left in place as the evidence record (harness + logs); host copy `/tmp/lane-e/` holds the same plus all scenario logs. The test-machine host was not touched beyond the earlier read-only check (panel `:8080` + agent `:53` on v0.1.5, binary `1084e5e9…`; Tailscale-managed `/etc/resolv.conf` untouched). Production panel `https://dns.0v0.baby` was never touched.
- **One exec call during this session returned `userConfirmationRequired: true, userConfirmationStatus: timed_out` although its output was delivered** — re-runs under that approval may need re-authorization.

## Suggested fix order (for the parent agent)

1. F-06 (temp exit) and F-01 (over-broad `:53` check) first — both are reachable on the default resolved path and both break DNS through documented or routine operations.
2. F-05 (fail-open exit code) together with either — it is what lets all of the above ship silently and lets `uninstall.sh` delete the agent afterwards.
3. F-03 (no-unit invisibility) and F-02 (false resolved message) next — narrower preconditions, same breakage class.
4. F-04 (IPv4-socket pktinfo) last — latent on normal hosts; cheap fix (derive the family from the socket, or fall back to `IP_PKTINFO`).
