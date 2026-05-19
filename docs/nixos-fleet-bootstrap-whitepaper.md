# Bootstrapping the NixOS Fleet — A Practical Whitepaper

**Companion to:** `nixos-architecture-reference-v3.md`
**Audience:** the operator (`mboehme`) executing the v3 architecture against bare hardware
**Scope:** zero → both hosts running the full stack, in defensible phases
**Philosophy:** *land one verifiable layer at a time; never debug five things at once*

---

## 0. How to Read This Document

The architecture reference describes **what** the finished system looks like. This whitepaper describes **how** to get there — broken into phases each of which leaves the system in a known-good, bootable, reversible state.

**Conventions used throughout:**

- **Goal** — what this phase produces.
- **Why** — the first-principles reason this phase exists here, in this order.
- **Steps** — the work to do.
- **Verification** — commands that prove the phase succeeded. *Do not proceed past a failing verification.*
- **Pitfalls** — failure modes that have bitten real operators.
- **Rollback** — how to undo if the phase goes sideways.

**Reading order:** Sequential. Each phase assumes the previous one verified clean. Skipping ahead is the single most common cause of unrecoverable wedged states in flake-driven NixOS deployments.

---

## 1. Mental Model — What You're Actually Building

Before the first command, internalise three ideas. The rest of the whitepaper is mechanical execution; these three ideas are the load-bearing concepts.

### 1.1 The flake is the system; the disk is a cache

In a traditional Linux install, `/etc/nixos/configuration.nix` (or `/etc`, or `/var/lib/...`) is the truth. You edit files in place and the system mutates.

In a flake-driven NixOS install, **the Gitea repo is the truth**. The disk is a materialisation of a specific commit. Anything on disk that isn't in the repo is either (a) state the system generates (logs, caches, user data) or (b) a bug — drift that will silently disappear on the next `nixos-rebuild switch`.

Practical consequence: **never SSH in and "just fix it" with a config edit on the target host**. Either edit in the repo and push-and-rebuild, or you've introduced drift that will bite you on the next sync. The one exception is `/etc/nixos/hardware-configuration.nix` if you keep it on the host — but the architecture commits this file to the repo per host, so even that exception goes away.

### 1.2 `test` before `switch`, always

`nixos-rebuild` has four verbs that matter:

| Verb | What it does | When to use |
|------|--------------|-------------|
| `build` | Evaluates the flake and builds the system closure. Does not activate. | Smoke-test that the config evaluates. |
| `test` | Builds **and** activates on the running system, but does **not** add it to the boot menu. A reboot reverts to the previous generation. | Every non-trivial change. |
| `switch` | Builds, activates, **and** makes it the default boot entry. | Once `test` has run clean. |
| `boot` | Builds and sets it as the default boot entry, but doesn't activate on the running system. Takes effect at next reboot. | Kernel changes that you don't want to activate mid-session. |

The rule: `build` → `test` → use the system for a few minutes → `switch`. The cost is one extra command; the benefit is that a broken activation script (which can wedge your session) is recoverable with a reboot instead of a rescue ISO.

### 1.3 Generations are free; use them

Every `switch` (or `boot`) creates a new generation. Old generations stay on the ESP and in the Nix store until garbage-collected. With `configurationLimit = 20` (per architecture Layer 9), you always have ~20 known-good previous states one bootloader keypress away.

**Practical consequence:** be bold in experimentation. The worst-case outcome of a bad change isn't a broken system; it's a 30-second reboot into the previous generation. This safety net is what makes layer-by-layer iteration cheap.

---

## 2. Prerequisites & Pre-Flight Checklist

### 2.1 What you need before touching hardware

| Item | Purpose | Notes |
|------|---------|-------|
| A working development machine | Where you edit the flake before / between installs | Any Linux, macOS, or even another NixOS box. WSL2 works. |
| Nix installed on that machine | Build and validate the flake without target hardware | Install via Determinate Systems installer or the official installer. The Determinate installer is faster to uninstall cleanly if you decide against it. |
| The Gitea repo created on the Proxmox host | The single source of truth | Empty is fine; the first commit comes from this whitepaper. |
| Two USB sticks (≥ 4 GiB each) | One for the NixOS installer; one as a backup | Get two. The first install always reveals one thing you wish you'd brought a second stick for. |
| The official NixOS installer ISO | Hardware bootstrap | Minimal ISO is sufficient; graphical is unnecessary since we'll install via console. Download from <https://nixos.org/download/>. Pin the version: `nixos-25.05` matches the architecture's stable channel choice. |
| Physical access to both target machines | Console for LUKS passphrase entry on first boot | SSH-based install is possible but more fragile for a first run. |
| Restic repo accessible from the target hosts | First-day backup target | Can be added in Phase 12; doesn't gate earlier phases. |
| Two age keys, one per host (generated later) | sops-nix decryption | Generated in Phase 10 from each host's SSH host key. Not needed earlier. |

### 2.2 Decisions still required from the operator

Two values mentioned in the architecture as TBD must be decided before Phase 10:

- **Home LAN CIDR** (for the WireGuard split-tunnel route). Look it up on your router (e.g. `192.168.1.0/24`).
- **Proxmox WireGuard endpoint** — either a DDNS hostname (e.g. `home.example.duckdns.org:51820`) or a static public IP. If neither is set up yet, Phase 10 will be deferred until it is; the rest of the build is unaffected.

Beyond those, the architecture is frozen. No other choices need to be made mid-build.

### 2.3 Pre-flight sanity checks on the dev machine

```bash
# Nix is installed and flakes are enabled
nix --version
nix flake --help >/dev/null && echo "flakes OK"

# Git is configured (committer identity)
git config --global user.name
git config --global user.email

# You can reach the Gitea repo
git ls-remote ssh://git@<gitea-host>:<port>/<user>/nix-config.git
```

If any of those fail, fix them before continuing. The rest of the whitepaper assumes they pass.

---

## 3. Phase 1 — Repository Skeleton (no hardware yet)

### Goal

A flake repository that evaluates cleanly (`nix flake check` passes) and contains the directory structure from the architecture's "Configuration Files Structure" section — but with empty or stub modules. **No target hardware is touched in this phase.**

### Why this comes first

Two reasons:

1. **The hardware install will consume this repo.** Doing the install with a half-finished flake means debugging the flake on a console with no clipboard, no editor of choice, and a 60-second penalty per evaluation cycle. Iterating on the flake from your existing dev machine is 10× faster.
2. **Empty-stub evaluation catches structural errors early.** If `nix flake check` fails on an empty module tree, no amount of hardware will fix it.

### Steps

#### 3.1 Clone the empty Gitea repo

```bash
git clone ssh://git@<gitea-host>:<port>/<user>/nix-config.git
cd nix-config
```

#### 3.2 Create the directory skeleton

```bash
mkdir -p hosts/{nix-desktop,nix-laptop,_lxc}
mkdir -p modules/{system,desktop,apps,virtualisation}
mkdir -p home/{hyprland/config,quickshell/config,walker,kitty,yazi,neovim,zsh,starship,fastfetch}
mkdir -p secrets overlays
touch hosts/_lxc/README.md
```

#### 3.3 Write the initial `flake.nix`

This is the *minimal* flake that evaluates cleanly with stubs in place. It will grow over the build, but starting minimal is critical — every input you add is a debugging surface you don't yet need.

```nix
{
  description = "mboehme/nix-config — multi-host NixOS fleet";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Inputs added in later phases (commented out until needed):
    #
    # hyprland.url = "github:hyprwm/Hyprland/v0.51.1";
    # quickshell.url  = "git+https://git.outfoxxed.me/quickshell/quickshell?ref=v<TBD>";
    # stylix         = { url = "github:danth/stylix"; inputs.nixpkgs.follows = "nixpkgs"; };
    # sops-nix       = { url = "github:Mic92/sops-nix"; inputs.nixpkgs.follows = "nixpkgs"; };
    # helium         = { url = "github:oxcl/nix-flake-helium-browser"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, home-manager, disko, ... }@inputs:
  let
    system = "x86_64-linux";

    mkHost = hostname: nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs; };
      modules = [
        disko.nixosModules.disko
        ./hosts/${hostname}
        ./modules/system
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = { inherit inputs; };
        }
      ];
    };
  in {
    nixosConfigurations = {
      nix-desktop = mkHost "nix-desktop";
      nix-laptop  = mkHost "nix-laptop";
    };
  };
}
```

**Notes on this skeleton:**

- `inputs.<x>.inputs.nixpkgs.follows = "nixpkgs"` is the canonical pattern to prevent each flake input from pulling in its own nixpkgs copy. Without it, the closure inflates and version skew creeps in.
- `specialArgs = { inherit inputs; }` lets every module reference `inputs.<name>` directly — useful for the Hyprland overlay later.
- Home Manager is wired as a NixOS module per **ADR-01** (system-module integration).
- The commented-out inputs are added in their respective phases; uncommenting them all now would force you to debug them all simultaneously.

#### 3.4 Write the stub host files

`hosts/nix-desktop/default.nix`:

```nix
{ inputs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  networking.hostName = "nix-desktop";
  system.stateVersion = "25.05";
}
```

`hosts/nix-laptop/default.nix` — identical with hostname swapped.

#### 3.5 Write `modules/system/default.nix`

```nix
{ ... }:
{
  imports = [
    ./locale.nix
    ./users.nix
  ];

  # Architecture Layer 9 — flake/GC settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Bootloader (ADR-05: systemd-boot only). Enabled fleet-wide here so the
  # Phase 1 skeleton already satisfies the NixOS bootloader assertion;
  # without an explicit bootloader, evaluation falls back to GRUB and then
  # fails because `boot.loader.grub.devices` is unset.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;
}
```

> 💡 Putting the bootloader settings in `modules/system/default.nix` rather than in each host file follows the rule that *fleet-wide concerns live in the fleet-wide module*. Both hosts use systemd-boot per ADR-05; there is nothing per-host about it. Phase 4 (§6.2) therefore does **not** repeat these lines in the host's expanded `default.nix`.

`modules/system/locale.nix`:

```nix
{ ... }:
{
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME        = "de_DE.UTF-8";
    LC_PAPER       = "de_DE.UTF-8";
    LC_MEASUREMENT = "de_DE.UTF-8";
    LC_MONETARY    = "de_DE.UTF-8";
    LC_NUMERIC     = "de_DE.UTF-8";
  };
  console.keyMap = "us";
  services.xserver.xkb.layout = "us";
}
```

`modules/system/users.nix`:

