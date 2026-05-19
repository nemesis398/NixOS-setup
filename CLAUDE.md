# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Declarative NixOS flake for a two-host fleet (`nix-desktop`, `nix-laptop`, with a future headless `_lxc` slot). Hyprland + Quickshell on AMD RDNA, LUKS2 → LVM → BTRFS, Home Manager as a NixOS module, sops-nix for secrets.

**The canonical design document is `docs/nixos-architecture-reference-v3.md`** (v3, frozen). It contains all 16 ADRs and the Operator Decisions Log. Read it before making structural changes — the ADRs encode rejected alternatives, not just chosen ones.

## Current phase

The repo is at **Phase 1 (skeleton)**. Many directories listed in the README layout are intentionally empty placeholders:

- `modules/desktop/`, `modules/apps/`, `modules/virtualisation/` — empty
- `home/*/` — empty leaf dirs (no actual HM module files yet)
- `overlays/`, `secrets/` — empty
- `hosts/*/disk-config.nix` — stubs (`disko.devices = { }` with a "Replaced by full disko schema in Phase 3" comment)
- `hosts/_lxc/README.md` — empty file
- No `.sops.yaml` in repo root yet despite README references

When asked to "add module X", first check whether the parent dir exists and whether it is wired into `modules/system/default.nix`'s `imports`. Don't assume the README layout reflects on-disk state.

Known apparent issues in the skeleton — confirm with the operator before "fixing":

- `flake.nix`: `nixpkgs.url` points at the home-manager repo, not nixpkgs. Almost certainly a placeholder/typo, but verify before changing — the lockfile may depend on it.
- `modules/system/users.nix`: `isNormalUsers = true` (should be `isNormalUser` singular) and `initialHashedPassword = "REPLACE_ME"`. These are unfinished stubs.

## Common commands

Build / activate (`<host>` = `nix-desktop` | `nix-laptop`):

```bash
nix flake check                                          # evaluate all outputs
nixos-rebuild build --flake .#<host>                     # dry build, no activation
sudo nixos-rebuild test --flake .#<host>                 # activate without setting default boot entry
sudo nixos-rebuild switch --flake .#<host>               # activate + set default
sudo nixos-rebuild switch --rollback                     # undo last switch
```

Flake inputs:

```bash
nix flake update                # all inputs
nix flake update hyprland       # single input — always read Hyprland release notes first
```

Secrets (sops-nix, age backend, host keys derived via `ssh-to-age`):

```bash
sops secrets/common.yaml
sops secrets/<host>.yaml
sops updatekeys secrets/<host>.yaml   # after editing .sops.yaml recipients
```

Garbage collect (also runs weekly via `nix.gc`):

```bash
sudo nix-collect-garbage --delete-older-than 30d
sudo /run/current-system/bin/switch-to-configuration boot   # prune boot entries
```

Dev shell is provided via `flake.nix` + `.envrc` (`use flake . --impure`). Direnv loads it automatically.

VS Code tasks in `.vscode/tasks.json` wrap the most common build/check/sops invocations. Formatter is `alejandra`; language server is `nixd` configured against this flake's outputs.

## Architecture

### Flake assembly

`flake.nix` exposes `nixosConfigurations.{nix-desktop, nix-laptop}` built by a single `mkHost` helper. Every host gets the same module stack in this order:

1. `disko.nixosModules.disko` — declarative partitioning
2. `./hosts/<hostname>` — per-host: hostname, `system.stateVersion`, hardware, disk layout
3. `./modules/system` — fleet-wide system layer (currently: locale, users, nix settings, gc, boot-entry limit)
4. `home-manager.nixosModules.home-manager` + inline config — Home Manager runs **as a NixOS module** (atomic rebuilds, see ADR-01). Not standalone.

`inputs` is threaded everywhere via `specialArgs` and `home-manager.extraSpecialArgs`.

When wiring a new module, add it to the appropriate `imports` list rather than to `mkHost` directly. Fleet-wide concerns belong under `modules/system/default.nix`'s imports; per-host concerns under `hosts/<host>/default.nix`.

### Module taxonomy (target layout)

- `modules/system/` — boot, storage, locale, users, networking, vpn, security, gc
- `modules/desktop/` — hyprland, audio, bluetooth, printing, fonts, **stylix**, mime, power, trash, peripherals
- `modules/apps/` — browsers, office, dev, media
- `modules/virtualisation/` — libvirt, podman (rootless, `dockerCompat = true`)
- `home/<program>/` — Home Manager modules per program; `home/quickshell/` carries a custom QML tree (no vendored upstream — ADR-13)

### Cross-cutting invariants (don't violate without an ADR)

These come from the README and ADRs and are not visible from any single file:

- **Notifications are owned by Quickshell** (`Quickshell.Services.Notifications.NotificationServer`). **Never** add `mako`, `swaync`, or `dunst` — two daemons cannot hold `org.freedesktop.Notifications`. Verify after a rebuild with `busctl --user introspect org.freedesktop.Notifications /org/freedesktop/Notifications`. (ADR-07)
- **Stylix is the system-wide theming source of truth** for colours, fonts, cursor, icons (ADR-14). Quickshell is **not** a Stylix target — palette is bridged via `config.lib.stylix.colors` → generated `palette.json` → `xdg.configFile."quickshell/theme/palette.json"` → `theme/Palette.qml` singleton. Don't hard-code colours in QML.
- **RADV only** for Vulkan (Mesa). Don't install AMDVLK alongside. (ADR-10)
- **Containers**: Podman rootless with `dockerCompat = true`. No Docker daemon. (ADR-11)
- **Greeter**: `greetd` + `regreet` under `cage` (GTK4). Not GDM/SDDM/LightDM. (ADR-08)
- **Launcher**: `walker` in daemon mode. (ADR-09)
- **Wallpaper daemon**: `awww` (animated, IPC-driven). Not swww/hyprpaper. (ADR-06)
- **Lid / sleep**: `suspend-then-hibernate`, 30 min delay. Hibernate target is the encrypted `lv_swap`; no plaintext swap on disk. (ADR-15)
- **Boot**: `systemd-boot` only. ESP is 10 GiB to also hold a rescue NixOS ISO. (ADR-05)
- **Swap**: zram primary + `lv_swap` (RAM + 2 GiB) for hibernate. (ADR-04)
- **hyprlock** requires an explicit `security.pam.services.hyprlock = {};` declaration or it rejects every password.
- **Kernel**: `linuxPackages_latest` for best RDNA support. (ADR-03)

### Secrets flow (sops-nix)

1. Each machine has an SSH host key (`/etc/ssh/ssh_host_ed25519_key`).
2. `ssh-to-age -i <pubkey>` derives the age public key.
3. Age pubkey is recorded in `.sops.yaml` under that host.
4. `sops updatekeys secrets/<host>.yaml` re-encrypts after recipient changes.

Private age keys are never committed. The deployment-time `nixos-install` flow in the README assumes you do steps 1–4 before the first `nixos-install --flake`.

### Deferred / out-of-scope (intentional)

Don't speculatively add: Steam/Proton/gamemode/mangohud, OBS, SANE, printer driver packages (CUPS daemon yes, drivers no), TPM-backed LUKS / lanzaboote Secure Boot, email/chat clients. Each has a named trigger condition in the Operator Decisions Log.

### Mirror status

This working tree is a **read-only mirror** of a private Gitea repo. Do not propose pushes to a "github origin" or treat `master` here as the publish target — confirm with the operator where changes should actually land.
