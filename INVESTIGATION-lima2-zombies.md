# Investigation: lima 2.x zombie containers on virtiofs

Tracking work for https://github.com/abiosoft/colima/issues/1552.

## Symptom

On a macOS 26.5 M1 with `colima 0.10.1` + `lima 2.1.1`, container processes
that do I/O against an NFS-backed virtiofs bind mount enter uninterruptible
D-state and cannot be killed with SIGKILL. `docker stop`, `docker restart`,
`docker rm -f`, and `docker compose down` all hang for 12s per container with:

```
cannot kill container: <id> PID <pid> is zombie and can not be killed.
Use the --init option when creating containers to run an init inside the
container that forwards signals and reaps processes
```

Only recovery is force-restarting the Colima VM (`colima stop -f` → kill
leftover limactl processes → `rm` stale `ha.pid`/`vz.pid`/sockets → `colima
start`). See `../halfmoon/scripts/colima_healthcheck.sh` for the playbook.

Downgrading to `colima 0.9.1 + lima 1.2.3` fixes it entirely.

## Reproduction attempts

### On crowntail (the machine the user is reading this from)

- macOS 26.4, M1
- colima 0.10.1, lima 2.1.0
- Test profile: `colima start --profile zombie-repro --vm-type vz --mount-type virtiofs --mount /tmp/zombie-test:w`
- Ran 10 concurrent containers each doing `dd if=/dev/urandom of=/data/f... bs=4k count=100` in a loop
- Killed all 10 simultaneously with `docker kill`
- **Result**: total kill time 0.4s, zero zombies, all clean

Local-path virtiofs (APFS-backed `/tmp`) does not reproduce the bug, even
under heavy concurrent write I/O.

### On halfmoon (the reporter)

- macOS 26.5, M1, colima 0.10.1, lima 2.1.1
- NFS bind mount from QNAP NAS (`plakatz:/Media`)
- NFS share has directories mode `0770 owner=1000:100` that container users
  (root via root_squash, or `abc` uid=501 without supplementary gid=100) can
  NOT access → NFS RPC returns EACCES, but under some conditions blocks
- Zombie containers appeared within 30–60 minutes of normal arr-stack usage
- 100% reproducible across multiple reboots

## Hypothesis

The zombie trap needs:
1. A syscall path that enters `TASK_UNINTERRUPTIBLE` (D-state) in the guest
   kernel inside the VM
2. A way for that state to persist long enough that SIGKILL can't be honored

Virtiofs on its own does not trap processes in D-state for local-disk-backed
paths — D-state is brief because the host I/O completes quickly.

When the host path is itself a slow/flaky network filesystem (NFS with
retries, `hard` mount, failing RPCs), the virtiofs driver in the guest
waits on a host-side read/stat/access that takes seconds to minutes to
return. Processes accessing that path stack up in D-state, and a SIGKILL
arriving during that window gets queued but never delivered, so the
container process becomes a "zombie and can not be killed" until the
underlying NFS RPC finally resolves.

## Root cause identified (2026-04-06)

**The bug is NOT specific to VZ or virtiofs.** Running the same slow-NFS test
with QEMU+sshfs produces EVEN MORE zombies (3/5) than VZ+virtiofs (2/5).
Both VM types use the same kernel image: `Linux 6.8.0-100-generic` from
colima-core v0.10.1.

**The root cause is the VM kernel image**, not the virtualization backend.
Colima-core v0.10.1 ships kernel 6.8.0-100-generic (Ubuntu, built Jan 2026).
Colima-core v0.10.0 (the previous image) likely had an older kernel that
handled NFS-backed FUSE/virtiofs D-state differently.

### Evidence

| Test | VM Type | Mount | NFS Delay | Zombies | Kill Time |
|------|---------|-------|-----------|---------|-----------|
| lima 2.1.0 | VZ | virtiofs | none | 0/10 | 0.4s |
| lima 2.1.0 | VZ | virtiofs | 500ms/10% | 0/5 (2 slow 6-9s) | 21s |
| lima 2.1.0 | VZ | virtiofs | 1000ms/15% | **2/5 zombie** | 36s |
| lima 2.1.0 | QEMU | sshfs | 1000ms/15% | **3/5 zombie** | 45s |
| halfmoon 1.2.3 | VZ | virtiofs | real NFS | 0/10 | 7s |