```nix
{ ... }:
{
  users.users.mboehme = {
    isNormalUser = true;
    description = "Matthias Böhme";
    extraGroups = [
      "wheel"
      "video"
      "audio"
      "input"
      "networkmanager"
      "libvirtd"
      "kvm"
      "dialout"   # required by bazecor (Dygma keyboards)
    ];
    shell = null;  # zsh added in Phase 7
    # Bootstrap password — replaced by sops-managed hashedPassword in Phase 10.
    # Generate with: mkpasswd -m yescrypt
    initialHashedPassword = "REPLACE_ME";
  };
}
```

> ⚠ The `initialHashedPassword = "REPLACE_ME"` is intentional — `nix flake check` will pass with the literal string, and you'll generate the real hash in Phase 4. This stub form prevents the temptation to commit a real password hash in plaintext now and forget to rotate it.

#### 3.6 Write placeholder hardware files

The real `hardware-configuration.nix` is generated *on the target host* during install. For now, write a stub so the flake evaluates:

`hosts/nix-desktop/hardware-configuration.nix`:

```nix
{ ... }:
{
  # Placeholder — replaced by `nixos-generate-config --show-hardware-config`
  # output during Phase 4.
  boot.initrd.availableKernelModules = [ ];
  boot.kernelModules = [ ];
  hardware.enableRedistributableFirmware = true;
  nixpkgs.hostPlatform = "x86_64-linux";

  # Phase 1 stub: satisfies the `fileSystems."/"` assertion so the flake
  # evaluates. The real entry comes from `nixos-generate-config` in Phase 4
  # and will point at the @root BTRFS subvolume on /dev/mapper/vg_system-lv_root.
  fileSystems."/" = {
    device = "/dev/disk/by-label/PLACEHOLDER";
    fsType = "ext4";
  };
}
```

Same for `nix-laptop`.

> 💡 Why the stub is needed: NixOS 25.05 hard-asserts that `fileSystems."/"` is defined as part of `system.build.toplevel`. Without a stub, `nix flake check --no-build` aborts with *"The 'fileSystems' option does not specify your root file system."* The `by-label/PLACEHOLDER` device is intentionally bogus — it will never be mounted, because Phase 4 overwrites this file wholesale before any `nixos-rebuild switch` ever runs.

#### 3.7 Write a placeholder disk-config

The full disko schema lands in Phase 3. For Phase 1, a placeholder is enough:

`hosts/nix-desktop/disk-config.nix`:

```nix
{ ... }:
{
  # Replaced by full disko schema in Phase 3.
  disko.devices = { };
}
```

Same for `nix-laptop`.

#### 3.8 First commit

```bash
git add .
git commit -m "feat: repo skeleton (Phase 1)"
git push origin main
```

### Verification

```bash
# From the dev machine, in the repo root:
nix flake check --no-build
```

Expected: no errors, just warnings about missing optional outputs (`devShells`, `formatter`). If you see *evaluation* errors, fix them before any hardware work.

```bash
# Also verify the configurations evaluate:
nix eval .#nixosConfigurations.nix-desktop.config.system.build.toplevel.drvPath
nix eval .#nixosConfigurations.nix-laptop.config.system.build.toplevel.drvPath
```

These should print a `/nix/store/...drv` path each. If they error, the flake structure is wrong.

### Pitfalls

- **Forgetting to `git add` new files** — Nix flakes only see files tracked by git. An untracked `default.nix` is invisible to `nix flake check`, which then fails with a confusing "file not found" error. Always `git add` before evaluating.
- **Using `nixos-unstable` on the laptop and `nixos-25.05` on the desktop** — possible, but every shared module is now a potential breakage point on channel bumps. The architecture says stable for `nix-desktop`; the same applies to the laptop unless there's a hardware-specific reason to diverge.

### Rollback

`git reset --hard HEAD` and start the phase over. Nothing on hardware to undo.

---

## 4. Phase 2 — Install Media & Hardware Bootstrap

### Goal

Each target machine boots into the NixOS installer, network is up, and you can reach the Gitea repo. No installation is performed in this phase yet — only proving that the installer environment works.

### Why a separate phase

Three things can go wrong in the first 15 minutes of any Linux install: firmware/UEFI quirks, network drivers, and storage device naming. Catching these *before* you start partitioning means you don't have a half-encrypted disk when you discover the laptop's Wi-Fi card needs a firmware blob.

### Steps

#### 4.1 Build the installer USB

```bash
# Verify the ISO checksum against nixos.org
sha256sum nixos-minimal-25.05.<build>-x86_64-linux.iso

# Write to USB (replace /dev/sdX — confirm with lsblk!)
sudo dd if=nixos-minimal-25.05.<build>-x86_64-linux.iso \
        of=/dev/sdX bs=4M status=progress conv=fsync
```

#### 4.2 UEFI settings on each target

Enter firmware setup (usually F2, F10, or Del at POST) and confirm:

| Setting | Required value |
|---------|----------------|
| Boot mode | **UEFI only** (not Legacy/CSM) |
| Secure Boot | **Disabled** (per ADR-05) |
| Fast Boot | Disabled (avoids the boot-from-USB-keypress race) |
| SATA mode | AHCI (not RAID, unless you specifically want hardware RAID) |
| TPM | Optional — leave at default; not used until/unless ADR-05 is revisited |

#### 4.3 Boot the installer

Boot from USB. You'll land at a root shell on the installer.

```bash
# Confirm UEFI boot (this directory exists only under UEFI):
ls /sys/firmware/efi/efivars >/dev/null && echo "UEFI OK"

# Bring up networking — Ethernet is automatic via DHCP.
# For Wi-Fi:
sudo systemctl start wpa_supplicant
wpa_cli
> add_network
> set_network 0 ssid "YourSSID"
> set_network 0 psk "YourPassword"
> enable_network 0
> quit
```

Alternative for Wi-Fi (often easier):

```bash
sudo systemctl start NetworkManager
nmcli device wifi connect "YourSSID" password "YourPassword"
```

#### 4.4 Verify connectivity to Gitea

```bash
ping -c 3 1.1.1.1                                    # basic Internet
ping -c 3 <gitea-host>                                # DNS + LAN/WAN reachability
nix-shell -p git --command "git ls-remote ssh://git@<gitea-host>:<port>/<user>/nix-config.git"
```

If the SSH probe fails, either:
- Set up SSH keys on the installer (`mkdir ~/.ssh && curl -o ~/.ssh/id_ed25519 <url> ...`), or
- Use HTTPS clone with a personal access token for this bootstrap.

### Verification

You can run `git clone <repo-url>` from the installer shell and `cd` into it. Don't proceed past this point until that works on both machines.

### Pitfalls

- **Realtek Wi-Fi chipsets needing firmware** that's blocked behind `nixos.allowUnfree`. The official installer ISO bundles redistributable firmware, so this usually works out of the box — but if Wi-Fi fails to associate, fall back to a tethered phone or Ethernet.
- **Disk device names vary**: `/dev/sda` on SATA, `/dev/nvme0n1` on NVMe. The disko config in Phase 3 hardcodes one of these per host. Verify with `lsblk` on each target *before* writing the disko schema.

### Rollback

Reboot. Nothing has been written to the target disks yet.

---

## 5. Phase 3 — Disko-Driven Disk Layout

### Goal

Each host's `disk-config.nix` declares the full GPT → LUKS2 → LVM → BTRFS layout from the architecture. Disko applies it. The disks are partitioned, encrypted, formatted, and mounted at `/mnt`, ready for the NixOS install in Phase 4.

### Why disko, not manual partitioning

The architecture chose disko (Tier-2 resolved). The reason matters: **with disko, a reinstall is `disko --mode disko <flake>#<host>` — no manual `parted`, `cryptsetup`, `pvcreate`, `lvcreate`, `mkfs.btrfs`, `btrfs subvolume create` chain to remember or fat-finger.** The same schema that built the system the first time rebuilds it identically.

The trade-off is one-time complexity: the disko schema is more verbose than the imperative commands. But the schema is committed to git; the commands are not.

### Steps

#### 5.1 Identify the target disk on each host

On each target, from the installer shell:

```bash
lsblk -d -o NAME,SIZE,MODEL,TRAN
```

Note the device path (e.g. `/dev/nvme0n1` for an NVMe SSD).

#### 5.2 Identify RAM size

```bash
free -h | awk '/^Mem:/ {print $2}'
```

Note this — the swap LV is sized to **RAM + 2 GiB** for hibernation headroom (per architecture Layer 1). E.g. 32 GiB RAM → 34 GiB swap.

#### 5.3 Write `hosts/nix-desktop/disk-config.nix`

This is a faithful translation of the architecture's storage stack. **Verify the device path and swap size for your hardware before applying.**

```nix
{ ... }:
let
  # ↓↓↓ EDIT THESE TWO VALUES PER HOST ↓↓↓
  diskDevice = "/dev/nvme0n1";   # from `lsblk`
  swapSize   = "34G";            # RAM + 2 GiB
  # ↑↑↑ EDIT THESE TWO VALUES PER HOST ↑↑↑

  btrfsMountOpts = [
    "compress=zstd:3"
    "noatime"
    "ssd"
    "space_cache=v2"
    "discard=async"
  ];
  btrfsNoCowOpts = [
    "noatime"
    "ssd"
    "space_cache=v2"
    "discard=async"
    "nodatacow"
  ];
in
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = diskDevice;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "10G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              # initrdUnlock = true is the disko default — included for clarity:
              extraOpenArgs = [ "--allow-discards" ];
              settings = {
                allowDiscards = true;
                # Persist a keyfile inside the LUKS header? No — passphrase only.
              };
              content = {
                type = "lvm_pv";
                vg = "vg_system";
              };
            };
          };
        };
      };
    };

    lvm_vg.vg_system = {
      type = "lvm_vg";
      lvs = {
        lv_swap = {
          size = swapSize;
          content = {
            type = "swap";
            resumeDevice = true;   # ← critical for hibernate
          };
        };
        lv_root = {
          size = "100%FREE";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "@root"      = { mountpoint = "/";              mountOptions = btrfsMountOpts;  };
              "@nix"       = { mountpoint = "/nix";           mountOptions = btrfsMountOpts;  };
              "@home"      = { mountpoint = "/home";          mountOptions = btrfsMountOpts;  };
              "@var-log"   = { mountpoint = "/var/log";       mountOptions = btrfsMountOpts ++ [ "nodatacow" ]; };
              "@var-lib"   = { mountpoint = "/var/lib";       mountOptions = btrfsMountOpts;  };
              "@vms"       = { mountpoint = "/var/lib/libvirt"; mountOptions = btrfsNoCowOpts; };
              "@gitea"     = { mountpoint = "/var/lib/gitea"; mountOptions = btrfsMountOpts;  };
              "@snapshots" = { mountpoint = "/.snapshots";    mountOptions = btrfsMountOpts;  };
            };
          };
        };
      };
    };
  };
}
```

