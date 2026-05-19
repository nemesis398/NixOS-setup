# NixOS + Hyprland + Quickshell Architecture Reference

**Project:** Custom NixOS Configuration
**Target:** Multi-Machine Deployment with AMD GPU Support
**Boot Manager:** systemd-boot
**Filesystem:** BTRFS on LVM on LUKS
**Compositor:** Hyprland (Wayland Native) — upstream flake
**UI Framework:** Quickshell (QML / JavaScript) — custom, in-house
**Config Management:** Nix Flakes + Home Manager
**Theming:** Stylix (system-wide, base16)
**Hibernation:** Enabled on both hosts (encrypted swap LV)
**Document Version:** 3

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NIXOS DECLARATIVE STACK                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐          │
│  │  GITEA REPO     │    │  PROXMOX SERVER │    │  AMD HARDWARE   │          │
│  │  (flake.nix)    │◄───┤  (Automation)   │    │  (RDNA GPU)     │          │
│  └────────┬────────┘    └─────────────────┘    └─────────────────┘          │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     NIX FLAKES OUTPUT                               │    │
│  │  nixosConfigurations.{nix-desktop, nix-laptop}                      │    │
│  │  (LXC variant deferred — added when needed)                         │    │
│  │  homeConfigurations.mboehme@<host>  (if standalone HM)              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## System Layers

### Layer 1: Boot & Storage

#### Storage Stack

```
┌─────────────────────────────────────────────┐
│ BTRFS subvolumes (@root, @home, @nix, ...)  │
├─────────────────────────────────────────────┤
│ LVM Logical Volumes  (lv_swap, lv_root)     │
├─────────────────────────────────────────────┤
│ LVM Volume Group     (vg_system)            │
├─────────────────────────────────────────────┤
│ LUKS2 Container      (on partition 2)       │
├─────────────────────────────────────────────┤
│ GPT Partition Table  (/dev/diskX)           │
└─────────────────────────────────────────────┘
```

#### Partition Layout

| Device | Partition | Size | Type | Purpose |
|--------|-----------|------|------|---------|
| `/dev/diskX` | p1 | 10 GiB | EFI System (vfat, FAT32) | Boot partition (systemd-boot + kernels + recovery ISO) |
| `/dev/diskX` | p2 | 100% FREE | Linux LUKS | Encrypted container |

> **EFI sizing (operator decision):** 10 GiB is intentionally oversized so a bootable rescue ISO (NixOS installer or SystemRescue) can live on the ESP for use when no USB stick is at hand. systemd-boot can chainload this ISO via a `loader/entries/recovery.conf` entry — see notes under **Bootable ISO on ESP**.

#### LVM Volume Group (`vg_system`) on LUKS

| Logical Volume | Size | Filesystem | Purpose |
|----------------|------|------------|---------|
| `lv_swap` | = installed RAM + 2 GiB | swap (`mkswap`) | Hibernate target + overflow |
| `lv_root` | 100% FREE | BTRFS | Subvolume host |

> **Hibernate:** size `lv_swap` ≥ physical RAM. Kernel cmdline must include `resume=/dev/mapper/vg_system-lv_swap`. Hibernation from encrypted swap requires `boot.resumeDevice` and the swap LV to be unlocked at early boot (same LUKS device, so this is automatic).

#### BTRFS Subvolumes (on `lv_root`)

| Subvolume | Mount Point | Mount Options | Purpose |
|-----------|-------------|---------------|---------|
| `@root` | `/` | `rw,compress=zstd:3,noatime,ssd,space_cache=v2,discard=async` | System root |
| `@nix` | `/nix` | `rw,compress=zstd:3,noatime,ssd,space_cache=v2,discard=async` | Nix store (large, compressible) |
| `@home` | `/home` | `rw,compress=zstd:3,noatime,ssd,space_cache=v2,discard=async` | User data |
| `@var-log` | `/var/log` | `rw,compress=zstd:3,noatime,ssd,space_cache=v2,discard=async,nodatacow` | Journald, app logs |
| `@var-lib` | `/var/lib` | `rw,compress=zstd:3,noatime,ssd,space_cache=v2,discard=async` | Service state (excl. libvirt, gitea) |
| `@vms` | `/var/lib/libvirt` | `rw,noatime,ssd,space_cache=v2,discard=async,nodatacow` | KVM images — CoW disabled for performance |
| `@gitea` | `/var/lib/gitea` | `rw,compress=zstd:3,noatime,ssd,space_cache=v2,discard=async` | Self-hosted git (moved out of `/home/<user>/vms`) |
| `@snapshots` | `/.snapshots` | `rw,noatime,ssd,space_cache=v2,discard=async` | Snapshot storage (snapper / btrbk) |

> **Mount-order requirement:** `@var-lib` must mount before `@vms` and `@gitea` (nested mountpoints). NixOS handles this automatically when `fileSystems.<path>` entries are declared, but the dependency must not be broken by manual unit edits.

> **`nodatacow` rationale:** VM images and databases produce many partial-block rewrites; BTRFS CoW fragments these heavily. Disable CoW for VM image stores and any DB-backed service directories. `nodatacow` implies `nodatasum` and disables compression for the affected files.

#### Boot Configuration

| Component | Source | Purpose |
|-----------|--------|---------|
| Boot Loader | `boot.loader.systemd-boot.enable = true` | EFI boot manager (NixOS module option) |
| Encryption | LUKS2 (`cryptsetup luksFormat --type luks2`) | Disk encryption format |
| LUKS tools | `cryptsetup` (in initrd via `boot.initrd.luks.devices`) | Unlock at boot |
| Filesystem | `btrfs-progs` (initrd + userspace) | BTRFS tooling |
| Microcode | `hardware.cpu.amd.updateMicrocode = true` | CPU microcode at boot |
| GC for boot | `boot.loader.systemd-boot.configurationLimit = 20` | Keep last N generations on ESP |

#### Boot Flow

```
UEFI POST
   │
   ▼
systemd-boot (ESP)
   │
   ▼
initrd: load amdgpu microcode, prompt LUKS passphrase
   │
   ▼
unlock /dev/diskX → /dev/mapper/cryptroot
   │
   ▼
activate VG vg_system → expose lv_root, lv_swap
   │
   ▼
mount @root (/) → mount @nix, @home, @var-log, @var-lib, @vms, @gitea, @snapshots
   │
   ▼
systemd → greetd → regreet → Hyprland session
```

---

### Layer 2: Wayland Compositor

#### Display Server Stack

| Component | nixpkgs Attribute | Purpose |
|-----------|-------------------|---------|
| Compositor | `hyprland` | Wayland window manager (dynamic tiling) |
| IPC | `hyprland` (`hyprctl` bundled) | Runtime CLI control |
| Portal (Hyprland) | `xdg-desktop-portal-hyprland` | screencast, screenshot, global shortcuts |
| Portal (GTK fallback) | `xdg-desktop-portal-gtk` | File chooser, OpenURI |
| Portal manager | `xdg-desktop-portal` (auto by NixOS) | Portal router |

> **Enable via module, not packages:** `programs.hyprland.enable = true;` pulls Hyprland, sets `XDG_CURRENT_DESKTOP`, configures portals, and registers the systemd target. Adding `hyprland` to `environment.systemPackages` instead is a common antipattern that bypasses these integrations.

