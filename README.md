# nixos-config

Declarative NixOS configuration for a multi-machine AMD desktop/laptop fleet.

> **Architecture Reference:** See [`nixos-architecture-reference-v3.md`](https://claude.ai/chat/nixos-architecture-reference-v3.md) for the full design document, all ADRs, and the operator decisions log.

------

## Fleet

| Host                 | Role                   | GPU           | Hibernate                    |
| -------------------- | ---------------------- | ------------- | ---------------------------- |
| `nix-desktop`        | Stationary workstation | AMD RDNA dGPU | Enabled                      |
| `nix-laptop`         | Portable               | AMD RDNA iGPU | Enabled (lid-close workflow) |
| *(future)* `nix-lxc` | Headless on Proxmox    | —             | N/A                          |

------

## Stack at a Glance

| Concern     | Technology                                                   |
| ----------- | ------------------------------------------------------------ |
| Boot        | systemd-boot                                                 |
| Encryption  | LUKS2 → LVM → BTRFS                                          |
| Compositor  | Hyprland (upstream flake, pinned to release tag)             |
| Shell / Bar | Quickshell (QML, upstream flake) — owns bar, OSDs, notifications |
| Theming     | Stylix (base16, system-wide)                                 |
| Secrets     | sops-nix (age backend, keys derived from SSH host keys)      |
| Disk layout | disko (declarative, per-host `disk-config.nix`)              |
| User config | Home Manager as NixOS module (atomic rebuilds)               |

------

## Repository Layout

```
flake.nix
flake.lock
.sops.yaml

hosts/
├── nix-desktop/
│   ├── default.nix
│   ├── hardware-configuration.nix
│   └── disk-config.nix
├── nix-laptop/
│   ├── default.nix
│   ├── hardware-configuration.nix
│   └── disk-config.nix
└── _lxc/                       # placeholder

modules/
├── system/                     # boot, storage, locale, users, networking, vpn, security, gc
├── desktop/                    # hyprland, audio, bluetooth, printing, fonts, stylix, mime, power, trash, peripherals
├── apps/                       # browsers, office, dev, media
└── virtualisation/             # libvirt, podman

home/                           # Home Manager modules
├── hyprland/
├── quickshell/                 # custom QML tree
├── walker/
├── kitty/
├── yazi/
├── neovim/
├── zsh/
├── starship/
└── fastfetch/

secrets/                        # sops-encrypted
├── common.yaml
├── nix-desktop.yaml
└── nix-laptop.yaml

overlays/
└── default.nix
```

------

## Key Design Decisions

| Decision          | Choice                                             | ADR    |
| ----------------- | -------------------------------------------------- | ------ |
| Home Manager mode | NixOS module (atomic rebuilds)                     | ADR-01 |
| Secrets           | sops-nix + age                                     | ADR-02 |
| Kernel            | `linuxPackages_latest` (best RDNA support)         | ADR-03 |
| Swap              | zram (primary) + `lv_swap` (hibernate target)      | ADR-04 |
| Boot loader       | systemd-boot (10 GiB ESP, rescue ISO capable)      | ADR-05 |
| Wallpaper daemon  | `awww` (animated, IPC-driven)                      | ADR-06 |
| Notifications     | Quickshell-native (`NotificationServer`) — no mako | ADR-07 |
| Greeter           | `greetd` + `regreet` (GTK4 under `cage`)           | ADR-08 |
| Launcher          | `walker` (Wayland-native, daemon mode)             | ADR-09 |
| Vulkan            | RADV only (Mesa)                                   | ADR-10 |
| Containers        | Podman rootless (`dockerCompat = true`)            | ADR-11 |
| Multi-monitor     | `kanshi` (laptop) / Hyprland directives (desktop)  | ADR-12 |
| Quickshell config | Custom from scratch — no vendored upstream         | ADR-13 |
| Theming           | Stylix (replaces catppuccin flake + nwg-look)      | ADR-14 |
| Lid / sleep       | `suspend-then-hibernate`, 30 min delay             | ADR-15 |
| Firewall          | `networking.firewall` + nftables backend           | ADR-16 |

------

## Prerequisites

- A machine that boots UEFI
- NixOS installer (or an existing NixOS system to rebuild from)
- An age key for sops-nix secret decryption (derived from the SSH host key via `ssh-to-age`)

------

## First-Time Install

### 1. Boot the NixOS installer

Download the NixOS ISO and boot it. (A rescue copy also lives on the ESP after install — see the architecture reference, *Bootable ISO on ESP*.)

### 2. Clone this repo

```bash
nix-shell -p git
git clone <gitea-url>/mboehme/nixos-config /mnt/etc/nixos
cd /mnt/etc/nixos
```

### 3. Partition and format with disko

```bash
sudo nix run github:nix-community/disko -- \
  --mode disko hosts/<hostname>/disk-config.nix
```

This creates: GPT → LUKS2 → LVM (`vg_system`) → BTRFS subvolumes, exactly as declared.

### 4. Generate hardware config

```bash
sudo nixos-generate-config --no-filesystems --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix hosts/<hostname>/
```

### 5. Provision the sops age key

```bash
# Derive the age key from the machine's SSH host key (generated during install)
ssh-to-age -i /mnt/etc/ssh/ssh_host_ed25519_key.pub
# Add the output public key to .sops.yaml under the host's entry, then re-encrypt secrets:
sops updatekeys secrets/<hostname>.yaml
```

### 6. Install

```bash
sudo nixos-install --flake .#<hostname>
```

### 7. Reboot

```bash
sudo reboot
```

------

## Day-to-Day Workflow

### Apply changes

```bash
# Dry build (no activation):
nixos-rebuild build --flake .#<hostname>

# Test without setting as default boot entry (safe for risky changes):
sudo nixos-rebuild test --flake .#<hostname>

# Apply and set as default:
sudo nixos-rebuild switch --flake .#<hostname>

# Roll back if something breaks:
sudo nixos-rebuild switch --rollback
```

### Deploy to the peer machine

```bash
ssh nix-laptop 'cd /etc/nixos && git pull'
ssh nix-laptop 'sudo nixos-rebuild switch --flake .#nix-laptop'
```

### Update flake inputs

```bash
# Update all inputs:
nix flake update

# Update a single input (e.g. after a Hyprland release):
nix flake update hyprland

# Always review hyprland release notes before bumping — breaking config
# changes have shipped within minor versions.
```

### Garbage collect

```bash
# Manual sweep (automated weekly via nix.gc):
sudo nix-collect-garbage --delete-older-than 30d
sudo /run/current-system/bin/switch-to-configuration boot  # prune boot entries
```

### Edit secrets

```bash
sops secrets/common.yaml
sops secrets/nix-desktop.yaml
sops secrets/nix-laptop.yaml
```

------

## Storage Layout (per host)

```
/dev/diskX p1  →  10 GiB  vfat   /boot          (systemd-boot + kernels + rescue ISO)
/dev/diskX p2  →  100%    LUKS2  /dev/mapper/cryptroot

cryptroot
└── vg_system
    ├── lv_swap  (RAM + 2 GiB)  swap            (hibernate target, encrypted)
    └── lv_root  (100% free)    BTRFS
        ├── @root       /
        ├── @nix        /nix
        ├── @home       /home
        ├── @var-log    /var/log          (nodatacow)
        ├── @var-lib    /var/lib
        ├── @vms        /var/lib/libvirt  (nodatacow — VM images)
        ├── @gitea      /var/lib/gitea
        └── @snapshots  /.snapshots
```

------

## Theming (Stylix)

Stylix drives the colour scheme, fonts, cursor, icons, and ~30 program themes from a single base16 YAML. To change the scheme:

```nix
# modules/desktop/stylix.nix
stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";
# or derive from wallpaper:
# stylix.image = ./wallpaper.png;
```

Quickshell is not a Stylix target. The palette is bridged via:

```
config.lib.stylix.colors  →  palette.json  →  xdg.configFile."quickshell/theme/palette.json"
                                              →  theme/Palette.qml singleton
```

------

## Notifications

Notifications are owned by Quickshell (`Quickshell.Services.Notifications.NotificationServer`). **mako, swaync, and dunst must not be installed** — two daemons cannot hold `org.freedesktop.Notifications` simultaneously.

Verify ownership after a rebuild:

```bash
busctl --user introspect org.freedesktop.Notifications /org/freedesktop/Notifications
```

The bus name owner must be Quickshell.

------

## Security Notes

- Disk encryption: LUKS2. Passphrase entered at boot.
- Secrets in repo: sops-nix (age backend). Private keys never committed.
- Firewall: `networking.firewall` with nftables backend. Default deny inbound.
- SSH server: `nix-desktop` only. Password auth disabled. Key-only.
- Hibernate image: encrypted (inherits LUKS — no plaintext swap on disk).
- hyprlock PAM: `security.pam.services.hyprlock = {};` is declared. Without it, hyprlock rejects every password.

------

## Backup Strategy

| Source                        | Tool                    | Cadence        | Destination                     |
| ----------------------------- | ----------------------- | -------------- | ------------------------------- |
| `@home`, `@var-lib`, `@gitea` | btrbk → BTRFS snapshots | Hourly + daily | `@snapshots` (local)            |
| Local snapshots               | restic over SSH         | Daily          | Proxmox restic repo (encrypted) |
| `flake.nix` + modules         | git                     | Per change     | Gitea (Proxmox)                 |
| Boot generations              | systemd-boot limit = 20 | On rebuild     | Local ESP                       |

Restore test cadence: **quarterly**.

------

## Deferred / Out of Scope (intentional)

These are excluded until a named trigger condition is met. See the *Operator Decisions Log* in the architecture reference for triggers.

- Steam / Proton / gamemode / mangohud
- OBS Studio
- Scanner (SANE)
- Printer drivers (CUPS enabled; driver packages deferred)
- TPM-backed LUKS unlock / Secure Boot (lanzaboote)
- Email and chat clients

------

## Reference

| Resource        | URL                                           |
| --------------- | --------------------------------------------- |
| NixOS Manual    | https://nixos.org/manual/nixos/stable/        |
| Home Manager    | https://nix-community.github.io/home-manager/ |
| Hyprland Wiki   | https://wiki.hypr.land/                       |
| Quickshell Docs | https://quickshell.outfoxxed.me/docs/         |
| Stylix          | https://github.com/danth/stylix               |
| disko           | https://github.com/nix-community/disko        |
| sops-nix        | https://github.com/Mic92/sops-nix             |
| Walker launcher | https://github.com/abenz1267/walker           |

------

**Operator:** `mboehme` · **Fleet:** `nix-desktop`, `nix-laptop` · **Architecture:** frozen at v3