Copy this file to `hosts/nix-laptop/disk-config.nix`, adjusting `diskDevice` and `swapSize` for the laptop's hardware.

> ⚠ **Disko schema is versioned.** This snippet matches disko as of the input pinned in `flake.lock`. If you bump disko later, re-read its README — the option names have evolved (e.g. early disko used `disko.devices.disk.<name>.imageSize`, removed in modern releases). Run `nix flake show github:nix-community/disko` to inspect current option types if uncertain.

#### 5.4 Commit and push from the dev machine

```bash
git add hosts/{nix-desktop,nix-laptop}/disk-config.nix
git commit -m "feat: disko schemas per host (Phase 3)"
git push
```

#### 5.5 On each target, apply disko

From the installer shell:

```bash
sudo -i

# Pull the repo
nix-shell -p git
git clone ssh://git@<gitea-host>:<port>/<user>/nix-config.git /mnt-config
cd /mnt-config

# Apply disko — this will DESTROY ALL DATA on the target disk.
# Triple-check `diskDevice` in disk-config.nix matches the actual hardware.
nix --experimental-features 'nix-command flakes' run \
    github:nix-community/disko -- \
    --mode disko \
    --flake .#nix-desktop          # or .#nix-laptop, on that host
```

You'll be prompted for the LUKS passphrase. **Use a strong one. There's no recovery.** Optionally enrol a second passphrase later with `cryptsetup luksAddKey`.

### Verification

After disko exits clean:

```bash
lsblk -f
# Expect to see:
#   nvme0n1 (or sda)
#   ├─nvme0n1p1   vfat  ...  (ESP)
#   └─nvme0n1p2   crypto_LUKS
#     └─cryptroot LVM2_member
#       ├─vg_system-lv_swap   swap
#       └─vg_system-lv_root   btrfs

mount | grep /mnt
# Expect /mnt, /mnt/boot, /mnt/nix, /mnt/home, ... all mounted.

btrfs subvolume list /mnt
# Expect @root, @nix, @home, @var-log, @var-lib, @vms, @gitea, @snapshots
```

If the swap LV isn't formatted as swap or `resumeDevice` was missed, hibernate will silently fail in Phase 4 — fix here, not later.

### Pitfalls

- **Wrong device path.** Disko will happily wipe the wrong disk if `diskDevice` points at, say, the USB stick you're booted from. Re-run `lsblk` immediately before the disko command.
- **Nested mount order.** `/var/lib/libvirt` is a child of `/var/lib`. Disko handles ordering automatically *if the schema is correct*; manual mount commands can race. If you ever mount manually, mount `@var-lib` first.
- **`nodatacow` doesn't apply retroactively.** Once a CoW file exists in `@vms` or `@var-log`, setting `nodatacow` won't undo CoW for that file. Disko creates these subvolumes empty, so the option takes effect on all files written into them — but if you later move existing VM images in, run `chattr +C` per file.

### Rollback

Reboot, boot installer again, re-run disko. There's no recovery of pre-disko disk contents — by design.

---

## 6. Phase 4 — First Boot: Minimal Viable System

### Goal

The target boots from disk, unlocks LUKS, brings up networking, accepts SSH (on `nix-desktop` only — laptop is client-only per architecture), and lets you log in as `mboehme`. No desktop yet. No Hyprland. No fonts. Just a TTY login over console or SSH.

### Why minimal

Every additional module is a debugging surface. Booting the smallest possible system first means that if it doesn't boot, you have ~10 modules to suspect, not ~80. Once it boots, you add layers with confidence.

### Steps

#### 6.1 Generate `hardware-configuration.nix` on the target

With `/mnt` still mounted from Phase 3:

```bash
nixos-generate-config --root /mnt --show-hardware-config
```

This prints a hardware config to stdout. **Copy it into the repo on the dev machine** at `hosts/<host>/hardware-configuration.nix`, replacing the placeholder from Phase 1 (including the Phase 1 `fileSystems."/"` stub — the generated file carries the real entry pointing at the `@root` subvolume).

You can do this in several ways; the cleanest is:

```bash
# On target:
nixos-generate-config --root /mnt --show-hardware-config \
  > /mnt-config/hosts/nix-desktop/hardware-configuration.nix
cd /mnt-config
git add hosts/nix-desktop/hardware-configuration.nix
git -c user.email="installer@nix-desktop" -c user.name="installer" \
    commit -m "feat(nix-desktop): hardware-configuration"
git push
```

**Inspect the generated file before committing.** Specifically:

- `fileSystems."/"` should reference the `@root` subvolume on `/dev/mapper/vg_system-lv_root`. If it doesn't, disko's mount didn't propagate; debug before installing.
- `boot.initrd.luks.devices.<name>.device` should reference the LUKS UUID. If it's missing, the initrd won't unlock the disk.
- `swapDevices` should reference `/dev/mapper/vg_system-lv_swap`.

#### 6.2 Expand the host's `default.nix` to a minimal-bootable system

Edit `hosts/nix-desktop/default.nix`:

```nix
{ inputs, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  networking.hostName = "nix-desktop";
  system.stateVersion = "25.05";

  # ── Boot (Architecture Layer 1 + ADR-05) ─────────────────────────────────
  # systemd-boot itself (`enable`, `configurationLimit`, `canTouchEfiVariables`)
  # is declared fleet-wide in `modules/system/default.nix`. Per-host boot
  # concerns — LUKS unlock, hibernate resume, kernel — stay here.
  boot.initrd.luks.devices.cryptroot = {
    # device = "/dev/disk/by-uuid/..."  ← already set by hardware-configuration.nix
    allowDiscards = true;
    preLVM = true;
  };

  # Hibernate resume (Architecture Layer 1)
  boot.resumeDevice = "/dev/mapper/vg_system-lv_swap";
  boot.kernelParams = [ "resume=/dev/mapper/vg_system-lv_swap" ];

  # Kernel (ADR-03 — recommendation B)
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # CPU microcode (AMD)
  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # ── Networking ───────────────────────────────────────────────────────────
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;
  networking.nftables.enable = true;   # ADR-16 sub-decision

  # ── SSH (Tier-2: desktop = server, laptop = client-only) ─────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
    # openFirewall = true is the default — opens TCP 22.
  };

  # zram (ADR-04 — recommendation E)
  zramSwap.enable = true;
}
```

For `nix-laptop`, the same minus `services.openssh.enable` — or with `services.openssh.enable = false;` and `services.openssh.startWhenNeeded = false;` to make the intent explicit.

#### 6.3 Generate the real password hash

On the dev machine or installer:

```bash
nix-shell -p mkpasswd --command "mkpasswd -m yescrypt"
# Type the desired password twice; copy the resulting hash.
```

Edit `modules/system/users.nix` and replace `initialHashedPassword = "REPLACE_ME"` with `initialHashedPassword = "$y$j9T$...your hash..."`.

> 🔒 This hash will be **plaintext in the git repo** until Phase 10 moves it under sops-nix. That's acceptable for the bootstrap because:
> - The hash is not the password; it's a yescrypt KDF of it.
> - It will move to sops within hours/days.
> - The repo is on a private Gitea instance, not public GitHub.
>
> Don't reuse a real personal password here. Use a strong bootstrap password and rotate it the moment Phase 10 is done.

#### 6.4 Provision the SSH authorized key

In `modules/system/users.nix`, add to the `mboehme` user block:

```nix
openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAA...yourkey... mboehme@dev-machine"
];
```

Use your **dev machine's** public key, not anything from the target.

#### 6.5 Commit and install

```bash
# Dev machine:
git add .
git commit -m "feat: minimal bootable system + hardware config (Phase 4)"
git push

# Target (still in installer shell, with /mnt mounted):
cd /mnt-config
git pull

sudo nixos-install --flake .#nix-desktop --no-root-password
# (or .#nix-laptop on the laptop)
```

`nixos-install` will:

1. Evaluate the flake.
2. Build the entire system closure (this is the longest step — 10-30 min depending on cache hit rate).
3. Copy it into `/mnt/nix/store`.
4. Install the bootloader to the ESP.
5. Prompt for the root password — type **nothing** and hit enter (the `--no-root-password` flag plus declared user is sufficient; root stays locked).

When it exits clean, reboot:

```bash
sudo reboot
```

Remove the USB stick during POST.

### Verification

After reboot:

1. **systemd-boot menu appears.** A 5-second countdown to "NixOS - Default".
2. **LUKS passphrase prompt.** Type the passphrase from Phase 3.
3. **A console login appears** for the host (e.g. `nix-desktop login:`).
4. Login as `mboehme` with the bootstrap password.

```bash
# Smoke-test from the desktop's console:
ip a                                    # network is up
ping -c 3 1.1.1.1                       # Internet reachable
hostname                                # nix-desktop
nixos-rebuild --flake /etc/nixos#nix-desktop dry-build  # flake works locally
```

> Note: `/etc/nixos` may or may not exist depending on how you cloned. You can either symlink it (`sudo ln -s /home/mboehme/nix-config /etc/nixos`) or always specify the flake path explicitly. The architecture's deployment flow uses `/etc/nixos`; pick one and stick with it.

From the dev machine:

```bash
ssh mboehme@<nix-desktop-ip>
# Should let you in via key, no password prompt.
```

If SSH key auth fails, debug *now* — it gets harder once the desktop session is mediating things.

### Pitfalls

- **`boot.resumeDevice` missing.** Hibernate will fail silently — `systemctl hibernate` returns success but the system suspends instead of hibernating. Verify with `journalctl -b -1 | grep -i hibernate` after a hibernate attempt.
- **`hardware-configuration.nix` regenerated automatically.** It isn't. Once committed, it's static. If you change disks, regenerate explicitly.
- **`system.stateVersion` mismatch.** Keep it at `25.05` to match the channel; never bump retroactively on existing hosts (it changes default values of stateful options).

### Rollback

Boot from the installer USB again. Mount `/mnt/boot`. Edit the systemd-boot loader entries to remove the broken generation, or just `disko` and reinstall — Phase 3 produces deterministic output.

---

## 7. Phase 5 — Layer 2: Hyprland Compositor

### Goal

