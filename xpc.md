# XPC — Environment Reference

**XPC** is the shorthand for the container environment used in this project.
When the user says "xpc", refer to this profile for all assumptions about the runtime environment.

---

## Classification

**Unprivileged LXC (Linux Container)**
Likely hosted on a Proxmox or LXD-based VPS platform (e.g. DigitalOcean, Hetzner, Linode).
Behaves like a lightweight VM but shares the host kernel.

---

## Properties

### Init system
- PID 1 is **not** an init daemon — was `tail` at time of observation
- **No systemd**, no upstart, no sysvinit daemon running
- `systemctl` command is **not available**
- `service <name>` only works if the package ships a sysvinit script — most modern `.deb` packages (e.g. ThingsBoard) only ship systemd units and will show as "unrecognized service"
- Services must be started **directly** (e.g. launching JARs, using `pg_ctlcluster`, etc.)

### Privileges & kernel access
- Running as **root** inside the container namespace
- `sudo` is **not installed** (not needed — already root)
- **No iptables/netfilter access** — UFW and iptables fail with "Permission denied"
- **No kernel module loading** — `conntrack` and similar modules unavailable
- `sysctl` writes fail with "Read-only file system" — kernel params are locked by host
- Firewall must be managed at the **host/cloud provider level** (e.g. DigitalOcean Firewall panel)

### Resource visibility
- `/proc/meminfo` reports **host machine RAM**, not container allocation
  - Observed: 503GB reported, actual container allocation was 6GB
  - Always cap JVM heap and RAM-based calculations — do not trust `/proc/meminfo` at face value
- `/proc/cpuinfo` similarly reflects host CPU topology, not container vCPU limit

### Userspace
- Full **Ubuntu 22.04 LTS** root filesystem
- `apt`, `dpkg`, `wget`, `curl` all work normally
- Can create users, install packages, write to disk freely within the container
- Rootfs is **writable and persistent** — files survive process restarts

### Networking
- Outbound internet access works (apt, wget, curl confirmed)
- Inbound ports controlled by **host/cloud firewall**, not inside the container
- Cannot use UFW or iptables inside the container

### Storage
- Persistent writable rootfs (not a Docker-style overlay)
- Files and installed packages survive container restarts

---

## Implications for scripting & automation

| Concern | What to do in XPC |
|---|---|
| Starting services | Launch process directly as the appropriate user |
| Stopping services | Kill by PID file |
| Boot persistence | Cannot use systemd/sysvinit — container must be started with an entrypoint or external orchestration |
| Firewall | Skip UFW; instruct user to configure cloud firewall panel |
| RAM detection | Cap `/proc/meminfo` reads; ask user for actual allocation or default to conservative values |
| JVM heap | Hard cap at 8GB regardless of reported RAM |
| `sudo` | Never use `sudo` in scripts — already root |
| `systemctl` | Never use — use direct process control or `pg_ctlcluster` for PostgreSQL |
| `service` | Only use for packages confirmed to have sysvinit scripts |

---