> **Source: upstream flake (operator decision).** Hyprland and its companion components come from `github:hyprwm/Hyprland`, not nixpkgs. The flake's overlay (`inputs.hyprland.overlays.default`) is applied to `pkgs`, replacing nixpkgs versions of the entire `hypr*` family in lockstep. This avoids the IPC / protocol / portal version skew that bites mixed stacks.
>
> **Ecosystem coherence — these components must travel together** (all sourced from the upstream flake's overlay):
>
> | Component | Role |
> |-----------|------|
> | `hyprland` | Compositor |
> | `xdg-desktop-portal-hyprland` | Wayland portal — IPC version-bound to compositor |
> | `hyprlock` | Lockscreen |
> | `hypridle` | Idle manager |
> | `hyprpolkitagent` | Polkit agent |
> | `hyprcursor` | Cursor protocol implementation |
> | `hyprutils`, `aquamarine`, `hyprlang` | Shared libraries — version-locked to compositor |
>
> Pinning strategy: pin the flake input to a release tag (e.g. `v0.51.1`), not `main`. Bump explicitly after reading the release notes; Hyprland has shipped breaking config changes within minor versions before.

#### GPU Configuration (AMD RDNA)

| Component | nixpkgs Attribute / Option | Purpose |
|-----------|----------------------------|---------|
| Mesa (OpenGL / Vulkan RADV) | `hardware.graphics.enable = true` | Userspace GL/Vulkan stack |
| 32-bit Mesa (Steam/Wine) | `hardware.graphics.enable32Bit = true` | 32-bit ABI for Proton |
| VA-API runtime | `libva-utils` (debugging) | Video acceleration |
| VA-API driver | included with Mesa (`radeonsi`) | HW video decode |
| AMDVLK (optional, opt-in) | `hardware.graphics.extraPackages = [ pkgs.amdvlk ]` | Vendor Vulkan ICD |
| Kernel module | `amdgpu` (in-tree) | KMS / DRM driver |

> **RADV vs AMDVLK:** Mesa's RADV is the recommended default for desktop and gaming on RDNA. AMDVLK is AMD's open-source Vulkan ICD with feature parity gaps and occasional regressions; install only if a specific workload requires it. If both are present, set `VK_ICD_FILENAMES` or `AMD_VULKAN_ICD=RADV` to force selection. See **ADR-10 (Vulkan Stack)**.

> **`hardware.opengl.*` is renamed:** since NixOS 24.11 the option set is `hardware.graphics.*`. v1.0 did not specify; v2.0 standardises on the new path.

#### Session Management

| Component | Configuration | Purpose |
|-----------|--------------|---------|
| Greeter | `services.greetd` command | DRM-rendered login |
| Session entry | `Hyprland` (no uwsm) | Direct compositor exec |
| Env init | `programs.zsh` + `home.sessionVariables` | `XDG_*`, `WAYLAND_DISPLAY`, etc. |
| Wayland flag | `XDG_SESSION_TYPE=wayland` | Set by `pam_systemd` |

#### Wayland Protocol Stack

```
┌─────────────────────────────────────────────┐
│           APPLICATIONS                      │
├─────────────────────────────────────────────┤
│   XDG Desktop Portal  (hyprland + gtk)      │
├─────────────────────────────────────────────┤
│           Hyprland (wlroots-based)          │
├─────────────────────────────────────────────┤
│   Wayland protocols (wlr-*, ext-*, xdg-*)   │
├─────────────────────────────────────────────┤
│   libdrm / KMS / DRM                        │
├─────────────────────────────────────────────┤
│   amdgpu kernel driver + Mesa (RADV)        │
└─────────────────────────────────────────────┘
```

---

### Layer 3: UI & User Interface

#### Status Bar & Shell

| Component | nixpkgs Attribute | Language | Purpose |
|-----------|-------------------|----------|---------|
| Shell toolkit | `quickshell` | QML + JavaScript | Bar, OSDs, widgets, **notification daemon**, polkit prompts (optional) |

> **Custom Quickshell:** no upstream config (DankMaterialShell, caelestia, noctalia) is vendored.

> **Notifications are handled by Quickshell itself**, not by `mako`. Quickshell exposes the `Quickshell.Services.Notifications` module which implements the `org.freedesktop.Notifications` D-Bus service.

#### Launcher & Authentication

| Component | nixpkgs Attribute | Mode | Purpose |
|-----------|-------------------|------|---------|
| Application Launcher | `walker` | Wayland daemon | Fuzzy search, plugins, script runner |
| Login Manager | `greetd` + `regreet` | GTK4 GUI | Pre-session login screen |
| Lock Screen | `hyprlock` | Wayland, GPU-accelerated | Session locker (requires PAM service — see Layer 8) |
| Polkit Agent | `hyprpolkitagent` | Wayland daemon | GUI privilege prompts (replaceable by Quickshell-native later) |

> **GUI greeter (operator decision):** `regreet` selected. It is a GTK4 greeter that runs under a minimal `cage` Wayland session before the user logs in.

#### Wallpaper Management

| Component | nixpkgs Attribute | Purpose |
|-----------|-------------------|---------|
| Wallpaper Daemon | `awww` | Animated transitions, IPC-driven |
| Wallpaper Selector | `waypaper` | GUI picker |

#### Power & Idle Management

| Component | nixpkgs Attribute | Purpose |
|-----------|-------------------|---------|
| Idle Manager | `hypridle` | DPMS off, lock-on-idle, suspend |
| Power Profiles | `services.power-profiles-daemon.enable = true` | Power saver / balanced / performance |
| Brightness | `brightnessctl` | Backlight control (laptop) |

---

### Layer 4: Daemons & System Services

#### Audio/Video Framework

| Component | NixOS Option | Purpose |
|-----------|--------------|---------|
| PipeWire | `services.pipewire.enable = true` | Audio + video routing |
| WirePlumber | `services.pipewire.wireplumber.enable = true` | Session/policy manager |
| ALSA compat | `services.pipewire.alsa.enable = true` | ALSA client compatibility |
| JACK compat | `services.pipewire.jack.enable = true` | Pro-audio compatibility |
| Bluetooth codecs | bundled with `pipewire` + `libldac`, `liblc3` | LDAC, AAC, aptX, LC3 over BT |

#### Hardware Services

| Component | NixOS Option / Attribute | Purpose |
|-----------|--------------------------|---------|
| Bluetooth | `hardware.bluetooth.enable = true` | BlueZ stack |
| Bluetooth GUI | `blueman` | Adapter and device manager |
| Network | `networking.networkmanager.enable = true` | NM daemon |
| Network GUI | `networkmanagerapplet` (provides `nm-applet`) | Tray UI |
| Auto-mount | `services.udisks2.enable = true` + `udiskie` | Removable media |
| Printing (recommended) | `services.printing.enable = true` (CUPS) | Print queue |
| Avahi (optional) | `services.avahi.enable = true` | mDNS / network printer/AirPlay discovery |
| Firmware | `hardware.enableRedistributableFirmware = true` | linux-firmware blobs |

#### Clipboard Management

| Component | nixpkgs Attribute | Purpose |
|-----------|-------------------|---------|
| Wayland Clipboard CLI | `wl-clipboard` | `wl-copy`, `wl-paste` |
| Clipboard History | `cliphist` | Persistent clipboard history (queried via walker) |

#### Screenshot Pipeline

| Component | nixpkgs Attribute | Purpose |
|-----------|-------------------|---------|
| Capture | `grim` | Wayland screenshot |
| Region | `slurp` | Geometry picker |
| Annotation | `swappy` | Quick edits |
| OCR (optional) | `tesseract` + script | Text extraction from selection |

```
┌──────────────────────────────────────────────┐
│           WAYLAND SESSION                    │
├──────────────────────────────────────────────┤
│ SCREENSHOT      → grim + slurp → swappy      │
│ CLIPBOARD       → wl-clipboard               │
│ CLIPBOARD HIST  → cliphist                   │
│ LAUNCHER        → walker (daemon)            │
│ NOTIFICATIONS   → quickshell (built-in)      │
│ POLKIT          → hyprpolkitagent            │
│ IDLE / LOCK     → hypridle → hyprlock        │
├──────────────────────────────────────────────┤
│ AUDIO/VIDEO     → pipewire + wireplumber     │
│ BLUETOOTH       → bluez + blueman            │
│ NETWORK         → NetworkManager             │
│ STORAGE         → udiskie + udisks2          │
│ PRINTING        → cups + avahi (opt)         │
└──────────────────────────────────────────────┘
```

---

### Layer 5: User Applications

#### Terminal Emulator

| Attribute | Purpose |
|-----------|---------|
| `kitty` | GPU-accelerated terminal (primary) |

#### File Management

| Attribute | Type | Purpose |
|-----------|------|---------|
| `yazi` | TUI | Primary file manager |
| `xfce.thunar` | GUI | Secondary, GTK file manager |
| `xfce.thunar-volman` | Plugin | Removable media handling |
| `xfce.thunar-archive-plugin` | Plugin | Archive ops in Thunar |

#### Web Browsers

| Attribute | Source | Purpose |
|-----------|--------|---------|
| `helium` | https://github.com/schembriaiden/helium-browser-nix-flake | Primary browser |

#### Office Suite

| Attribute | Purpose |
|-----------|---------|
| `onlyoffice-desktopeditors` | Documents, spreadsheets, presentations |

#### Media

| Attribute | Purpose |
|-----------|---------|
| `vlc` | Media player (primary) |

#### Development

| Attribute | Purpose |
|-----------|---------|
| `neovim` | Editor (Lua-configured) |
| `git` | VCS |
| `gh` | GitHub CLI (optional, useful for PR workflow) |
| `lazygit` | TUI git interface |
| `direnv` + `nix-direnv` | Per-directory dev shells |

#### System Monitoring

| Attribute | Type | Purpose |
|-----------|------|---------|
| `btop` | TUI | Resource monitor (secondary) |
| `mission-center` | GUI | Graphical monitor (primary) |
| `lm_sensors` | CLI | `sensors`, hwmon |
| `nvtopPackages.amd` | TUI | AMD GPU monitoring |

#### Screen Capture

See Layer 4 (`grim`, `slurp`, `swappy`).

#### Image & Document Viewing

| Attribute | Purpose |
|-----------|---------|
| `imv` | Wayland-native image viewer |
| `zathura` | Minimal PDF viewer (vim-keys) |

#### Device Integration

| Attribute | Purpose |
|-----------|---------|
| `kdePackages.kdeconnect-kde` | iPhone/Android sync, clipboard, notifications |

> **Note:** the nixpkgs attribute is `kdePackages.kdeconnect-kde` (Qt6/KDE6 split). The unqualified `kdeconnect` may still alias correctly depending on channel.

#### Archive Utilities

| Attribute | Purpose |
|-----------|---------|
| `unzip` | ZIP |
| `p7zip` | 7z, ZIP, ISO, etc. |
| `unrar` (unfree) | RAR — requires `nixpkgs.config.allowUnfreePredicate` |
| `zstd`, `xz`, `gzip` | Native tools (usually in base) |

#### Shell & Prompt

| Attribute | Purpose |
|-----------|---------|
| `zsh` | Shell (enable via `programs.zsh.enable = true`) |
| `starship` | Cross-shell prompt |
| `atuin` | Searchable, syncable shell history |
| `zoxide` | Smart `cd` replacement |
| `fzf` | Fuzzy finder (integrates with atuin, zoxide, yazi) |

#### Modern CLI Tools (recommended additions)

| Attribute | Replaces / Augments | Purpose |
|-----------|---------------------|---------|
| `ripgrep` | `grep` | Fast recursive grep |
| `fd` | `find` | Fast file finder |
| `bat` | `cat` | Syntax-highlighted cat |
| `eza` | `ls` | Modern ls with git integration |
| `jq` | — | JSON manipulation |
| `yq-go` | — | YAML manipulation |
| `delta` | — | Better `git diff` |

#### Infrastructure Tools

| Attribute | Purpose |
|-----------|---------|
| `openssh` | Remote access; enable server via `services.openssh.enable = true` |
| `rsync` | File sync |
| `restic` | Encrypted backup (BTRFS snapshots → Proxmox) |

#### Utilities

| Attribute | Purpose |
|-----------|---------|
| `wlsunset` | Blue-light filter |
| `wlr-randr` | Manual display config |
| `kanshi` | Declarative dynamic display profiles |

#### More

| Attribute | Purpose                    |
| --------- | -------------------------- |
| `zotero`  | Research and documentation |
| `foliate` | Simple eReader             |
| `blanket` | Simple ambient sounds      |
|           |                            |

---

### Layer 6: Fonts & Theming

Theming is unified under **Stylix** (a base16-driven NixOS + Home Manager theming framework by `danth`). Stylix replaces the manual per-program theming approach from v1.0 / v2.x drafts and removes the need for several auxiliary tools. See **ADR-14** for the decision record.

#### Fonts

| Attribute | Role in Stylix | Purpose |
|-----------|----------------|---------|
| `nerd-fonts.jetbrains-mono` | `stylix.fonts.monospace` | Terminal / code |
| `dejavu_fonts` (or `inter`) | `stylix.fonts.sansSerif` | UI sans-serif |
| `dejavu_fonts` (or `source-serif`) | `stylix.fonts.serif` | Documents |
| `noto-fonts-emoji` | `stylix.fonts.emoji` | Emoji |
| `noto-fonts-cjk-sans` | aux (auto-picked by fontconfig) | CJK coverage |
| `liberation_ttf` | aux | MS-compatible metrics |

> Stylix takes **four font roles** (mono / sans / serif / emoji) plus optional sizes for terminal, application, desktop, popup. Pick one mono and propagate to all consumers.

#### Theming via Stylix

| Concern | Stylix mechanism | Replaces |
|---------|------------------|----------|
| Colour scheme | `stylix.base16Scheme = pkgs.base16-schemes + "share/themes/catppuccin-mocha.yaml"` (or any base16 yaml) | `catppuccin/nix` flake (no longer needed as flake input) |
| Auto-derive from wallpaper | `stylix.image = ./wallpaper.png` (optional alternative to a fixed scheme) | Manual palette curation |
| GTK theme | `stylix.targets.gtk.enable` | `nwg-look` (manual GTK switcher — removed) |
| Qt5/Qt6 styling | `stylix.targets.qt.enable` (uses `qtct` backend internally) | `qt5ct` / `qt6ct` (still installable as fallback, but Stylix-driven by default) |
| Kitty / Neovim / Btop / Bat / Fzf / Starship / Yazi / Hyprland / Hyprlock / etc. | `stylix.targets.<program>.enable` | Per-program theme blocks |
| Cursor theme | `stylix.cursor.{package, name, size}` | Manual `bibata-cursors` declaration |
| Icon theme | `stylix.iconTheme.{package, dark, light, enable}` | Manual `papirus-icon-theme` declaration |
| Console (TTY) | `stylix.targets.console.enable` | Manual `console.colors` |
| systemd-boot menu | `stylix.targets.systemd-boot.enable` (optional) | Default monochrome |

#### Stylix Coverage Limits

Stylix has a finite list of `targets.<program>`. Anything outside that list — notably the **custom Quickshell QML tree** — is *not* auto-themed. Strategy:

1. Stylix already exposes its base16 palette as `config.lib.stylix.colors` (Nix attrset) and as a generated JSON file at `${config.stylix.paletteJsonPath}`.
2. Symlink that JSON into `~/.config/quickshell/theme/palette.json` via `xdg.configFile`.
3. The custom Quickshell `theme/Palette.qml` singleton reads and re-exports the base16 colours as QML properties.
4. The shell now repaints in lockstep with any Stylix scheme swap.

#### Packages Still Needed Alongside Stylix

| Attribute | Why retained |
|-----------|--------------|
| `papirus-icon-theme` | Declared as `stylix.iconTheme.package` source |
| `bibata-cursors` | Declared as `stylix.cursor.package` source |
| `qt6ct` / `qt5ct` (optional) | Kept as escape hatch for one-off Qt overrides; Stylix sets the default style automatically |

> `nwg-look` is **removed** — Stylix owns GTK theming and `nwg-look` would race against it.

#### What Stylix Does Not Replace

- **Hyprland config itself** (window rules, keybinds, animations) — only the colour values inside it.
- **Quickshell QML structure** — see palette-export pattern above.
- **App-specific layouts** (e.g. Kitty key bindings, Neovim plugins) — only the colour values.

---

### Layer 7: Configuration Management (new)

#### Flake Structure

```
flake.nix
├── inputs
│   ├── nixpkgs            (nixos-unstable or 25.05)
│   ├── home-manager       (matching nixpkgs branch)
│   ├── hyprland           (official flake — pinned to release tag)
│   ├── quickshell         (outfoxxed/quickshell flake — pinned to release tag)
│   ├── stylix             (danth/stylix — pinned)
│   ├── disko              (nix-community/disko — declarative partitioning)
│   ├── sops-nix           (Mic92/sops-nix)
│   └── zen-browser        (community flake)
└── outputs
    ├── nixosConfigurations.{nix-desktop, nix-laptop}
    └── homeConfigurations.mboehme@<host>   (if standalone HM)
```

#### Home Manager Integration

See **ADR-01** for the system-module vs standalone trade-off. **Recommended: system-module integration** (`home-manager.nixosModules.home-manager`), which keeps user dotfiles atomic with system rebuilds.

User-scoped configs that belong in Home Manager rather than `/etc`:

| Program | HM Module |
|---------|-----------|
| Hyprland | `wayland.windowManager.hyprland` |
| Kitty | `programs.kitty` |
| Zsh + Starship | `programs.zsh`, `programs.starship` |
| Neovim | `programs.neovim` |
| Git | `programs.git` |
| Hypridle / Hyprlock | community modules or raw config files |
| Walker | raw config file via `xdg.configFile` |
| Quickshell | raw QML tree via `xdg.configFile."quickshell".source` — owns the notification daemon |

---

### Layer 8: Security & Hardening (new)

| Concern | Mechanism | Notes |
|---------|-----------|-------|
| Firewall | `networking.firewall.enable = true` | Default deny; open only declared ports |
| Disk encryption | LUKS2 (Layer 1) | Manual passphrase entry |
| Secrets in repo | `sops-nix` or `agenix` | See **ADR-02** |
| Microcode | `hardware.cpu.amd.updateMicrocode = true` | AMD RDNA mandatory |
| Sudo policy | `security.sudo.wheelNeedsPassword = true` | Default |
| Polkit | `hyprpolkitagent` (user session) | GUI prompts |
| `hyprlock` PAM service | `security.pam.services.hyprlock = {};` | **Required** — without it `hyprlock` rejects every password (no PAM stack to authenticate against) |
| Kernel hardening (opt-in) | `boot.kernelPackages = pkgs.linuxPackages_hardened` | See **ADR-03**; trade-off vs. AMD performance |
| Secure Boot (opt-in) | `lanzaboote` flake | See **ADR-05** |
| Trusted DNS (opt-in) | `services.resolved.enable = true` with DNSSEC | systemd-resolved |
| SSH | `services.openssh` with `PasswordAuthentication = false` | Key-only login |
| Containers / VMs | namespace isolation; AppArmor optional | See **ADR-11** |

---

### Layer 9: Maintenance & Operations (new)

#### Generations & Garbage Collection

| Setting | Value | Rationale |
|---------|-------|-----------|
| `boot.loader.systemd-boot.configurationLimit` | `20` | Bound ESP usage |
| `nix.gc.automatic` | `true` | Hands-off cleanup |
| `nix.gc.dates` | `"weekly"` | Reasonable cadence |
| `nix.gc.options` | `"--delete-older-than 30d"` | Keep 30 days of generations |
| `nix.settings.auto-optimise-store` | `true` | Hardlink duplicate store paths |
| `nix.settings.experimental-features` | `[ "nix-command" "flakes" ]` | Required for flake workflow |

#### Snapshot Strategy

| Layer | Tool | Trigger |
|-------|------|---------|
| BTRFS local snapshots | `btrbk` or `snapper` | Hourly / daily, retained per policy |
| Off-site (Proxmox) | `restic` over SSH | Daily, encrypted repo |
| ESP / nixpkgs lock | git (Gitea) | On every commit |

> **Why BTRFS snapshots + restic, not just one:** BTRFS snapshots are instant and great for quick local rollback, but they live on the same disk. Restic on Proxmox provides off-host, encrypted, deduplicated backups. Together they cover both fast recovery and disaster recovery.

#### Channel / Input Pinning

| Input | Strategy | Notes |
|-------|----------|-------|
| `nixpkgs` | Follow `nixos-25.05` (stable) or `nixos-unstable` | Stable recommended for main-pc; unstable acceptable for spare-pc |
| `home-manager` | Track matching nixpkgs branch | Mismatched branches cause module evaluation errors |
| `hyprland` | Pin to released tag; bump explicitly | Hyprland's `hyprland.nixosModules.default` provides the up-to-date module |
| `quickshell` | Pin commit; track outfoxxed release notes | API still evolving |

---

## Architectural Decision Records (ADRs)

Each ADR follows: **Options → Trade-offs → Recommendation → Rejected alternatives**.

---

### ADR-01: Home Manager Integration Mode

**Decision required:** how to wire Home Manager into the flake.

| Option | Pros | Cons |
|--------|------|------|
| **A. NixOS module** (`home-manager.nixosModules.home-manager`) | Single `nixos-rebuild` rebuilds system + HM atomically; rollbacks cover both; one generation tree | Slightly slower rebuilds; HM bound to system rebuild cycle; needs `useGlobalPkgs` to share nixpkgs config |
| **B. Standalone** (`homeConfigurations.<user>@<host>`) | HM updates independently (`home-manager switch`); works on non-NixOS hosts | Two rollback timelines; risk of HM/NixOS drift; more boilerplate |
| **C. No HM** (raw `environment.etc` / `home.file` workarounds) | Minimal dependencies | Reinvents HM poorly; user-scoped state polluting `/etc`; fights NixOS module ergonomics |

**Recommended: A (NixOS module).** A single source of truth and atomic rollbacks outweigh the rebuild-time penalty for a fleet of three machines.

**Rejected:** B (operational complexity for marginal benefit on a uniform fleet). C (loses HM's strongest value — typed, composable user configuration).

---

### ADR-02: Secrets Management

**Decision required:** how to store and decrypt secrets (Wi-Fi PSKs, restic password, SSH keys, Gitea tokens) committed to the Gitea repo.

| Option | Pros | Cons |
|--------|------|------|
| **A. `sops-nix`** | Industry-standard SOPS format; supports age, GPG, KMS; selective key rotation; encrypts YAML/JSON/ENV/binary | More moving parts; requires age keys present at activation; key distribution problem |
| **B. `agenix`** | Pure age; very small surface; activation-time decryption | Less tooling (no per-value edits without re-encrypting file); single backend |
| **C. Plain files outside repo** | Trivially simple | Defeats the "config is git" goal; no audit trail; no reproducibility |
| **D. `nix-sops`-less `pass` integration** | Reuses existing GPG workflow | Activation-time secret materialisation is awkward |

**Recommended: A (`sops-nix`) with age backend.** Per-host age keys derived from each machine's SSH host key (`ssh-to-age`) eliminate the key-distribution problem; secrets are decrypted at activation into `tmpfs` at `/run/secrets`.

**Rejected:** B (acceptable runner-up; rejected only because sops's per-value editing scales better as the secret set grows). C (violates declarative principle). D (poor activation story).

---

### ADR-03: Kernel Selection

| Option | Pros | Cons |
|--------|------|------|
| **A. `linuxPackages` (default LTS-ish)** | Most-tested by nixpkgs; broadest binary cache coverage | Lags on newest amdgpu features |
| **B. `linuxPackages_latest`** | Newest mainline; best RDNA support | More churn; occasional regressions |
| **C. `linuxPackages_zen`** | Desktop/gaming tunings, lower latency | Out-of-tree maintenance dependency |
| **D. `linuxPackages_xanmod`** (community flake) | Scheduler tweaks; gamer focus | Same caveat as Zen |
| **E. `linuxPackages_hardened`** | KSPP patches, attack surface reduction | Disables some modules; ~5–15% perf hit; can break virtualisation |

**Recommended: B (`linuxPackages_latest`).** RDNA hardware benefits materially from newer amdgpu, and nixpkgs builds latest in the binary cache so there is no local compile cost.

**Rejected:** A (acceptable fallback; chosen only if a `_latest` regression appears). C/D (marginal gains over `_latest` for a desktop workload). E (good security posture, but conflicts with the AMD-performance goal; revisit only for the Proxmox LXC host where graphics performance is irrelevant).

---

### ADR-04: Swap Strategy

| Option | Pros | Cons |
|--------|------|------|
| **A. LVM `lv_swap`** (chosen in Layer 1) | Simple, works with hibernate, encrypted via LUKS, resizable | Static allocation; needs LVM in the stack |
| **B. BTRFS swapfile** | No LVM needed; resize trivial | Hibernate requires `btrfs inspect-internal map-swapfile` resume offset; CoW must be disabled; brittle |
| **C. Swap partition (outside LUKS)** | Simplest layout | Plaintext swap is a hibernate-image leak; **disqualifying** |
| **D. zram only** | RAM-only, fast, no disk wear | No hibernate; no real overflow beyond compression ratio |
| **E. zram + LVM swap** | Fast everyday compression + hibernate fallback | Slightly more config |

**Recommended: E (zram primary + LVM `lv_swap` for hibernate).** Configure `zramSwap.enable = true` with high priority; keep `lv_swap` for hibernate target.

**Rejected:** A alone (works but leaves easy zram performance gains on the table). B (hibernate fragility). C (plaintext hibernate image is a credible threat). D alone (loses hibernate).

---

### ADR-05: Boot Loader

**Decided (operator):** `systemd-boot`. Secure Boot is explicitly out of scope.

| Option | Pros | Cons |
|--------|------|------|
| **A. `systemd-boot`** ✅ | Simple, fast, native in NixOS; trivial chainloading of recovery ISOs via `loader/entries/*.conf`; no key-management overhead | No Secure Boot; no signature chain |
| **B. `lanzaboote`** | Adds Secure Boot via signed unified kernel images | Newer; key enrolment ceremony; bricking risk on misuse; **not wanted** |
| **C. GRUB** | Most features (BIOS+EFI, encryption-aware menus) | Slower; larger attack surface; over-spec for this use case |

**Recommended: A.** Locked in. The 10 GiB ESP gives space for a fleet of kernel generations *and* a rescue ISO available via a `recovery.conf` boot entry — see operational note **"Bootable ISO on ESP"** below the ADRs.

**Rejected:** B (Secure Boot deliberately not adopted). C (no compelling feature for this stack).

---

### ADR-06: Wallpaper Daemon

**Decided (operator):** `awww`.

| Option | Pros | Cons |
|--------|------|------|
| **A. `awww`** ✅ | Renamed successor to `swww` (Oct 2025); animated transitions; IPC; multi-namespace support; ships legacy `swww` binary names for compat | Daemon process; small VRAM cost; recent rename means some third-party docs still say `swww` |
| **B. `hyprpaper`** | Official Hyprland; lightweight; static only | No transitions; per-monitor config rigid |
| **C. `mpvpaper`** | Video wallpapers | High GPU/power cost; overkill |
| **D. `wpaperd`** | Auto-rotate with simple config | Smaller community |

**Recommended: A.** Locked in.

**Rejected:** B (no transitions). C (power draw unjustified). D (smaller ecosystem; nothing `awww` doesn't already do).

---

### ADR-07: Notification Daemon

**Decided (operator):** Quickshell-native. No external notification daemon.

| Option | Pros | Cons |
|--------|------|------|
| **A. Quickshell-native** ✅ | Single shell process owns notifications; theming unified with bar; no extra daemon; full control over urgency rendering, history pane, DND, actions | Requires writing the QML; must own the D-Bus service lifecycle |
| **B. `mako`** | Lightweight, INI config, well-maintained | Separate daemon; theming drift from the rest of Quickshell |
| **C. `swaync`** | Notification centre with history pane | Heavier; GTK; duplicates work Quickshell can do natively |
| **D. `dunst`** | Mature, scriptable | Less Wayland-native heritage |

**Recommended: A.** Locked in.

**Implementation requirements (must-build):**

1. **D-Bus service registration.** Use `Quickshell.Services.Notifications` — instantiate a `NotificationServer { }` singleton. This claims `org.freedesktop.Notifications` on the session bus. Two notification daemons cannot coexist; ensure mako / swaync / dunst are absent from `environment.systemPackages`.
2. **Notification model.** Maintain a `ListModel` of active notifications, keyed by `id` (uint32 per spec), supporting the `Replaces` semantics. Expire entries by `expireTimeout` (use a `Timer` per entry or a single tick-based reconciler).
3. **Popup component.** A `PanelWindow` anchored top-right (or per preference) with a `Repeater` over the model. Each delegate renders summary, body, app icon, actions, and urgency-coloured border (`low` / `normal` / `critical`).
4. **Action handling.** Each notification can carry `actions` (e.g. `["default", "Open", "reply", "Reply"]`). Bind `MouseArea.onClicked` to `NotificationServer.invokeAction(id, key)`.
5. **History pane (optional).** Mirror dismissed notifications into a second model with a TTL; render in a `PopupWindow` or slide-out panel triggered from the bar.
6. **DND mode.** A boolean property on a singleton that gates whether popups are shown. Persist via `Quickshell.PersistentProperties` or write to `~/.config/quickshell/state.json`.
7. **Image handling.** Notifications may carry inline image data (`image-data` hint) or paths (`image-path`). Use `Quickshell.Image` with the `Notification.image` property — Quickshell handles both transparently in recent versions.

**Validation:**

```bash
# After implementation, test with:
notify-send -u critical "Test" "Critical-urgency body"
notify-send -t 5000 -a "MyApp" "Replaceable" "Body"
busctl --user introspect org.freedesktop.Notifications /org/freedesktop/Notifications
```

The third command must show Quickshell as the bus name owner — not mako.

**Rejected:** B/C/D (operator decision; native ownership preferred).

---

### ADR-08: Greeter

**Decided (operator):** GUI greeter required.

| Option | Pros | Cons |
|--------|------|------|
| **A. `greetd` + `tuigreet`** | Tiny; renders in DRM; works pre-Wayland; fewest dependencies | TUI only — **disqualified by operator requirement** |
| **B. `greetd` + `regreet`** ✅ | GTK4 GUI; theme-able via GTK CSS; runs under `cage` (minimal Wayland compositor); session list from `/etc/greetd/environments` | Wayland session required for the greeter itself; more deps than tuigreet |
| **C. `greetd` + `gtkgreet`** | GTK3 GUI under `cage` | Older GTK stack; less active development |
| **D. SDDM** | Mature, Qt6, Wayland-capable, theme-rich | Heavier; brings full KDE Plasma dependency chains via `kdePackages` |
| **E. GDM** | Most polished UX | Pulls GNOME components; misaligned with the minimal Wayland philosophy |

**Recommended: B (`regreet`).** GTK4 GUI under `cage`, configurable via `/etc/greetd/config.toml` + `regreet.toml`. Theme via GTK CSS so the greeter visually matches the desktop. Cage is launched as the greeter's compositor; it dies after login and the user's Hyprland session takes over.

**Required wiring (summary, not implementation):**

- `services.greetd.enable = true;`
- `services.greetd.settings.default_session.command = "${pkgs.cage}/bin/cage -s -- ${pkgs.greetd.regreet}/bin/regreet";`
- `programs.regreet.enable = true;` (provides config file management)
- Background image, GTK theme name, and cursor theme go in `regreet.toml`.

**Rejected:** A (operator excluded). C (older GTK). D/E (excess scope).

---

### ADR-09: Application Launcher

| Option | Pros | Cons |
|--------|------|------|
| **A. `walker`** (current) | Modular plugins, Lua scripting, dmenu/clipboard/calculator built-in | Younger project; smaller ecosystem |
| **B. `wofi`** | Classic, simple, GTK | Less extensible; aging |
| **C. `fuzzel`** | Very fast, native Wayland, minimal | Less feature-rich; no built-in calculator/clipboard plugin |
| **D. `anyrun`** | Plugin-based (Rust), modern | Plugin ecosystem still small; less battle-tested |
| **E. `rofi-wayland`** | Mature rofi fork with massive plugin pool | X11 heritage; some patches lag rofi mainline |

**Recommended: A (`walker`).** Plugin model and Wayland-first design make it the best fit for an integrated shell experience with cliphist, calc, app launching, and SSH targets unified.

**Rejected:** B (under-featured). C (excellent fallback if walker proves unstable). D (younger than walker; no decisive advantage). E (X11 lineage; matches less well).

---

### ADR-10: AMD Vulkan Stack

| Option | Pros | Cons |
|--------|------|------|
| **A. RADV only** | Mesa-integrated; broadest game support; faster on most titles | Occasional title needs AMDVLK |
| **B. RADV + AMDVLK** | Per-app ICD selection possible | Risk of accidental ICD selection; env var management overhead |
| **C. AMDVLK only** | Closer to AMD's reference behaviour | Slower on Linux gaming; tooling assumes RADV |

**Recommended: A (RADV only).** Install `amdvlk` only if a specific application demands it, and gate via `AMD_VULKAN_ICD=AMDVLK` for just that launcher.

**Rejected:** B (default state; rejected as default policy because silent ICD races have caused real-world regressions). C (community consensus favours RADV for desktop gaming).

---

### ADR-11: Containers / Virtualisation Runtime

The `@vms` subvolume and `@var-lib` subvolume imply both libvirt and container engines. v1.0 did not specify which.

| Option | Pros | Cons |
|--------|------|------|
| **A. Podman (rootless)** | Daemonless; rootless by default; Docker CLI compat (`dockerCompat = true`) | Some Compose features lag Docker |
| **B. Docker** | Industry standard; widest compatibility | Rootful daemon; larger attack surface |
| **C. systemd-nspawn** | Native systemd; lightweight | No container ecosystem (no images from registries by default) |
| **D. None** (libvirt only) | Smallest surface | Loses container workflow |

**For VMs:** `virtualisation.libvirtd.enable = true` with `qemu_kvm` + `virt-manager` (GUI) is the standard choice; no real alternative for KVM on Linux.

**Recommended for containers: A (Podman with `dockerCompat = true`).** Provides `docker` CLI alias, rootless model, and avoids running a privileged daemon.

**Rejected:** B (security profile worse). C (different use case). D (containers are valuable for dev work even if not the primary workflow).

---

### ADR-12: Multi-Monitor / Display Configuration

| Option | Pros | Cons |
|--------|------|------|
| **A. Hyprland `monitor=` directives** | Native; in `hyprland.conf` | Static; no hot-plug profile switching |
| **B. `kanshi`** | Profile-based; reacts to hot-plug; declarative | Extra daemon |
| **C. `wlr-randr` scripts** | Manual control | Imperative; doesn't survive replug |

**Recommended: B (`kanshi`)** for laptops or any machine with docking/external-monitor scenarios; **A (Hyprland directives)** for the fixed-display LXC and any desktop with a single static monitor configuration.

**Rejected:** C (imperative; loses declarative benefit).

---

### ADR-13: Quickshell Configuration Base

**Decided (operator):** Custom QML config, authored from scratch. No vendored upstream.

| Option | Pros | Cons |
|--------|------|------|
| **A. DankMaterialShell** | Material You design; v1.2 released; large feature set | Heavy; opinionated; **rejected — operator wants in-house build** |
| **B. caelestia-shell** | Hyprland-focused; cohesive design language | Smaller community; **rejected — same reason** |
| **C. noctalia-shell** | Minimal aesthetic | Less mature; **rejected** |
| **D. Custom from scratch** ✅ | Total control; learn QML deeply; smallest footprint; no upstream tracking burden | Significant time investment; must implement bar, notifications, OSDs, lock overlay, polkit (optional), wallpaper integration |
| **E. Fork an existing config** | Compromise | Maintenance burden of tracking upstream |

**Recommended: D.** Locked in.

**Module inventory (what the custom Quickshell config must own):**

| Module | Quickshell type / approach | Notes |
|--------|----------------------------|-------|
| Bar | `PanelWindow` + `Variants { model: Quickshell.screens }` | Per-monitor instance |
| Workspaces | `Hyprland` IPC module | `Hyprland.workspaces.values` reactive |
| Active window | `Hyprland.activeToplevel` | Title + class |
| Clock | `Timer` + `Date.now()` | 1 s tick |
| Audio | `Quickshell.Services.Pipewire` | Volume, mute, default sink |
| Network | `Quickshell.Services.SystemTray` or `NetworkManager` D-Bus | |
| Battery | sysfs `/sys/class/power_supply/*` or `UPower` D-Bus | Desktop: omit |
| Notifications | `Quickshell.Services.Notifications.NotificationServer` | See ADR-07 |
| OSDs (volume, brightness) | `PopupWindow` triggered by audio/brightness changes | Auto-hide via `Timer` |
| Wallpaper integration | Spawn `awww` via `Process` on shell startup | Or rely on user systemd unit |
| Tray | `Quickshell.Services.SystemTray` | KStatusNotifierItem + legacy XEmbed via xwayland |
| Lock overlay (optional) | A separate Quickshell QML tree or use `hyprlock` (current) | Choose one |
| Polkit (optional) | `Quickshell.Services.Polkit` | Replaces `hyprpolkitagent` if adopted |

**Suggested starter directory layout:**

```
~/.config/quickshell/
├── shell.qml                 # entry point
├── Bar.qml
├── modules/
│   ├── Clock.qml
│   ├── Workspaces.qml
│   ├── AudioIndicator.qml
│   ├── NetworkIndicator.qml
│   └── Tray.qml
├── notifications/
│   ├── NotificationServer.qml   # singleton, owns the D-Bus service
│   ├── Popup.qml                # per-notification visual
│   └── Center.qml               # history pane (optional)
├── osd/
│   ├── VolumeOsd.qml
│   └── BrightnessOsd.qml
└── theme/
    └── Catppuccin.qml           # colour singleton
```

**Reference reading (not vendor — just to learn QML idioms):**

- Quickshell official docs: <https://quickshell.outfoxxed.me/docs/>
- `outfoxxed`'s personal config (linked from quickshell.outfoxxed.me)
- `vaxry`'s config (Hyprland author)
- `pfaj` / `bdebiase` config
- `flicko`'s config

**Rejected:** A/B/C/E.

---

### ADR-14: Theming Framework

**Decided (operator):** **Stylix**.

| Option | Pros | Cons |
|--------|------|------|
| **A. Stylix** ✅ | One base16 scheme themes ~30 programs automatically (GTK, Qt, Hyprland, Kitty, Neovim, Btop, Bat, Fzf, Starship, Yazi, hyprlock, ...); fonts + cursor + icons in one config; can derive a scheme from a wallpaper image; replaces `nwg-look` and `qt5ct`/`qt6ct` defaults | Adds a flake input; custom Quickshell needs a palette-export bridge (Stylix has no Quickshell target); per-program overrides require `stylix.targets.<x>.enable = false;` opt-out |
| **B. `catppuccin/nix` flake (manual)** | Direct, no abstraction; flavor switch is one line | Each program must be enabled individually; fonts/cursor/icons separate; GTK/Qt drift if not maintained |
| **C. Hand-rolled colour scheme + per-program config files** | Maximum control | Maximum maintenance |
| **D. `base16-nix`** | Pure base16, no opinionated extras | Smaller community than Stylix |

**Recommended: A.** Locked in.

**Architectural consequences:**

- **`catppuccin/nix` is removed from flake inputs.** Stylix consumes base16 schemes directly; the Catppuccin family is available via `base16-schemes` in nixpkgs.
- **`nwg-look` is removed from the package matrix.** Stylix owns GTK theming; a manual switcher would race.
- **`qt5ct` / `qt6ct` are kept as optional fallbacks** — Stylix sets the default Qt style automatically; the *ct tools remain useful for one-off overrides.
- **Quickshell bridge required:** Stylix has no `targets.quickshell.enable`. A custom integration is needed: export the active palette as JSON (Stylix exposes `config.lib.stylix.colors`), symlink it into `~/.config/quickshell/theme/palette.json`, and have a QML `Palette` singleton expose the values to the rest of the shell. This adds one ~50-line QML file and one Home Manager `xdg.configFile` entry.

**Rejected:** B (operator preference for unified theming + reduced per-program config churn). C (maintenance burden). D (smaller ecosystem).

---

### ADR-15: Laptop Sleep / Lid Behavior

`nix-laptop` only. Hibernate is already enabled (v2.3); this ADR decides *when* it triggers and *what* happens on lid close.

Background: AMD laptops use **s2idle** (modern standby), not S3 — suspend leaks measurable power (1–5%/hr). Pure suspend across a weekend drains the battery. Pure hibernate is safe but resume is slow (~10–20 s vs <1 s). `suspend-then-hibernate` combines both: suspend for fast resume during short closes, transition to hibernate after a delay for long closes.

| Option | Lid behaviour | Pros | Cons |
|--------|---------------|------|------|
| **A. `suspend`** | Always suspend | Instant resume | Battery drains over hours; closed-in-bag overnight = morning surprise |
| **B. `hibernate`** | Always hibernate | Zero power use; safest | Slow resume every single lid open; defeats the laptop ergonomic |
| **C. `suspend-then-hibernate`** ✅ | Suspend, then auto-hibernate after delay | Fast resume on short closes; hibernate kicks in for long closes; one declarative knob | Requires AMD s2idle to play nice with hibernate handoff (proven on RDNA + modern kernels) |
| **D. AC/battery asymmetry only** (`suspend` on AC, `hibernate` on battery) | Lid-close behaviour depends on power state | Simple to reason about | Closing the lid for a 5-minute meeting on battery means a slow resume — bad UX |

**Recommended: C with AC override.**

- `services.logind.lidSwitch = "suspend-then-hibernate";`
- `services.logind.lidSwitchExternalPower = "suspend";` (on AC, just suspend — power loss isn't a battery-drain risk when plugged in)
- `services.logind.lidSwitchDocked = "ignore";` (closed lid with external monitor → keep working)
- `/etc/systemd/sleep.conf` (via `systemd.sleep.extraConfig`): `HibernateDelaySec=30min` — short closes (meeting, lunch) stay in suspend; longer closes (overnight, weekend) transition to hibernate.

**Hyprland/hypridle integration:**
- `hypridle` triggers `hyprlock` after 5 min of inactivity (lock screen).
- `hypridle` triggers `systemctl suspend-then-hibernate` after 15 min (independent of lid).
- DPMS off after 7 min.

**Rejected:** A (battery roulette). B (resume tax on every coffee break). D (asymmetry adds cognitive load without solving the on-battery-short-close case).

---

## Operational Note — Bootable ISO on ESP

The 10 GiB ESP is sized to host a rescue ISO so the system can be booted into a recovery environment without an external USB stick. This is non-trivial; there are three viable mechanisms.

| Mechanism | How | Pros | Cons |
|-----------|-----|------|------|
| **A. Direct ISO chainload via systemd-boot** | systemd-boot ≥ 250 supports `type1` entries with `linux` + `initrd` extracted from the ISO. Copy `vmlinuz` + `initrd` + the ISO file to the ESP; reference them in `loader/entries/recovery.conf` with the ISO path as a kernel param. | Fast; native | Requires the ISO's kernel command line to support boot-from-ISO (most NixOS / SystemRescue ISOs do, via `findiso=`); kernel/initrd must be extracted at copy time |
| **B. ISO via `memdisk` (SYSLINUX)** | Use SYSLINUX's `memdisk` loader to load the ISO into RAM | Works with any El Torito ISO | systemd-boot doesn't natively chainload SYSLINUX; needs grub2 as intermediary — defeats systemd-boot decision |
| **C. EDK2 UEFI Shell with `bcfg`** | Drop a UEFI shell (`Shell.efi`) on the ESP; add menu entry; let the user boot the ISO via the shell | Most flexible | Manual at boot time |

**Recommended: A.** Standard systemd-boot loader entry; the operator updates the ISO and extracted kernel/initrd when refreshing rescue media (quarterly is reasonable).

**Sketch of `/boot/loader/entries/recovery.conf`:**

```
title    NixOS Rescue ISO
linux    /recovery/vmlinuz
initrd   /recovery/initrd
options  root=live:CDLABEL=nixos-installer findiso=/recovery/nixos-installer.iso copytoram
```

**Maintenance discipline:**

- Pin a known-good ISO version in a `scripts/refresh-rescue-iso.sh` helper checked into the flake repo. Re-run after major NixOS releases.
- Reserve ~3 GiB for the ISO, ~3 GiB for kernel generations, ~4 GiB buffer.
- Verify the rescue entry boots after each refresh — an untested rescue is hope, not recovery.

---

## Outstanding Decisions & Gaps After Operator Pass

All Tier-1, Tier-2 and most Tier-3 items are now resolved. The remaining Tier-3 items are *deliberately deferred with named trigger conditions* — the document records the condition under which each should be re-evaluated, rather than leaving them as vague "if needed" notes.

### Resolved (cumulative)

| Item | Decision | Version |
|------|----------|---------|
| User account | Primary administrator: **`mboehme`**. Groups: `wheel video audio input networkmanager libvirtd kvm`. Authentication via `hashedPassword` (stored in sops-encrypted secret, not in plain Nix). Bootstrap via `initialHashedPassword` for the very first boot. | v2.2 |
| Hostnames | **`nix-desktop`** (workstation), **`nix-laptop`** (portable). LXC variant deferred — `_lxc/` placeholder under `hosts/`. | v2.2 |
| Locale | `time.timeZone = "Europe/Berlin"`. `i18n.defaultLocale = "en_US.UTF-8"`. German overrides for `LC_TIME`, `LC_PAPER`, `LC_MEASUREMENT`, `LC_MONETARY`, `LC_NUMERIC` → `de_DE.UTF-8`. | v2.2 |
| Keyboard layout | **US** system-wide: console keymap `us`, XKB `us`, Hyprland `input { kb_layout = us }`. | v2.2 |
| Theming framework | **Stylix** (ADR-14). | v2.2 |
| Hibernation scope | **Enabled on both hosts.** Per-host `lv_swap` sized ≥ RAM + 2 GiB. `boot.resumeDevice = "/dev/mapper/vg_system-lv_swap"` + `boot.kernelParams = [ "resume=/dev/mapper/vg_system-lv_swap" ]`. Hibernate image inherits LUKS encryption. | v2.3 |
| `hyprlock` PAM | `security.pam.services.hyprlock = {};` declared. Without it the lockscreen rejects every password. | v2.3 |
| Hyprland source | **Upstream flake** (`github:hyprwm/Hyprland`) with overlay; entire `hypr*` ecosystem version-locked to the flake input. Pin to release tag, bump explicitly. | v2.3 |

**All Tier-1 architectural decisions are now closed.**

### Resolved — Tier 2 (v2.4)

| Item | Decision |
|------|----------|
| **XWayland** | **Enabled.** `programs.hyprland.xwayland.enable = true;` declared on both hosts. Required for some Electron / JetBrains / legacy apps; default value is `true` but the declaration is explicit so the choice can't drift on a Hyprland major bump. |
| **MIME defaults** | **Mapped.** `xdg.mime.defaultApplications` set as: `application/pdf` → `org.pwmt.zathura.desktop`; `text/html`, `x-scheme-handler/{http,https}` → `zen.desktop`; `image/*` → `imv.desktop`; `video/*` and `audio/*` → `mpv.desktop` (VLC kept as compatibility fallback); `inode/directory` → `thunar.desktop`; `text/plain` → `nvim.desktop`. Companion env: `BROWSER=zen`, `EDITOR=nvim`, `VISUAL=nvim`, `TERMINAL=kitty`. |
| **`disko`** | **Adopted.** Per-host `hosts/<name>/disk-config.nix` declares the GPT → LUKS2 → LVM (`vg_system`) → BTRFS subvolume layout via `disko.devices`. Reinstalls become reproducible from the flake. Added as flake input `github:nix-community/disko`. |
| **Quickshell source** | **Upstream flake.** `git+https://git.outfoxxed.me/quickshell/quickshell` pinned to a release tag, not nixpkgs. Same rationale as Hyprland (ADR-13 + Layer 2 ecosystem note): bar-side IPC and service APIs evolve fast, and a custom QML config is most painful when the toolkit lags. |
| **systemd-resolved + DNSSEC** | **Enabled.** `services.resolved.enable = true; services.resolved.dnssec = "allow-downgrade"; services.resolved.fallbackDns = [ "1.1.1.1" "9.9.9.9" ];`. `allow-downgrade` (not `true`) prevents breakage on captive portals and misconfigured corporate networks while still authenticating where possible. |
| **OpenSSH** | **Enabled on `nix-desktop`; client-only on `nix-laptop`.** Asymmetric exposure: the desktop is always-on at home and a useful SSH target; the laptop travels and should not advertise a server. Hardening on `nix-desktop`: `PasswordAuthentication = false`, `KbdInteractiveAuthentication = false`, `PermitRootLogin = "no"`. Authorized keys provisioned via Home Manager + sops-encrypted secrets. |
| **Trash semantics** | **Enabled.** `gvfs` enabled at system level (provides `trash://` for GTK apps including Thunar). `trash-cli` added to user packages (provides `trash-put`/`trash-list`/`trash-restore`). Yazi config points its delete operation at `trash-put` rather than `rm`. |
| **Laptop power management** | **`power-profiles-daemon` retained.** No switch to `tlp` at deploy time. Trigger to revisit: sustained battery life under typical workload drops below 4 hours, or measured idle drain exceeds 10%/hr on battery with lid open. Quickshell exposes a profile switcher widget for runtime control. |
| **Laptop lid behavior** | See **ADR-15.** `suspend-then-hibernate` on battery; `suspend` on AC; `ignore` when docked; `HibernateDelaySec=30min`. |
| **Touchpad config** | **Set in Hyprland `input` block.** `natural_scroll = true`, `tap-to-click = true`, `disable_while_typing = true`, `clickfinger_behavior = true` (two-finger right-click), `scroll_factor = 0.4`. Laptop-only; the desktop's input block omits the `touchpad` section entirely. |

### Resolved — Tier 3 (v2.4)

| Item | Decision |
|------|----------|
| **VPN (WireGuard)** | **Architecturally adopted.** Pattern: laptop (and optionally desktop) is a WireGuard *client*; server lives on the Proxmox host (outside the NixOS fleet). Interface name: `wg-home`. Split-tunnel — only the home LAN CIDR is routed through the tunnel; default route stays on the local NIC. Keys: per-host private key in `secrets/<host>.yaml` (sops-nix); server public key is non-secret config. Wireguard interface declared in `modules/system/vpn.nix`. **Two operator-supplied parameters remain TBD:** the home LAN CIDR, and the Proxmox server's reachable endpoint (DDNS hostname or static IP). These are configuration values, not architectural choices. |

### Deferred — Tier 3, with Named Trigger Conditions (v2.4)

These items are *deliberately* not added now. The trigger column states the single condition under which the architecture should be re-opened to include them.

| Item | Trigger to add |
|------|----------------|
| **Steam / Proton / `gamemode` / `mangohud`** | Operator requests gaming, OR a specific game is purchased. `programs.steam.enable = true;` plus `programs.gamemode.enable = true;` + `mangohud` package. 32-bit Mesa is already declared, so no Layer 1 change. |
| **OBS Studio** | A streaming or recording use case appears. The PipeWire portal (already configured) provides Wayland screen capture; add `obs-studio` only when needed. |
| **Scanner (SANE)** | Operator acquires a scanner. Add `hardware.sane.enable = true;` plus the device-specific backend package. |
| **Printer drivers** | Operator prints something. CUPS is already enabled (Layer 4); only the manufacturer-specific driver package (`gutenprint`, `hplip`, `cnijfilter2`, etc.) is missing. |
| **`hyprcursor` theme** | Cursor scaling looks wrong on a HiDPI display. Until then, Stylix's Xcursor (`bibata-cursors`) is sufficient. |
| **Stylix wallpaper-derived scheme** | Two weeks of stable operation with the static base16 scheme. Then experiment with `stylix.image = ./wallpaper.png;` for auto-derived palettes. Revert if the auto-derived colours are inconsistent. |
| **Email client / chat clients** | Personal preference, not architectural. Add to `modules/apps/` when chosen. |
| **TPM-backed LUKS unlock** | Operator decides to revisit Secure Boot (ADR-05 currently rejects it). TPM-backed unlock without Secure Boot is incomplete protection, so these two move together if at all. |

---

## Complete Package Matrix (corrected)

### Boot & Storage

```text
# Enabled via NixOS options (NOT installed as packages):
#   boot.loader.systemd-boot.enable
#   boot.initrd.luks.devices.<name>
#   hardware.cpu.amd.updateMicrocode

# Userspace tooling:
cryptsetup
btrfs-progs
lvm2
parted
gptfdisk
```

### Wayland Compositor

```text
# Enabled via: programs.hyprland.enable = true
# This pulls hyprland, sets portals, registers session.

xdg-desktop-portal-hyprland       # auto when programs.hyprland.enable
xdg-desktop-portal-gtk
```

### GPU (AMD RDNA)

```text
# Enabled via: hardware.graphics.{enable, enable32Bit} = true
# RADV ships with Mesa automatically.

libva-utils                       # vainfo (debugging)
vulkan-tools                      # vkcube, vulkaninfo (debugging)
# amdvlk                          # OPT-IN only; see ADR-10
```

### UI Layer

```text
quickshell                        # also owns notifications (no mako)
walker
greetd                            # enabled via services.greetd
greetd.regreet                    # GUI greeter (replaces tuigreet)
cage                              # minimal Wayland compositor that hosts regreet
hyprlock                          # PAM service required — see security
hypridle
hyprpolkitagent
awww                              # renamed from swww (Oct 2025)
waypaper
brightnessctl
```

### System Daemons

```text
# Configured via NixOS options:
#   services.pipewire.enable + .pulse + .alsa + .jack
#   services.pipewire.wireplumber.enable
#   hardware.bluetooth.enable
#   networking.networkmanager.enable
#   services.udisks2.enable
#   services.printing.enable
#   services.avahi.enable
#   services.resolved.enable (DNSSEC=allow-downgrade — Tier-2 resolved)
#   services.openssh.enable  (nix-desktop ONLY; hardened — Tier-2 resolved)
#   services.gvfs.enable     (trash:// for GTK apps — Tier-2 resolved)

blueman
networkmanagerapplet
udiskie
cliphist
wl-clipboard
grim
slurp
swappy
gvfs                               # also pulled by services.gvfs.enable
```

### User Applications

```text
# Terminal
kitty

# Files
yazi
xfce.thunar
xfce.thunar-volman
xfce.thunar-archive-plugin

# Browsers (zen-browser via flake input)
chromium

# Office
onlyoffice-desktopeditors

# Media
mpv                                # primary (lightweight, scriptable)
vlc                                # fallback for difficult formats

# Dev
neovim
git
gh
lazygit
direnv
nix-direnv

# Monitoring
btop
mission-center
lm_sensors
nvtopPackages.amd

# Viewing
imv
zathura

# Device integration
kdePackages.kdeconnect-kde

# Archives
unzip
p7zip
unrar                              # unfree

# Shell
# zsh enabled via programs.zsh.enable
starship
atuin
zoxide
fzf

# Modern CLI
ripgrep
fd
bat
eza
jq
yq-go
delta

# Trash (Tier-2 resolved)
trash-cli                          # used by yazi; matches GTK gvfs trash semantics

# Infra
openssh                            # server enabled on nix-desktop only; client on both
rsync
restic
wireguard-tools                    # wg, wg-quick — VPN client (laptop primary user)

# Utilities
wlsunset
wlr-randr
kanshi                             # nix-laptop: mandatory; nix-desktop: optional
```

### Fonts & Theming

```text
# Fonts (note nerd-fonts.* namespace)
nerd-fonts.jetbrains-mono
noto-fonts
noto-fonts-cjk-sans
noto-fonts-emoji
liberation_ttf
dejavu_fonts                       # sans + serif role for Stylix
# inter                            # alternative sans for Stylix

# Theming via Stylix (consumed as flake input: github:danth/stylix)
# Module enabled at NixOS level + Home Manager level.
# Stylix does NOT need a package; it is a module + flake input.

base16-schemes                     # provides Catppuccin (+ many others) as yaml files

# Stylix-managed assets — keep these packages, Stylix references them:
papirus-icon-theme                 # stylix.iconTheme.package source
bibata-cursors                     # stylix.cursor.package source

# Optional Qt overrides (Stylix sets the default — these are fallback escape hatches):
qt5ct
qt6ct
# kdePackages.qtstyleplugin-kvantum  # only if Kvantum-level theming is later wanted

# REMOVED in v2.2:
#   nwg-look                       # Stylix owns GTK; manual switcher would race
#   catppuccin (flake input)       # Stylix consumes base16 schemes directly
```

---

## Configuration Files Structure

```
flake.nix                          # Flake entry point
flake.lock                         # Locked dependencies
.sops.yaml                         # sops-nix routing rules

hosts/
├── nix-desktop/
│   ├── default.nix                # imports + host-specific config
│   ├── hardware-configuration.nix # nixos-generate-config output
│   └── disk-config.nix            # disko config (optional)
├── nix-laptop/
│   ├── default.nix
│   ├── hardware-configuration.nix
│   └── disk-config.nix
└── _lxc/                          # placeholder for future containerised variant
    └── README.md

modules/                           # Composable NixOS modules
├── system/
│   ├── boot.nix                   # systemd-boot, LUKS, microcode, hibernate resume=
│   ├── storage.nix                # disko-driven; filesystems, swap, zram
│   ├── locale.nix                 # tz=Europe/Berlin, LANG=en_US, LC_*=de_DE, kb=us
│   ├── users.nix                  # users.users.mboehme + groups
│   ├── networking.nix             # NM, firewall, ssh (desktop only), resolved+DNSSEC
│   ├── vpn.nix                    # WireGuard client (wg-home), sops-fed keys
│   ├── security.nix               # sudo, polkit, sops, PAM hyprlock
│   └── gc.nix                     # nix.gc, store optimisation
├── desktop/
│   ├── hyprland.nix               # programs.hyprland (from upstream flake), portals, xwayland
│   ├── audio.nix                  # pipewire stack
│   ├── bluetooth.nix
│   ├── printing.nix               # CUPS enabled; drivers deferred (Tier-3 trigger)
│   ├── fonts.nix                  # nerd-fonts.*, noto
│   ├── stylix.nix                 # system-wide theming (consumes base16-schemes)
│   ├── mime.nix                   # xdg.mime.defaultApplications + env (BROWSER, EDITOR, ...)
│   ├── power.nix                  # PPD, logind lid policy (ADR-15), hypridle bridge
│   └── trash.nix                  # gvfs + trash-cli
├── apps/
│   ├── browsers.nix
│   ├── office.nix
│   ├── dev.nix
│   └── media.nix                  # mpv (primary), vlc (fallback)
└── virtualisation/
    ├── libvirt.nix
    └── podman.nix

home/                              # Home Manager modules
├── default.nix                    # imports
├── hyprland/
│   ├── default.nix
│   └── config/
│       ├── hyprland.conf
│       ├── hyprlock.conf
│       └── hypridle.conf
├── quickshell/
│   └── config/                    # custom QML tree (owns bar + notifications)
├── walker/
│   └── config.toml
├── kitty/
│   └── kitty.conf
├── yazi/
│   └── yazi.toml
├── neovim/
│   └── init.lua
├── zsh/
│   └── .zshrc
└── starship/
    └── starship.toml

secrets/                           # sops-encrypted
├── common.yaml
├── nix-desktop.yaml
└── nix-laptop.yaml

overlays/
└── default.nix                    # custom packages / patches
```

> **Naming convention:** `default.nix` per directory enables `imports = [ ./modules/system ./modules/desktop ];` shorthand. v1.0 used per-component filenames at the leaf, which is also valid but loses the directory-import idiom.

---

## System Architecture Summary

| Layer | Primary Technologies | Key Packages |
|-------|----------------------|--------------|
| 1. Boot & Storage | systemd-boot, LUKS2, LVM, BTRFS, **disko** | `cryptsetup`, `lvm2`, `btrfs-progs` |
| 2. Compositor | Hyprland (upstream flake) | `hyprland`, `xdg-desktop-portal-hyprland` (overlay-pinned) |
| 3. UI | Quickshell (QML, upstream flake), walker, hyprlock | `quickshell`, `walker`, `hyprlock`, `awww` (notifications inside Quickshell) |
| 4. Daemons | PipeWire, NetworkManager, BlueZ, **systemd-resolved (DNSSEC)**, **gvfs** | `pipewire`, `wireplumber`, `networkmanager`, `bluez`, `gvfs` |
| 5. Apps | Kitty, Yazi, Zen, Neovim, **mpv** | `kitty`, `yazi`, `chromium`, `neovim`, `mpv` |
| 6. Theming | **Stylix**, Nerd Fonts, Papirus | `nerd-fonts.jetbrains-mono`, `base16-schemes`, `papirus-icon-theme`, `bibata-cursors` |
| 7. Config Mgmt | Flakes + Home Manager + **disko** | `home-manager.nixosModules.home-manager` |
| 8. Security | Firewall, sops-nix, microcode, **PAM-hyprlock**, **systemd-resolved DNSSEC**, **hardened SSH** | `sops`, `age`, `cryptsetup` |
| 9. Ops | nix.gc, btrbk, restic, **WireGuard (laptop)** | `restic`, `btrbk`, `wireguard-tools` |

---

## Multi-Machine Deployment Flow

```
┌────────────────────────────────────────────────────────────────┐
│                    DEVELOPMENT WORKFLOW                        │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  1. EDIT CONFIG                                                │
│     └── flake.nix / modules/** / home/**                       │
│                                                                │
│  2. VALIDATE LOCALLY                                           │
│     ├── nix flake check                                        │
│     ├── nixos-rebuild build --flake .#<host>  (dry build)      │
│     └── nixos-rebuild test --flake .#<host>   (no bootloader)  │
│                                                                │
│  3. APPLY                                                      │
│     └── sudo nixos-rebuild switch --flake .#nix-desktop        │
│                                                                │
│  4. COMMIT & PUSH                                              │
│     ├── git commit -am "feat: …"                               │
│     └── git push gitea main                                    │
│                                                                │
│  5. DEPLOY TO PEER                                             │
│     ├── ssh nix-laptop 'cd /etc/nixos && git pull'             │
│     └── ssh nix-laptop 'sudo nixos-rebuild switch \            │
│                          --flake .#nix-laptop'                 │
│                                                                │
│  6. AUTOMATE (Future)                                          │
│     └── systemd timer on LXC: pull → rebuild → notify          │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

> `nixos-rebuild test` applies the config to the running system without making it the default boot entry — strongly preferred over `switch` for risky changes. Rollback with `nixos-rebuild switch --rollback`.

---

## Backup Strategy

| Source | Tool | Cadence | Destination |
|--------|------|---------|-------------|
| BTRFS subvolumes (`@home`, `@var-lib`, `@gitea`) | `btrbk` → BTRFS snapshots in `@snapshots` | Hourly + daily retention | Local (`@snapshots`) |
| Local snapshots | `restic` over SSH | Daily | Proxmox restic repo (encrypted) |
| `flake.nix` + modules | `git` | Per change | Gitea (Proxmox) |
| ESP / kernel generations | `boot.loader.systemd-boot.configurationLimit = 20` | Automatic on rebuild | Local ESP |

> **Restore test cadence:** quarterly. An untested backup is a hope, not a backup.

---

## Hardware & Compatibility

| Host | Role | CPU | GPU | Driver | Wayland | Hibernate | Notes |
|------|------|-----|-----|--------|---------|-----------|-------|
| `nix-desktop` | Stationary workstation | AMD (Zen) | AMD RDNA (dGPU) | Mesa RADV (`amdgpu` kmod) | Full | **Enabled** | `lv_swap ≥ RAM + 2 GiB`; encrypted via LUKS |
| `nix-laptop` | Portable | AMD (Zen / APU) | AMD RDNA (iGPU) | Mesa RADV (`amdgpu` kmod) | Full | **Enabled (essential)** | `lv_swap ≥ RAM + 2 GiB`; lid-close → hibernate is the expected workflow; kanshi for dock |
| *(future)* `nix-lxc` | Headless container on Proxmox | Host CPU | Virtual / passthrough | Mesa (llvmpipe) | Headless | N/A | Containers don't hibernate; build a headless variant of the flake — exclude desktop layers (2, 3, 6) |

> **Laptop-specific Layer adjustments** (vs. desktop — hibernate is enabled on both, so not listed here):
> - Layer 3: Quickshell battery / brightness / network indicators are mandatory (vs. nice-to-have on the desktop).
> - Layer 4: lid-switch behavior via `services.logind.lidSwitch = "hibernate"` matches the operator's hibernate-on-both decision (suspend is also acceptable; the choice is power-vs-resume-speed).
> - Layer 5: `brightnessctl` actively used; Hyprland input config needs touchpad block (`tap-to-click`, `natural-scroll`, etc.).
> - **ADR-12** (kanshi) moves from "if multi-monitor" to "yes, always" for the laptop.
> - **Power management** retains `power-profiles-daemon`; revisit only if battery life proves insufficient (see Tier 2 in Outstanding Decisions).

> **LXC caveat (when added):** running Hyprland inside an unprivileged LXC requires GPU passthrough and `/dev/dri` access; usually the LXC variant is built as a headless server image and excludes Layers 2, 3, 6 entirely.

---

## Reference Documentation

| Resource | URL |
|----------|-----|
| NixOS Manual | https://nixos.org/manual/nixos/stable/ |
| Nixpkgs Manual | https://nixos.org/manual/nixpkgs/stable/ |
| Nix Flakes | https://nixos.wiki/wiki/Flakes |
| Home Manager Manual | https://nix-community.github.io/home-manager/ |
| Hyprland Wiki (NixOS) | https://wiki.nixos.org/wiki/Hyprland |
| Hyprland Upstream | https://wiki.hypr.land/ |
| Quickshell Docs | https://quickshell.outfoxxed.me/docs/ |
| QML Language Reference | https://doc.qt.io/qt-6/qmlreference.html |
| DankMaterialShell | https://danklinux.com/blog/v1-2-release |
| sops-nix | https://github.com/Mic92/sops-nix |
| lanzaboote (Secure Boot) | https://github.com/nix-community/lanzaboote |
| catppuccin/nix | https://github.com/catppuccin/nix |
| disko (declarative partitioning) | https://github.com/nix-community/disko |

---

**Document Version:** 2.4 — Tier-2 fully resolved; Tier-3 resolved or formally deferred with named triggers
**Operator:** `mboehme` · **Fleet:** `nix-desktop`, `nix-laptop` (LXC deferred)
**Status:** **Architecture frozen — ready to translate into NixOS modules.** No open decisions remain that would change module structure or package selection. Implementation work can begin against this reference.