Hyprland comes up on each host. The user logs in via regreet (GUI greeter) and sees an empty Hyprland desktop — a blank wallpaper-coloured screen with a working terminal launched via keybind. No bar yet (that's Phase 6).

### Why this layer next

Hyprland is the foundation everything visual sits on. Validating it in isolation — without Quickshell, without Stylix, without walker — means that *if* something later breaks the visual stack, you know the compositor itself is healthy. This is the layer with the most external-flake risk; isolating it is high-value.

### Steps

#### 7.1 Add the Hyprland flake input

Edit `flake.nix`:

```nix
inputs = {
  # ... existing inputs ...
  hyprland = {
    url = "github:hyprwm/Hyprland?ref=v0.51.1";   # pin to release tag
    # NOTE: do NOT use inputs.nixpkgs.follows here — Hyprland needs its own
    # nixpkgs for the upstream-built binaries to match the binary cache.
    # Following nixpkgs forces a local rebuild of the entire hypr* stack.
  };
};
```

> **Why not `inputs.nixpkgs.follows`?** The Hyprland upstream flake publishes binary cache entries built against *their* pinned nixpkgs. Overriding the follow re-evaluates everything against your nixpkgs and misses the cache, forcing a 30-60 minute local C++ rebuild. The downside of *not* following is closure inflation — usually a fair trade.

Pass `inputs` through to the desktop module — already wired via `specialArgs` in Phase 1.

#### 7.2 Create `modules/desktop/hyprland.nix`

```nix
{ inputs, pkgs, ... }:
{
  # Apply the Hyprland flake's overlay — replaces all hypr* packages in pkgs
  # with the version-locked upstream builds.
  nixpkgs.overlays = [ inputs.hyprland.overlays.default ];

  # Architecture Layer 2 — enable the compositor + portals + session entry.
  programs.hyprland = {
    enable = true;
    package = inputs.hyprland.packages.${pkgs.system}.hyprland;
    portalPackage = inputs.hyprland.packages.${pkgs.system}.xdg-desktop-portal-hyprland;
    xwayland.enable = true;   # Tier-2 resolved
  };

  # GTK portal fallback for file pickers, OpenURI, etc.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # Architecture Layer 2 — AMD GPU
  hardware.graphics = {
    enable = true;
    enable32Bit = true;        # 32-bit ABI (Steam/Proton path; harmless to enable now)
  };

  # PAM service for hyprlock — REQUIRED, or every password is rejected.
  security.pam.services.hyprlock = { };

  # Lockscreen, idle, polkit
  programs.hyprlock.enable = true;
  services.hypridle.enable = true;
  security.polkit.enable = true;
  systemd.user.services.hyprpolkitagent = {
    description = "Hyprland Polkit Agent";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
      Restart = "on-failure";
    };
  };
}
```

#### 7.3 Add the greeter — `modules/desktop/greeter.nix`

```nix
{ pkgs, ... }:
{
  # ADR-08: regreet under cage
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.cage}/bin/cage -s -- ${pkgs.greetd.regreet}/bin/regreet";
        user = "greeter";
      };
    };
  };
  programs.regreet.enable = true;
}
```

#### 7.4 Update `modules/system/default.nix` to import the desktop tree

```nix
{ ... }:
{
  imports = [
    ./locale.nix
    ./users.nix
    ../desktop/hyprland.nix
    ../desktop/greeter.nix
  ];
  # ... rest unchanged ...
}
```

#### 7.5 Add a minimal Hyprland config via Home Manager

Create `home/default.nix`:

```nix
{ ... }:
{
  home-manager.users.mboehme = { pkgs, ... }: {
    home.username = "mboehme";
    home.homeDirectory = "/home/mboehme";
    home.stateVersion = "25.05";

    imports = [
      ./hyprland
    ];

    # Minimal package set — bar/launcher come later.
    home.packages = with pkgs; [
      kitty
      wl-clipboard
    ];

    programs.home-manager.enable = true;
  };
}
```

Create `home/hyprland/default.nix`:

```nix
{ inputs, pkgs, ... }:
{
  wayland.windowManager.hyprland = {
    enable = true;
    package = inputs.hyprland.packages.${pkgs.system}.hyprland;

    settings = {
      # Architecture-aligned minimum config.
      "$mod" = "SUPER";

      input = {
        kb_layout = "us";
        follow_mouse = 1;
      };

      monitor = [ ",preferred,auto,1" ];   # auto-detect all outputs

      bind = [
        "$mod, Return, exec, kitty"
        "$mod, Q, killactive,"
        "$mod, M, exit,"
        "$mod, F, fullscreen,"
        # Workspaces 1-9
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod SHIFT, 1, movetoworkspace, 1"
        "$mod SHIFT, 2, movetoworkspace, 2"
        "$mod SHIFT, 3, movetoworkspace, 3"
      ];

      # Solid colour background so the screen isn't black — debugging aid.
      misc = {
        background_color = "rgb(1e1e2e)";
        disable_hyprland_logo = true;
      };
    };
  };
}
```

Wire `./home` into the host:

In `hosts/nix-desktop/default.nix`, add:

```nix
imports = [
  ./hardware-configuration.nix
  ./disk-config.nix
  ../../home          # ← new
];
```

> **Laptop-specific addition.** In `hosts/nix-laptop/default.nix` (or a laptop-specific module imported by it), add the touchpad block per the architecture Tier-2 row:
>
> ```nix
> wayland.windowManager.hyprland.settings.input = {
>   touchpad = {
>     natural_scroll = true;
>     tap-to-click = true;
>     disable_while_typing = true;
>     clickfinger_behavior = true;
>     scroll_factor = 0.4;
>   };
> };
> ```

#### 7.6 Build → test → switch

From the dev machine:

```bash
git add . && git commit -m "feat: Hyprland (Phase 5)" && git push
```

On the target (over SSH for the desktop, console for the laptop):

```bash
cd /etc/nixos   # or wherever the repo lives
git pull
sudo nixos-rebuild build --flake .#nix-desktop  # evaluation + closure build
sudo nixos-rebuild test  --flake .#nix-desktop  # activate without making default
```

If `test` succeeds, reboot — the greeter will take the screen at boot. Log in as `mboehme`. You should land in a blank Hyprland desktop with the `$mod+Return` keybind opening kitty.

```bash
sudo nixos-rebuild switch --flake .#nix-desktop  # make it the boot default
```

### Verification

From the kitty terminal in the running Hyprland session:

```bash
echo $XDG_SESSION_TYPE                     # → wayland
echo $XDG_CURRENT_DESKTOP                  # → Hyprland
hyprctl version                            # → matches the flake's pinned tag
hyprctl monitors                           # lists your monitor(s)

# Portal sanity:
busctl --user list | grep portal
# Expect both org.freedesktop.portal.Desktop and ...portal.Hyprland

# AMD GPU:
glxinfo -B | grep -i renderer              # RADV / radeonsi
vulkaninfo --summary 2>&1 | grep deviceName  # AMD RADV ...
```

Lock-screen smoke test:

```bash
hyprlock
# Type your bootstrap password. It should unlock. If it doesn't, the PAM
# service for hyprlock isn't registered — re-check Phase 7.2 of this guide.
```

### Pitfalls

- **Skipping the overlay.** Without `nixpkgs.overlays = [ inputs.hyprland.overlays.default ];`, you'll have Hyprland from the flake but `xdg-desktop-portal-hyprland` from nixpkgs — version-skewed. Screen sharing breaks silently.
- **`programs.hyprland.package = ...` missing.** NixOS pulls nixpkgs' Hyprland by default. The architecture wants the upstream-flake version; without `package = inputs.hyprland.packages.<system>.hyprland`, you get the wrong binary.
- **`hyprctl version` shows a different version than the flake pin.** The session was started from a stale generation. Reboot, or log out and back in.
- **AMDVLK silently selected.** If you accidentally `amdvlk` into the system, `vulkaninfo` may show AMDVLK as the active ICD. ADR-10 says RADV. Remove the package or set `VK_DRIVER_FILES` to force RADV.

### Rollback

```bash
sudo nixos-rebuild switch --rollback
# Or boot the previous generation from the systemd-boot menu.
```

---

## 8. Phase 6 — Layer 3: UI Layer (Walker, Notifications via Quickshell stub, Wallpaper)

### Goal

The desktop has an application launcher (walker), a wallpaper daemon (awww), and a placeholder Quickshell bar. Full custom Quickshell QML is Phase 9; this phase brings up the minimal Quickshell runtime so notifications work.

### Why split walker/awww from Quickshell

Walker and awww are off-the-shelf packages. Quickshell is custom QML you'll author over weeks. Bringing up walker and awww now means you have a working desktop *while* you iterate on Quickshell — the laptop isn't unusable for the duration of the QML development.

### Steps

#### 8.1 Add walker via Home Manager

`home/walker/default.nix`:

```nix
{ pkgs, ... }:
{
  programs.walker = {
    enable = true;
    runAsService = true;       # elephant backend lifecycle
    # Settings can be added as the launcher matures; defaults are usable.
  };
}
```

Wire into `home/default.nix`:

```nix
imports = [
  ./hyprland
  ./walker        # ← new
];
```

Add a keybind in `home/hyprland/default.nix`:

```nix
bind = [
  # ... existing ...
  "$mod, D, exec, walker"
];
```

Add the walker substituters to avoid Rust rebuilds — in `modules/system/default.nix`:

```nix
nix.settings = {
  experimental-features = [ "nix-command" "flakes" ];
  auto-optimise-store = true;
  extra-substituters = [
    "https://walker.cachix.org"
    "https://walker-git.cachix.org"
  ];
  extra-trusted-public-keys = [
    "walker.cachix.org-1:fG8q+uAaMqhsMxWjwvk0IMb4mFPFLqHjuvfwQxE4oJM="
    "walker-git.cachix.org-1:vmC0ocfPWh0S/vRAQGtChuiZBTAe4wiKDeyyXM0/7pM="
  ];
};
```

> ⚠ **Verify these cache public keys** against the walker project's README before committing — trusting a wrong key is a supply-chain footgun. Run `curl https://walker.cachix.org/cache.json` and confirm the key matches.

#### 8.2 Add awww (wallpaper)

`modules/desktop/wallpaper.nix`:

```nix
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    awww          # daemon (ADR-06)
    waypaper      # GUI picker
  ];
}
```

Start awww as a user service via Home Manager. Append to `home/default.nix`:

```nix
systemd.user.services.awww-daemon = {
  Unit = {
    Description = "awww wallpaper daemon";
    After = [ "graphical-session.target" ];
    PartOf = [ "graphical-session.target" ];
  };
  Service = {
    ExecStart = "${pkgs.awww}/bin/awww-daemon";
    Restart = "on-failure";
  };
  Install.WantedBy = [ "graphical-session.target" ];
};
```

> **Caveat on `awww` binary names.** As of the Oct 2025 rename, awww ships both `awww`/`awww-daemon` *and* legacy `swww`/`swww-daemon` symlinks for backward compat. If `${pkgs.awww}/bin/awww-daemon` doesn't exist on your pinned version, fall back to `swww-daemon`. Verify with `nix run nixpkgs#awww -- --help`.

#### 8.3 Add the Quickshell flake input

Edit `flake.nix`:

```nix
inputs.quickshell = {
  url = "git+https://git.outfoxxed.me/quickshell/quickshell?ref=v0.1.0";  # pin to a real tag
  inputs.nixpkgs.follows = "nixpkgs";
};
```

> Verify the tag exists: `git ls-remote https://git.outfoxxed.me/quickshell/quickshell.git | grep tags`. Quickshell tags as of late 2025/early 2026 — pick the latest stable.

#### 8.4 Add Quickshell as a system package + minimal QML

`modules/desktop/quickshell.nix`:

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.quickshell.packages.${pkgs.system}.default
  ];
}
```

Create a *minimal* `home/quickshell/config/shell.qml` — just enough to verify Quickshell starts:

```qml
//@ pragma UseQApplication
import Quickshell