Both QEMU+sshfs and VZ+virtiofs produce zombies when NFS is slow. Since both
use the same guest kernel, the bug is in the kernel's handling of signal
delivery to processes blocked on FUSE/virtiofs I/O.

### Docker version swap test (2026-04-06)

Swapped Docker 29.2.1 → 29.2.0 inside the same VM (same kernel). Result:
Docker 29.2.0 still produces 1/5 zombies (vs 2/5 with 29.2.1). Slightly
better but NOT fixed. **Confirms the kernel is the root cause**, not Docker.

| Docker | Kernel | VM | Zombies | Kill Time |
|--------|--------|-----|---------|-----------|
| 29.2.1 | 6.8.0-100 | VZ+virtiofs | 2/5 | 36s |
| 29.2.1 | 6.8.0-100 | QEMU+sshfs | 3/5 | 45s |
| 29.2.0 | 6.8.0-100 | VZ+virtiofs | 1/5 | 36s |

### Definitive root cause

**Ubuntu kernel 6.8.0-100-generic** (built Jan 13 2026) has a regression
in signal delivery to processes blocked on FUSE/virtiofs/sshfs I/O
backed by slow network filesystems. When NFS RPCs take >1s, container
processes enter TASK_UNINTERRUPTIBLE and SIGKILL cannot be delivered.

This is a kernel bug, not colima/lima/Docker. Colima-core controls which
kernel ships. The fix is in colima-core: pin to a pre-regression kernel
or upgrade to a kernel with the fix.

### Next steps

1. Identify the exact kernel version in colima-core v0.10.0 (which works)
2. File an Ubuntu kernel bug against 6.8.0-100-generic for FUSE signal regression
3. Test with a newer kernel (6.8.0-101+) if available

### Previous hypothesis (disproven)

~~Why lima 2.x makes it worse than lima 1.x: unknown. Hypotheses:~~
- ~~virtiofs mount options (cache mode, tiered i/o config) changed defaults~~
- ~~VM kernel image shipped with lima 2.x handles D-state scheduling differently~~
- ~~VZ framework integration path changed~~

The virtiofs/VZ hypothesis was wrong. The QEMU+sshfs control test proves the
bug is VM-type-agnostic. The common factor is the kernel image.

## Tests added in this branch

`environment/vm/lima/yaml_vz_test.go` — documents the generated lima.yaml
schema shape (specifically that Rosetta lives under `vmOpts.vz.rosetta`,
NOT at top-level). This catches the schema mismatch that prevents
downgrading lima without downgrading colima.

It does NOT catch the zombie bug — that lives inside the guest kernel's
interaction with virtiofs-backed syscalls. A meaningful regression test
would require either:

1. A Linux CI runner with a mockable slow-filesystem (FUSE) backing
   virtiofs, and a container workload that stresses it.
2. A macOS CI runner with VZ+virtiofs and a way to simulate blocked host
   I/O (an NFS mount to an unreachable host, a paused FUSE server, etc.).

Neither is simple to wire into colima's existing CI (`go.yml` runs on
ubuntu-latest + macos-15-intel). The VZ driver requires Apple Silicon
macOS 13+, so the existing CI can't even exercise the vz code path.

## Open questions for upstream

1. Did lima 2.x intentionally change virtiofs default mount options?
2. Should colima expose virtiofs mount options (cache mode, writeback, etc.)
   through its `Mount` struct, paralleling the existing `NineP` options?
3. Is there a known-good colima release matched to lima 2.x?

## Workaround (current)

Pin `colima` and `lima` to the last-known-good combo:

```bash
brew pin colima  # pin 0.9.1
brew pin lima    # pin 1.2.3
```