ShellRoot {
  // Empty for now — full bar comes in Phase 9.
  // This file existing and parsing proves Quickshell loads cleanly.
}
```

Wire it via Home Manager — `home/quickshell/default.nix`:

```nix
{ config, lib, ... }:
{
  xdg.configFile."quickshell/shell.qml".source = ./config/shell.qml;
}
```

And import it in `home/default.nix`:

```nix
imports = [
  ./hyprland
  ./walker
  ./quickshell    # ← new
];
```

Start Quickshell from Hyprland's autostart — append to `home/hyprland/default.nix`:

```nix
settings.exec-once = [
  "quickshell"
];
```

#### 8.5 Build → test → switch

```bash
git add . && git commit -m "feat: Layer 3 UI stubs — walker, awww, Quickshell shell (Phase 6)"
git push
# On target:
git pull
sudo nixos-rebuild test --flake .#nix-desktop
# Log out and back in (or reboot) so the Hyprland exec-once picks up Quickshell.
```

### Verification

```bash
# Walker
pgrep -f elephant     # backend should be running
pgrep -f walker       # service-mode daemon

# awww
pgrep -f awww-daemon
awww img /path/to/test-wallpaper.png    # should set the wallpaper

# Quickshell
pgrep -f quickshell
# Test the notification daemon registration (it should NOT be Quickshell yet,
# since we have an empty shell.qml — this becomes Quickshell-owned in Phase 9).
busctl --user introspect org.freedesktop.Notifications /org/freedesktop/Notifications 2>&1 | head -5
# Expected at this point: no owner (since the empty Quickshell doesn't claim it,
# and no mako is installed). This is correct for this phase.
```

After `switch`:

```bash
sudo nixos-rebuild switch --flake .#nix-desktop
```

### Pitfalls

- **walker without elephant.** walker is a thin frontend; `elephant` is the backend. `runAsService = true` plus the systemd user service should bring both up; if walker hangs on startup, check `systemctl --user status elephant`.
- **Quickshell QML parse errors.** Don't fail the build — they fail at runtime. Check with `journalctl --user -u quickshell -f` or run `quickshell` from a terminal and read the QML error trace.
- **Stale Cachix keys.** If the substituter keys are wrong, Nix silently rebuilds from source. The first walker build takes 30+ minutes if cache miss. Verify by watching `nix build` output for `copying from` (cache hit) vs. `building` (miss).

### Rollback

`sudo nixos-rebuild switch --rollback` — Hyprland from Phase 5 is the previous generation.

---

## 9. Phase 7 — Layers 4 & 5: Daemons & User Applications

### Goal

PipeWire, Bluetooth, networking GUI, screenshot tooling, file manager, browser, dev tools — all the things from architecture Layers 4 and 5 except the things deferred per Tier-3 triggers.

### Why batch these

These packages are largely independent of each other and of the rest of the stack. A bug in mpv doesn't affect Hyprland. Batching them into one rebuild is acceptable and saves time. The exception — PipeWire — is the one piece that *could* cause cascading breakage (audio device routing), so split it into its own module for surgical rollback.

### Steps

#### 9.1 Audio — `modules/desktop/audio.nix`

```nix
{ ... }:
{
  # PulseAudio MUST be off — both stacks cannot coexist.
  services.pulseaudio.enable = false;

  security.rtkit.enable = true;   # real-time scheduling for PipeWire

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    wireplumber.enable = true;
  };
}
```

#### 9.2 Hardware services — `modules/desktop/hardware.nix`

```nix
{ pkgs, ... }:
{
  # Bluetooth
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.blueman.enable = true;

  # Removable media
  services.udisks2.enable = true;

  # Printing — CUPS only, drivers deferred per Tier-3 trigger
  services.printing.enable = true;

  # Avahi — mDNS for printer/AirPlay discovery
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Trash semantics (Tier-2 resolved)
  services.gvfs.enable = true;

  # systemd-resolved with DNSSEC (Tier-2 resolved)
  services.resolved = {
    enable = true;
    dnssec = "allow-downgrade";
    fallbackDns = [ "1.1.1.1" "9.9.9.9" ];
  };

  # Dygma keyboards — pulls package + udev rules
  programs.bazecor.enable = true;
}
```

#### 9.3 Power & idle — `modules/desktop/power.nix`

```nix
{ ... }:
{
  services.power-profiles-daemon.enable = true;

  # ADR-15 — laptop lid behaviour
  services.logind = {
    lidSwitch = "suspend-then-hibernate";
    lidSwitchExternalPower = "suspend";
    lidSwitchDocked = "ignore";
  };
  systemd.sleep.extraConfig = ''
    HibernateDelaySec=30min
  '';
}
```

> The desktop doesn't need lid policies — they're no-ops without a lid. But the module is harmless on both hosts.

#### 9.4 MIME defaults & environment — `modules/desktop/mime.nix`

```nix
{ ... }:
{
  environment.sessionVariables = {
    BROWSER = "helium";
    EDITOR = "nvim";
    VISUAL = "nvim";
    TERMINAL = "kitty";
  };

  # xdg.mime is host-level and HM-level; set both for full coverage.
  xdg.mime.defaultApplications = {
    "application/pdf" = "org.pwmt.zathura.desktop";
    "text/html" = "helium.desktop";
    "x-scheme-handler/http" = "helium.desktop";
    "x-scheme-handler/https" = "helium.desktop";
    "image/png" = "imv.desktop";
    "image/jpeg" = "imv.desktop";
    "image/gif" = "imv.desktop";
    "image/webp" = "imv.desktop";
    "video/mp4" = "mpv.desktop";
    "video/x-matroska" = "mpv.desktop";
    "video/webm" = "mpv.desktop";
    "audio/mpeg" = "mpv.desktop";
    "audio/flac" = "mpv.desktop";
    "audio/ogg" = "mpv.desktop";
    "inode/directory" = "thunar.desktop";
    "text/plain" = "nvim.desktop";
  };
}
```

> **Helium availability.** The Helium browser is consumed via the `oxcl/nix-flake-helium-browser` flake (architecture Layer 5). Add it as an input now and pull the package in `modules/apps/browsers.nix` below. If Helium's flake API has changed since the architecture doc was written, fall back to `chromium` as the default browser temporarily — keep the MIME entries but point them at `chromium.desktop`.

#### 9.5 Browsers — `modules/apps/browsers.nix`

Add the input to `flake.nix` first:

```nix
inputs.helium = {
  url = "github:oxcl/nix-flake-helium-browser";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Then:

```nix
{ inputs, pkgs, system, ... }:
{
  # Helium (community flake — verify the exact attribute name; the oxcl flake
  # exposes `programs.helium` as a module).
  imports = [ inputs.helium.nixosModules.default ];
  programs.helium.enable = true;

  environment.systemPackages = with pkgs; [
    chromium      # fallback
  ];
}
```

> **Verify before committing.** Run `nix flake show github:oxcl/nix-flake-helium-browser` to inspect the actual exposed names. If `nixosModules.default` isn't the right path, substitute the correct one. The README of that flake is the authoritative reference.

#### 9.6 Screenshot, clipboard, utility apps — `modules/desktop/wayland-utils.nix`

```nix
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    grim
    slurp
    swappy
    cliphist
    wl-clipboard
    wlsunset
    wlr-randr
    kanshi          # always-on for laptop, optional for desktop
    brightnessctl
  ];
}
```

#### 9.7 User apps — `modules/apps/default.nix`

```nix
{ pkgs, ... }:
{
  imports = [ ./browsers.nix ];

  environment.systemPackages = with pkgs; [
    # Terminal
    kitty

    # Files
    yazi
    xfce.thunar
    xfce.thunar-volman
    xfce.thunar-archive-plugin

    # Office
    onlyoffice-desktopeditors

    # Media
    mpv
    vlc

    # Dev
    neovim
    git
    gh
    lazygit
    direnv
    nix-direnv
    claude-code

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
    unrar      # unfree

    # Modern CLI
    ripgrep
    fd
    bat
    eza
    jq
    yq-go
    delta

    # Infra
    rsync
    restic
    wireguard-tools

    # Shell helpers (zsh enabled below)
    starship
    atuin
    zoxide
    fzf

    # Trash semantics
    trash-cli

    # Misc
    zotero
    foliate
    blanket
  ];

  # unrar is unfree — declare per-package rather than blanket allowUnfree
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (pkgs.lib.getName pkg) [
      "unrar"
      # Helium is unfree depending on flake config — add if needed
    ];

  # zsh as login shell
  programs.zsh.enable = true;
  users.users.mboehme.shell = pkgs.zsh;
}
```

#### 9.8 Wire all the new modules into `modules/system/default.nix`

```nix
imports = [
  ./locale.nix
  ./users.nix
  ../desktop/hyprland.nix
  ../desktop/greeter.nix
  ../desktop/wallpaper.nix
  ../desktop/quickshell.nix
  ../desktop/audio.nix          # ← new
  ../desktop/hardware.nix       # ← new
  ../desktop/power.nix          # ← new
  ../desktop/mime.nix           # ← new
  ../desktop/wayland-utils.nix  # ← new
  ../apps                       # ← new (imports default.nix)
];
```

#### 9.9 Build → test → switch

```bash
git add . && git commit -m "feat: Layer 4-5 daemons and apps (Phase 7)" && git push
git pull   # on target
sudo nixos-rebuild build --flake .#nix-desktop
sudo nixos-rebuild test  --flake .#nix-desktop
# Use the system for ~10 minutes — play audio, plug in a USB stick, take a screenshot.
sudo nixos-rebuild switch --flake .#nix-desktop
```

### Verification

```bash
# Audio
pactl info | head -3            # Server name: PipeWire
wpctl status                    # WirePlumber graph

# Bluetooth
bluetoothctl show               # adapter present

# Network
nmcli device status
resolvectl status               # DNSSEC supported: yes

# Trash
trash-put /tmp/test_file        # creates a trash entry
trash-list

# Screenshot pipeline
grim - | wl-copy                # captures to clipboard

# Browsers
which helium  || which chromium

# CLI
rg --version && fd --version && bat --version
```

### Pitfalls

- **Audio routing silence.** `wpctl status` shows the graph; if no default sink is set, audio plays into the void. `wpctl set-default <id>` resolves it.
- **`programs.helium` not found.** The flake's module name may differ. Run `nix flake show <flake-url>` to inspect.
- **`unrar` build fails for unfree license.** The `allowUnfreePredicate` is required; a blanket `allowUnfree = true` works but lets future unfree packages slip in unintentionally.
- **`environment.sessionVariables` doesn't reach Hyprland.** Wayland sessions get env from `~/.profile` and pam_systemd. If a session-vars value is missing inside Hyprland, also set it in `wayland.windowManager.hyprland.settings.env`.

### Rollback

Per-module. Rollback the whole switch if multiple things broke; revert single modules in git if just one (e.g. PipeWire) regressed.

---

## 10. Phase 8 — Layer 6: Stylix Theming

### Goal

System-wide theming via Stylix — one base16 scheme drives GTK, Qt, Kitty, Neovim, Btop, Bat, Fzf, Starship, Yazi, hyprlock, the TTY console, fonts, cursors, icons. Stylix replaces per-program theme blocks.

### Why now, after the apps

Stylix's targets reference packages — if you enable `stylix.targets.kitty.enable` before kitty is installed, evaluation succeeds but the theming has nothing to attach to. Doing Stylix after Phase 7 (where the apps land) means every target hits real packages.

### Steps

#### 10.1 Add the input

`flake.nix`:

```nix
inputs.stylix = {
  url = "github:danth/stylix";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.home-manager.follows = "home-manager";
};
```

#### 10.2 Wire as a system module — pass to `mkHost`

In `flake.nix` outputs:

```nix
mkHost = hostname: nixpkgs.lib.nixosSystem {
  inherit system;
  specialArgs = { inherit inputs; };
  modules = [
    disko.nixosModules.disko
    inputs.stylix.nixosModules.stylix     # ← new
    ./hosts/${hostname}
    ./modules/system
    home-manager.nixosModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { inherit inputs; };
      home-manager.sharedModules = [ inputs.stylix.homeModules.stylix ];  # ← new
    }
  ];
};
```

#### 10.3 Create `modules/desktop/stylix.nix`

```nix
{ pkgs, ... }:
{
  stylix = {
    enable = true;

    # Base16 scheme — Catppuccin Mocha
    base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";

    # Wallpaper — switch later to `stylix.image = ...;` for auto-derived schemes
    # once the static scheme has been validated.
    image = ./wallpapers/default.png;     # commit this file to the repo

    polarity = "dark";

    fonts = {
      monospace = {
        package = pkgs.nerd-fonts.jetbrains-mono;
        name = "JetBrainsMono Nerd Font";
      };
      sansSerif = {
        package = pkgs.dejavu_fonts;
        name = "DejaVu Sans";
      };
      serif = {
        package = pkgs.dejavu_fonts;
        name = "DejaVu Serif";
      };
      emoji = {
        package = pkgs.noto-fonts-emoji;
        name = "Noto Color Emoji";
      };
      sizes = {
        applications = 11;
        terminal = 12;
        desktop = 11;
        popups = 11;
      };
    };

    cursor = {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 24;
    };

    iconTheme = {
      enable = true;
      package = pkgs.papirus-icon-theme;
      dark = "Papirus-Dark";
      light = "Papirus-Light";
    };

    # Stylix targets — opt-in selection.
    # The defaults turn most things on; explicit listing here makes drift visible.
    targets = {
      console.enable = true;
      # GRUB/systemd-boot — optional, default off, leave off
    };
  };
}
```

Add a wallpaper file:

```bash
mkdir -p modules/desktop/wallpapers
# Drop a 1080p+ wallpaper image at modules/desktop/wallpapers/default.png
git add modules/desktop/wallpapers/default.png
```

Import the module:

```nix
# In modules/system/default.nix
imports = [
  # ...
  ../desktop/stylix.nix
];
```

#### 10.4 Build → test → switch

```bash
git add . && git commit -m "feat: Stylix theming (Phase 8)" && git push
git pull
sudo nixos-rebuild test --flake .#nix-desktop
```

Open kitty, neovim, btop, bat — all should pick up Catppuccin Mocha automatically.

```bash
sudo nixos-rebuild switch --flake .#nix-desktop
```

### Verification

```bash
# GTK theme
gsettings get org.gnome.desktop.interface gtk-theme           # Stylix-generated
gsettings get org.gnome.desktop.interface icon-theme          # Papirus-Dark

# Console (reboot to see fully)
journalctl -b | grep -i stylix

# Fonts
fc-match monospace      # JetBrainsMono Nerd Font ...
fc-match sans-serif     # DejaVu Sans ...
```

### Pitfalls

- **Stylix double-applies if you keep per-program theme blocks.** Remove any explicit `programs.kitty.theme = "...";` etc. — let Stylix drive.
- **`nwg-look` accidentally installed.** It will race against Stylix's GTK theme application. The architecture excludes it; verify no transitive dependency pulls it in.
- **Wallpaper-derived schemes are fickle.** Stay on a static base16 scheme for the first two weeks (per architecture's Tier-3 trigger), then experiment with `stylix.image` driving the scheme.

### Rollback

Stylix is a single module — comment out the import and rebuild. All per-program theming returns to package defaults.

---

## 11. Phase 9 — Custom Quickshell Build-Out

### Goal

The custom Quickshell QML tree from the architecture's ADR-13 module inventory: bar, workspaces, clock, audio indicator, network indicator, tray, notification daemon (claiming `org.freedesktop.Notifications`), and OSDs.

### Why this is its own phase — and the longest one

This is **the** custom-code phase. Unlike the other layers (which are package-flips and module-enables), this is QML you write from scratch. The architecture estimates "significant time investment" and is right — plan for days of iteration, not hours. The good news: each QML file can be reloaded without rebuilding the system (`quickshell -r` or kill+restart), so iteration is fast.

### Approach

Don't try to implement the full module inventory in one push. Build in this order, validating each component live:

1. **Empty shell loads.** (Already done — Phase 6.)
2. **Single static bar appears on one monitor.**
3. **Workspaces module — reactive to Hyprland IPC.**
4. **Clock.**
5. **Audio indicator (PipeWire).**
6. **Network indicator (NetworkManager D-Bus or SystemTray).**
7. **System tray.**
8. **Notification daemon** (claims D-Bus name).
9. **OSDs (volume, brightness).**
10. **Stylix palette bridge.**
11. **(Optional) Lockscreen overlay, polkit, history pane.**

Each of these is a 1-3 hour task with the docs open at <https://quickshell.outfoxxed.me/docs/>.

### Steps (high-level — full QML omitted; this is custom-author territory)

#### 11.1 Directory layout

Create the structure from ADR-13:

```bash
mkdir -p home/quickshell/config/{modules,notifications,osd,theme}
```

Replace the placeholder `shell.qml` with something that imports the bar:

```qml
//@ pragma UseQApplication
import Quickshell
import "modules"

ShellRoot {
  Bar {}
}
```

#### 11.2 Stylix → Quickshell palette bridge

Per architecture Layer 6 — Stylix has no Quickshell target, so a manual export is required.

In `modules/desktop/stylix.nix`, add:

```nix
home-manager.sharedModules = [
  ({ config, ... }: {
    # Export the active base16 palette as JSON for Quickshell to consume.
    xdg.configFile."quickshell/theme/palette.json".text = builtins.toJSON {
      base00 = config.lib.stylix.colors.base00;
      base01 = config.lib.stylix.colors.base01;
      base02 = config.lib.stylix.colors.base02;
      base03 = config.lib.stylix.colors.base03;
      base04 = config.lib.stylix.colors.base04;
      base05 = config.lib.stylix.colors.base05;
      base06 = config.lib.stylix.colors.base06;
      base07 = config.lib.stylix.colors.base07;
      base08 = config.lib.stylix.colors.base08;
      base09 = config.lib.stylix.colors.base09;
      base0A = config.lib.stylix.colors.base0A;
      base0B = config.lib.stylix.colors.base0B;
      base0C = config.lib.stylix.colors.base0C;
      base0D = config.lib.stylix.colors.base0D;
      base0E = config.lib.stylix.colors.base0E;
      base0F = config.lib.stylix.colors.base0F;
    };
  })
];
```

> **Verify the option path** `config.lib.stylix.colors.*` against Stylix's current API. Stylix has historically exposed colours under several namespaces; the path may have evolved. `nix repl` → `:lf .` → inspect `nixosConfigurations.nix-desktop.config.lib.stylix` to confirm.

Then `home/quickshell/config/theme/Palette.qml` reads it:

```qml
pragma Singleton
import QtQuick
import Quickshell.Io

Item {
  property string base00; property string base01; property string base02
  property string base03; property string base04; property string base05
  property string base06; property string base07; property string base08
  property string base09; property string base0A; property string base0B
  property string base0C; property string base0D; property string base0E
  property string base0F

  FileView {
    path: Quickshell.env("XDG_CONFIG_HOME") + "/quickshell/theme/palette.json"
    onLoaded: {
      const j = JSON.parse(text);
      base00 = "#" + j.base00; base01 = "#" + j.base01; base02 = "#" + j.base02;
      // ... etc for base03–base0F
    }
  }
}
```

#### 11.3 Notification daemon

The single most important Quickshell file. From ADR-07's implementation requirements:

`home/quickshell/config/notifications/NotificationServer.qml`:

```qml
import Quickshell
import Quickshell.Services.Notifications

NotificationServer {
  id: server

  // Claim org.freedesktop.Notifications on the session bus.
  // Setting these properties registers capabilities.
  bodyMarkupSupported: true
  bodyImagesSupported: true
  actionsSupported: true
  actionIconsSupported: false
  imageSupported: true
  persistenceSupported: true

  // Maintain a model of active notifications.
  // ListModel + populate on `notification` signal.
  // ... QML implementation per ADR-07 ...
}
```

Then validate per ADR-07:

```bash
notify-send -u critical "Test" "Critical-urgency body"
busctl --user introspect org.freedesktop.Notifications /org/freedesktop/Notifications
# Should show Quickshell as the bus name owner.
```

#### 11.4 Bar with workspaces and clock

`home/quickshell/config/modules/Bar.qml`:

```qml
import QtQuick
import Quickshell
import Quickshell.Wayland

Variants {
  model: Quickshell.screens

  PanelWindow {
    required property var modelData
    screen: modelData

    anchors {
      top: true
      left: true
      right: true
    }
    implicitHeight: 32

    // ... clock, workspaces, audio, network, tray children ...
  }
}
```

The full implementation is too long for this whitepaper — refer to the reference configs cited in ADR-13 (outfoxxed, vaxry, pfaj/bdebiase, flicko) as learning material, **not** to vendor.

#### 11.5 Iteration workflow

Quickshell hot-reloads on QML file changes when run interactively. Workflow:

```bash
# Stop the autostart instance.
pkill quickshell

# Run interactively from a terminal.
quickshell --verbose

# Edit QML files in another terminal. Quickshell reloads on save.
```

Once a component is stable, the autostart from `exec-once = ["quickshell"]` (set in Phase 6) takes over.

### Verification

- Bar visible on every monitor.
- Workspaces highlight reactively as you `$mod+1`/`$mod+2`.
- Clock ticks.
- Audio indicator updates when you change volume with `wpctl set-volume`.
- `notify-send test body` produces a popup.
- `busctl --user introspect org.freedesktop.Notifications` shows Quickshell as owner.
- Theming follows Stylix — change `stylix.base16Scheme` to a different yaml, rebuild, and the bar colour changes without Quickshell config edits.

### Pitfalls

- **Two notification daemons silently coexist.** If a transitive package pulls in `mako`, `swaync`, or `dunst`, the D-Bus name claim becomes a race. Audit `environment.systemPackages` and `home.packages` for any of these.
- **Quickshell version skew.** The QML API evolves. Pin a release tag; bump deliberately. The flake input pinning from Phase 6 is doing this work — don't `nix flake update` casually.
- **`FileView` reloads aren't free.** Reading `palette.json` on every theme change is fine; reading it in a tight loop in a delegate is not. Cache the values in a singleton.

### Rollback

Quickshell QML is user-config, not system-level. Worst case, `rm -rf ~/.config/quickshell` falls back to whatever the system flake provides — which is an empty stub. The bar disappears; nothing else is harmed.

---

## 12. Phase 10 — Secrets Management with sops-nix

### Goal

The bootstrap password hash, SSH host keys, restic password, WireGuard private key, and any future tokens live in sops-encrypted YAML committed to the repo. Decryption happens at NixOS activation using each host's age key (derived from its SSH host key).

### Why now

Until this phase, the bootstrap password hash is committed in plaintext. That's acceptable for hours, not weeks. Moving secrets under sops is the prerequisite for WireGuard, restic backups, and any service-with-API-key (Gitea CI tokens later, etc.).

### Steps

#### 12.1 Add sops-nix as a flake input

```nix
inputs.sops-nix = {
  url = "github:Mic92/sops-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Wire into `mkHost`:

```nix
modules = [
  inputs.sops-nix.nixosModules.sops
  # ...
];
```

#### 12.2 Generate age keys per host

On each target:

```bash
# Convert the host's existing SSH ed25519 key to age format.
nix-shell -p ssh-to-age --command \
  "sudo ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub -o /tmp/age-pubkey"
cat /tmp/age-pubkey   # copy this output
```

You'll get a string like `age1abc123...xyz`. Note one per host.

On your dev machine, generate an admin age key for editing secrets:

```bash
nix-shell -p age --command "mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt"
# Note the public key it prints.
```

#### 12.3 Write `.sops.yaml` (repo root)

```yaml
keys:
  - &admin       age1<your-dev-machine-pubkey>
  - &nix_desktop age1<nix-desktop-host-pubkey>
  - &nix_laptop  age1<nix-laptop-host-pubkey>
creation_rules:
  - path_regex: secrets/common\.yaml$
    key_groups:
      - age:
        - *admin
        - *nix_desktop
        - *nix_laptop
  - path_regex: secrets/nix-desktop\.yaml$
    key_groups:
      - age:
        - *admin
        - *nix_desktop
  - path_regex: secrets/nix-laptop\.yaml$
    key_groups:
      - age:
        - *admin
        - *nix_laptop
```

#### 12.4 Create and edit the secrets files

```bash
nix-shell -p sops --command "sops secrets/common.yaml"
```

In the editor, write:

```yaml
mboehme_password_hash: $y$j9T$your-yescrypt-hash-here
restic_password: "long-restic-repo-password"
```

Save. The file on disk is now encrypted — `cat secrets/common.yaml` shows base64 ciphertext.

Repeat for `secrets/nix-desktop.yaml` and `secrets/nix-laptop.yaml` if there are host-specific secrets.

#### 12.5 Reference the secrets in NixOS modules

`modules/system/users.nix`:

```nix
{ config, ... }:
{
  sops.secrets.mboehme_password_hash = {
    sopsFile = ../../secrets/common.yaml;
    neededForUsers = true;   # decrypt early enough for user creation
  };

  users.users.mboehme = {
    isNormalUser = true;
    # Remove `initialHashedPassword`; replace with:
    hashedPasswordFile = config.sops.secrets.mboehme_password_hash.path;
    # ... rest unchanged ...
  };
}
```

#### 12.6 Tell sops-nix where to find the host's age key

Add to `modules/system/security.nix`:

```nix
{ ... }:
{
  sops = {
    defaultSopsFile = ../../secrets/common.yaml;
    age = {
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      keyFile = "/var/lib/sops-nix/key.txt";
      generateKey = true;
    };
  };
}
```

Import in `modules/system/default.nix`:

```nix
imports = [
  # ...
  ./security.nix
];
```

#### 12.7 Build → test → switch

```bash
git add . && git commit -m "feat: sops-nix secrets management (Phase 10)" && git push
git pull
sudo nixos-rebuild test --flake .#nix-desktop
```

The activation script logs (`journalctl -u sops-install-secrets`) will show secrets being decrypted into `/run/secrets/`.

### Verification

```bash
ls -la /run/secrets/                          # tmpfs mount with decrypted files
sudo cat /run/secrets/mboehme_password_hash    # the hash
sudo -i; passwd mboehme                        # asks for new password? No — uses hash
```

Reboot. Log in with the password you hashed. If login fails, the hash didn't materialise — check `journalctl -b | grep sops`.

### Pitfalls

- **`neededForUsers = true` missing.** sops decrypts late by default; the `users` module evaluates early. Without `neededForUsers`, the hash file doesn't exist when the user is created, and you're locked out.
- **Lost age key.** If `~/.config/sops/age/keys.txt` is destroyed, you can no longer edit existing secrets. Back this up — encrypted, separately from the repo. A `pass`-encrypted copy or an offline USB stick are reasonable answers.
- **Editing secrets without sops.** `sops` re-encrypts on save. If you ever edit a `secrets/*.yaml` file with plain `nvim` and commit, you've committed plaintext to git history. `git filter-repo` can scrub, but only if caught immediately.

### Rollback

The previous generation has the plaintext `initialHashedPassword` and still works. Rollback if sops integration breaks; investigate; reapply.

---

## 13. Phase 11 — Deploying the Second Host

### Goal

`nix-laptop` is bootstrapped from the same flake. Differences are isolated to `hosts/nix-laptop/` and any laptop-specific module imports.

### Why straightforward at this point

By Phase 11, every architectural decision is encoded in modules. The laptop install is a re-run of Phases 2-4 + 10 with three changes:

1. Different `hardware-configuration.nix` (generated on the laptop).
2. Different `disk-config.nix` (different device path, different swap size).
3. Laptop-specific module imports (touchpad config, kanshi, no SSH server).

### Steps

#### 13.1 Author the laptop-specific touches

`hosts/nix-laptop/default.nix`:

```nix
{ inputs, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  networking.hostName = "nix-laptop";
  system.stateVersion = "25.05";

  # No SSH server.
  services.openssh.enable = false;

  # kanshi — laptop is mandatory per ADR-12
  services.kanshi = {
    enable = true;
    # profiles authored once you know what monitors you dock to
  };

  # Touchpad — pushed into Home Manager Hyprland settings already (Phase 5).
}
```

#### 13.2 Run Phase 2–4 on the laptop hardware

Boot the installer, network up, `disko` apply, `nixos-generate-config` for hardware, `nixos-install --flake .#nix-laptop`.

#### 13.3 Add the laptop's age key to `.sops.yaml`

Already done in Phase 10 if you generated both keys upfront. If not, regenerate `.sops.yaml`, run:

```bash
nix-shell -p sops --command "sops updatekeys secrets/common.yaml"
nix-shell -p sops --command "sops updatekeys secrets/nix-laptop.yaml"
```

`sops updatekeys` re-encrypts existing files to the new key set without changing the secret values.

#### 13.4 First rebuild on the laptop

```bash
sudo nixos-rebuild switch --flake /etc/nixos#nix-laptop
```

### Verification

The laptop reaches the greeter; user logs in; Hyprland comes up; bar appears; lid close suspends; reopening resumes within 1 second; battery indicator visible in the bar; touchpad two-finger scroll works.

### Pitfalls

- **Mixing host UUIDs.** Each host's `hardware-configuration.nix` references LUKS UUIDs unique to its disks. Don't copy-paste between hosts.
- **Forgetting `sops updatekeys`.** If you add the laptop's age key to `.sops.yaml` but don't re-encrypt, the laptop can't decrypt secrets at activation, and the activation fails — but only at first boot.

---

## 14. Phase 12 — Backups, Maintenance, Operational Hygiene

### Goal

`btrbk` takes hourly local BTRFS snapshots. `restic` pushes encrypted off-site backups to Proxmox daily. Rebuild scripts and rollback drills are routine.

### Steps (sketch)

#### 14.1 `btrbk` per architecture Layer 9

`modules/system/snapshots.nix`:

```nix
{ ... }:
{
  services.btrbk.instances.local = {
    onCalendar = "hourly";
    settings = {
      snapshot_preserve_min = "2d";
      snapshot_preserve = "48h 14d 8w 12m";
      volume."/" = {
        snapshot_dir = "/.snapshots";
        subvolume = {
          "home" = { };
          "var-lib" = { };
          "gitea" = { };
        };
      };
    };
  };
}
```

#### 14.2 `restic` daily push

A user-systemd timer that runs `restic backup` of `/.snapshots/<latest>` to the Proxmox repo, with the restic password from sops.

#### 14.3 Quarterly restore drill

```bash
# Spin up a clean VM, install NixOS with the flake, restic-restore the home subvol.
restic -r sftp:backup@proxmox:repos/nix-desktop restore latest --target /mnt/restore
```

If the restore yields working data, the backup chain is healthy. If not, you've discovered the bug *before* you needed the backup — which is the only time it's a non-emergency.

#### 14.4 Routine commands

```bash
# Update inputs (deliberately — read the changelogs)
nix flake update

# Update one input at a time
nix flake lock --update-input hyprland

# Garbage collect
sudo nix-collect-garbage --delete-older-than 30d

# Verify ESP space
df -h /boot
```

---

## 15. Verification Matrix — "Is It Done?"

A single table that says yes/no per phase. Don't trust subjective "feels working"; run these.

| Phase | Verification command | Pass criterion |
|-------|----------------------|----------------|
| 1 | `nix flake check --no-build` | Exit 0, no eval errors |
| 2 | `git ls-remote <gitea-url>` from installer | Lists refs |
| 3 | `lsblk -f` after disko | All subvolumes mounted under /mnt |
| 4 | Reboot → login as `mboehme` | Console login succeeds |
| 5 | `hyprctl version` in Hyprland | Matches flake pin |
| 6 | `pgrep -fa walker awww quickshell` | All three running |
| 7 | `pactl info`; `bluetoothctl show`; `resolvectl status` | Audio, BT, resolved healthy |
| 8 | `gsettings get org.gnome.desktop.interface gtk-theme` | Stylix-generated name |
| 9 | `busctl --user list \| grep notifications` | Quickshell owns the name |
| 10 | `ls /run/secrets/` | Decrypted files present; reboot → login works |
| 11 | Both hosts reach Hyprland desktop | Visual confirmation |
| 12 | `btrbk list snapshots`; restic restore test | Snapshots present; restore yields readable data |

---

## 16. Common Pitfalls — A Cross-Phase Cheat Sheet

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `nix flake check` says "file not found" | Untracked file | `git add` and retry |
| `nix flake check` says *"fileSystems option does not specify your root file system"* | Phase 1 `fileSystems."/"` stub missing from `hardware-configuration.nix` | Restore the stub from §3.6, or — if you're past Phase 4 — confirm `nixos-generate-config` output was actually copied in |
| `nix flake check` says *"set boot.loader.grub.devices"* though you want systemd-boot | `boot.loader.systemd-boot.enable = true;` missing | Add it to `modules/system/default.nix` (see §3.5); GRUB is the fallback when no bootloader is explicitly enabled |
| LUKS prompt doesn't appear at boot | `boot.initrd.luks.devices` missing | Re-check `hardware-configuration.nix` |
| Hibernate fails silently | `resume=` kernel param missing or wrong UUID | Verify `boot.kernelParams` and `boot.resumeDevice` |
| Hyprland binary is wrong version | Missing `programs.hyprland.package = inputs.hyprland.packages.<sys>.hyprland` | Add it |
| Notifications go nowhere | No daemon claims D-Bus name | Either install one or build the Quickshell daemon (Phase 9) |
| Audio silent despite PipeWire running | No default sink | `wpctl set-default <id>` |
| Login fails after sops switch | `neededForUsers = true` missing | Add to the secret declaration |
| Walker takes 30 min to install | Cachix substituter missing or wrong key | Verify keys against project README |
| Stylix doesn't theme some program | Target not enabled or program installed via `home.packages` outside HM modules | Either enable the target or theme manually |
| Wallpaper black on first boot | awww service started before Hyprland surfaces | Add `After=graphical-session.target` |
| Lid close on laptop drains battery overnight | `HibernateDelaySec` too long or `suspend-then-hibernate` not set | Re-check ADR-15 wiring |

---

## 17. Appendix A — Per-Phase File-Change Map

A flat index of which files each phase touches.

| Phase | New files | Modified files |
|-------|-----------|----------------|
| 1 | `flake.nix`, `hosts/*/default.nix`, `hosts/*/hardware-configuration.nix` (stub), `hosts/*/disk-config.nix` (stub), `modules/system/{default,locale,users}.nix` | — |
| 2 | — | — |
| 3 | — | `hosts/*/disk-config.nix` |
| 4 | — | `hosts/*/hardware-configuration.nix`, `hosts/*/default.nix`, `modules/system/users.nix` |
| 5 | `modules/desktop/{hyprland,greeter}.nix`, `home/default.nix`, `home/hyprland/default.nix` | `modules/system/default.nix`, `flake.nix` (hyprland input) |
| 6 | `modules/desktop/{wallpaper,quickshell}.nix`, `home/walker/default.nix`, `home/quickshell/default.nix`, `home/quickshell/config/shell.qml` | `flake.nix` (quickshell input), `modules/system/default.nix`, `home/default.nix` |
| 7 | `modules/desktop/{audio,hardware,power,mime,wayland-utils}.nix`, `modules/apps/{default,browsers}.nix` | `flake.nix` (helium input), `modules/system/default.nix` |
| 8 | `modules/desktop/stylix.nix`, `modules/desktop/wallpapers/default.png` | `flake.nix` (stylix input), `modules/system/default.nix` |
| 9 | `home/quickshell/config/**` (extensive) | `modules/desktop/stylix.nix` (palette export) |
| 10 | `.sops.yaml`, `secrets/*.yaml`, `modules/system/security.nix` | `flake.nix` (sops-nix input), `modules/system/{default,users}.nix` |
| 11 | `hosts/nix-laptop/{hardware-configuration,disk-config}.nix` | `hosts/nix-laptop/default.nix`, `.sops.yaml` |
| 12 | `modules/system/snapshots.nix` | `modules/system/default.nix` |

---

## 18. Appendix B — Command Cheatsheet

```bash
# ── Editing & validation (dev machine) ─────────────────────────────────
nix flake check                                         # eval-only check
nix flake show                                          # outputs overview
nix eval .#nixosConfigurations.nix-desktop.config.system.build.toplevel.drvPath
nix flake update                                        # bump all inputs
nix flake lock --update-input hyprland                  # bump one input

# ── Build & deploy (target host) ───────────────────────────────────────
sudo nixos-rebuild build  --flake .#nix-desktop         # closure only
sudo nixos-rebuild test   --flake .#nix-desktop         # activate, no boot entry
sudo nixos-rebuild switch --flake .#nix-desktop         # activate + boot entry
sudo nixos-rebuild boot   --flake .#nix-desktop         # boot entry only
sudo nixos-rebuild switch --rollback                    # undo

# ── Disko ──────────────────────────────────────────────────────────────
sudo nix --experimental-features 'nix-command flakes' run \
    github:nix-community/disko -- --mode disko --flake .#<host>

# ── Secrets (sops) ─────────────────────────────────────────────────────
sops secrets/common.yaml                                # edit
sops updatekeys secrets/common.yaml                     # re-encrypt to new key set

# ── Generations ────────────────────────────────────────────────────────
sudo nix-collect-garbage --delete-older-than 30d
sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

# ── Diagnostics ────────────────────────────────────────────────────────
journalctl -b -p err                                    # current-boot errors
journalctl -u sops-install-secrets                      # secrets activation
hyprctl version && hyprctl monitors
busctl --user list | grep -i notif
wpctl status
```

---

## 19. Appendix C — Estimated Time Budget

A realistic schedule assuming one operator working evenings/weekends, no prior NixOS experience.

| Phase | Estimated wall time | Notes |
|-------|---------------------|-------|
| 1 — Repo skeleton | 2-3 h | Mostly typing, some Nix syntax reading |
| 2 — Install media | 30 min | Per host |
| 3 — Disko | 1 h | Per host; 30 min on subsequent reinstalls |
| 4 — Minimal viable system | 2 h | First-time; 30 min on reinstall |
| 5 — Hyprland | 3-4 h | First flake overlay, first Wayland session |
| 6 — Walker/awww/QS stub | 2 h | Mostly package adds |
| 7 — Daemons & apps | 3-4 h | Many small modules; little debugging needed |
| 8 — Stylix | 2-3 h | Reading Stylix docs is half the time |
| 9 — Custom Quickshell | **20-40 h** | The variable cost — depends on QML aptitude |
| 10 — sops-nix | 2-3 h | Mostly understanding the key flow |
| 11 — Laptop | 2-3 h | Phases 2-4 condensed |
| 12 — Backups | 3-4 h | Restore drill included |
| **Total (excluding QS)** | **20-30 h** | |
| **Total (with QS)** | **40-70 h** | |

This is achievable in ~6 weeks of evenings or ~3 long weekends.

---

## 20. Closing Notes

### What this whitepaper is

A bootstrap path. It produces a working system that matches the architecture reference at each phase's verification gate.

### What it is not

A long-term operational manual. Once the system is up, day-to-day work is:

1. Edit modules in the repo.
2. `nixos-rebuild test`.
3. `nixos-rebuild switch` if happy.
4. Commit and push.
5. `git pull && nixos-rebuild switch` on the other host.

The architecture reference, not this whitepaper, is the document you'll consult monthly.

### When to deviate

The architecture is frozen at v3. Any deviation from this whitepaper that contradicts an ADR should result in either (a) the deviation being reversed or (b) the ADR being amended explicitly. The cost of letting silent deviations accumulate is a system that diverges from its design without anyone noticing — which, on a declarative stack, is the worst of both worlds.

### When to ask for help

After 30 minutes of unproductive debugging on a single error. NixOS error messages are notoriously cryptic; the matrix.org `#nix:nixos.org` and `#hyprland:matrix.org` rooms are responsive. Have ready:

- The exact command that failed.
- The full error output (not paraphrased).
- The commit hash of the repo at the time of failure.
- `nixos-version` and `nix --version` on the target.

---

**Document end. The architecture reference (v3) is authoritative; this whitepaper is the construction sequence.**
