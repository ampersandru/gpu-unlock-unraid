# Experimental Unraid integration

Build a kernel-specific module in Docker, then run it immediately before NVIDIA
loads using a persistent `modprobe` install hook. No NVIDIA driver patch, GPU
unbind, or live module reload is performed. This is a community experiment,
not an official Unraid or NVIDIA plugin.

## Observed result and scope

The original integration succeeded on:

| Item | Observed configuration |
| --- | --- |
| Unraid | 7.3.4 |
| Kernel / compiler | 6.18.58-Unraid / GCC 16.2.0 |
| Target | RTX 3090, PCI 0000:01:00.0 |
| Other GPU | RTX 5060 Ti, left untargeted |
| NVIDIA | Open kernel module 580.196.07 |
| Outcome | `gpu_unlock: unlocked` before `NVRM: loading NVIDIA` |
| Strata IQ3 outcome | No obvious major decode or prefill improvement reported |

The tester's 3090/5060 Ti normally use 250 W / 150 W limits through LACT.
LACT and inference containers were stopped during boot debugging. Activation
and performance are separate outcomes: do not infer an end-to-end speedup from
the unlock message. No controlled benchmark was performed.

These reusable scripts generalize the successfully exercised procedure. They
have not themselves been deployed on that machine yet. Upstream GPU code is
kept intact; this checkout may contain upstream changes newer than the tested
deployment. Each build records its exact source commit and kernel configuration.

Only the supported upstream Ampere parts are eligible. An RTX 5060 Ti is not
unlocked by this project. IQ3/Q4 storage does not prevent FP16/BF16 operations
in inference, but CPU, memory, PCIe, quantized-kernel and multi-GPU bottlenecks
can limit any benefit. Keep power limits and inference settings identical for
comparisons.

## Prerequisites

- Back up the USB boot device and retain a recovery/Safe Mode boot entry.
- Finish any array rebuild before experimental reboots.
- Root shell on Unraid, Docker available, Git, and sufficient build storage
  (allow at least 10 GB; download/build sizes vary).
- Stock kernel config at `/usr/src/linux-$(uname -r)/config`.
- `CONFIG_MODVERSIONS` disabled and `CONFIG_RANDSTRUCT_NONE=y`.
- Matching prepared kernel archive available from
  [ich777/unraid_kernel](https://github.com/ich777/unraid_kernel/releases), and
  the matching compiler image available in the official `gcc` Docker repository.

The prepared kernel tree is a third-party build input. The script applies your
running kernel's config and prepares it using that config's GCC version. It
checks the kernel release and module metadata; these checks do not prove all
possible ABI or firmware compatibility. Firmware generation uses upstream's
pinned inputs and checksum checks. No generated firmware or binaries are
committed to this fork.

## 1. Clone and build (no GPU changes)

```bash
git clone https://github.com/ampersandru/gpu-unlock-unraid.git
cd gpu-unlock-unraid
bash unraid/build.sh
```

The default workspace is `/mnt/user/appdata/gpu-unlock-unraid-build`.
Use an appropriate pool/share with enough free space. Override it if needed:

```bash
GPU_UNLOCK_WORK=/mnt/cache/appdata/gpu-unlock-unraid-build bash unraid/build.sh
```

The container is not privileged, receives no GPU or host Docker-socket access,
and installs build tools only inside itself. It outputs a uniquely named
`payload-KERNEL.XXXXXX` directory. Note the exact directory printed at completion.
If the archive/image does not exist or checks fail, stop and inspect the error;
do not force a module version or relax its checks. No custom kernel is installed.

## 2. Identify the target

```bash
nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv
lspci -Dnn | grep -i nvidia
```

Use the full four-digit-domain PCI address, e.g. `0000:01:00.0`, not the GPU
index or nvidia-smi's eight-digit domain. Do not copy the example blindly.
The installer accepts one PCI address, `all`, or a comma-separated list
of PCI addresses. Verify that selected GPUs are supported by the upstream
unlock module. For `all`, the hook checks NVIDIA display controllers for
driver ownership before loading the module, excluding audio functions.

## 3. Stage the persistent hook

Substitute the actual payload directory and your PCI address:

```bash
bash unraid/install.sh \
  /mnt/user/appdata/gpu-unlock-unraid-build/payload-6.18.58-Unraid.XXXXXX \
  0000:01:00.0
```

The installer verifies checksums, kernel release and, when present, NVIDIA's
module compatibility string. It refuses another NVIDIA `install` hook or a
different configured target. It stages files only on the boot device and does
not modify the current `/etc/modprobe.d` or execute the unlock now.

For multiple GPUs, install with `all` or an explicit PCI list:

    bash unraid/install.sh /absolute/payload-directory all
    bash unraid/install.sh /absolute/payload-directory 0000:81:00.0,0000:82:00.0

The installer rejects duplicate PCI addresses and validates explicit
targets as NVIDIA display controllers. With `all`, device checks happen
at boot.

In Main -> Flash -> Syslinux Configuration, add a custom parameter:

```text
gpu_unlock.targets=0000:01:00.0
```

For multiple GPUs, use `gpu_unlock.targets=all` or the exact
comma-separated PCI list supplied to the installer. The boot parameter
must match the configured target exactly.

Apply it to the normal Unraid OS entry, preserving existing options. Leave a
recovery entry unchanged. If either disable marker described below exists,
remove it only when ready to enable this experiment. Reboot cleanly.

## 4. Verify

```bash
sh unraid/status.sh
```

Look for this ordering:

```text
gpu-unlock-unraid: Running unlock ... before NVIDIA loads
pci 0000:01:00.0: gpu_unlock: unlocked
NVRM: loading NVIDIA ...
```

`Module executed` by itself is not success: upstream can report an unlock
failure while module insertion succeeds. Missing firmware, a bound card, and
an absent boot opt-in are logged. Some kernel failures can still hang the
machine despite the hook's fail-open shell behavior.

Start LACT/power-limit management and inference after confirming normal NVIDIA
operation. Measure prompt processing and decode separately with the same
prompts, model, context, cache state and power limits. Repeat/interleave runs.

## Disable, recover, or remove

Disable on the next boot without changing current GPU state:

```bash
sh unraid/disable.sh
```

Re-enable for the next boot:

```bash
rm /boot/config/gpu-unlock-unraid/disabled
```

The legacy marker `/boot/config/gpu-unlock.disable` is also respected. Remove
it too if it exists and you intend to enable the unlock.

If boot hangs, remove `gpu_unlock.targets=...` in the boot-menu editor, use
Safe Mode, or attach the flash drive to another computer and remove
`config/modprobe.d/gpu-unlock-unraid.conf`. The remaining payload is inert.
Removing that config restores the ordinary NVIDIA load path on the next boot.
Do not try to unload NVIDIA, unbind the GPU, or run the hook manually after boot.
Power off before retrying if upstream reports firmware that did not stop.

## Kernel and driver updates

Payloads live under `/boot/config/gpu-unlock-unraid/kernels/KERNEL/`. A new
kernel without a matching payload is skipped and NVIDIA loading continues.
After an Unraid update, run `build.sh` and install its new payload; the hook
automatically selects it by `uname -r`. Keep old kernel payloads for rollback.
Replacing an existing payload requires first moving it outside that directory;
the installer refuses silent replacement. Shell-level skip guards do not
guarantee unrelated OS updates will boot correctly.

NVIDIA-only updates normally do not require a module rebuild because no NVIDIA
driver is patched, but recheck boot logs and performance. The hook relies on
`modprobe` honoring `install nvidia`; direct `insmod`, different future Unraid
boot behavior, or `--ignore-install` can bypass it. This is not an automatic
update service or an officially supported plugin.

## Migrating the earlier interactive setup

If you used the initial chat-generated instructions, disable the old hook
before using this installer. Move (do not merely rename) these outside their
active directories, retaining a backup:

- `/boot/config/modprobe.d/gpu-unlock-before-nvidia.conf`
- `/boot/extra/gpu-unlock-*.txz` packages from the earlier experiment.

Do not move unrelated packages or driver configuration. Files left in
`/boot/extra`, even with a renamed extension, may still be processed by Unraid.
The old `/boot/config/gpu-unlock/` payload may remain inert. The new installer
will stop if the old install hook is still active in `/etc/modprobe.d`; after
staging the old hook's removal, reboot normally before installing the new one.

## Why a pre-NVIDIA hook?

The tested Unraid startup initialized NVIDIA before `/boot/extra` packages ran.
Moving a loader into an ordinary package was too late. Persistent modprobe
configuration is restored early, so an `install nvidia` command runs this hook
and then calls `modprobe --ignore-install nvidia $CMDLINE_OPTS` to preserve
normal loading without recursion. Errors return control to normal NVIDIA loading.

An inherited-file-descriptor `flock` attempt failed at early boot although it
worked interactively; the precise cause was not established. The successful
revision used `/usr/bin/flock` with a filename and command, and captured stderr.
This fork uses that form. Never remove concurrency protection to work around a
boot error without understanding simultaneous driver-load requests.

## Reporting results

For a Docker-based PyTorch 2.9 dense GEMM comparison, see
[the benchmark instructions](BENCHMARK.md). This is separate from LLM testing.

Include Unraid/kernel/compiler versions, NVIDIA driver flavor/version, target
GPU and PCI address, source commit from `manifest.txt`, relevant kernel logs,
and measured before/after workload settings. Report activation separately from
speed. Review logs for personal data before posting; do not upload API keys,
whole diagnostics archives or generated proprietary firmware.

References: [upstream](https://github.com/Zagitta/gpu-unlock),
[Unraid persistent modprobe configuration](https://docs.unraid.net/unraid-os/release-notes/6.9.0/),
[modprobe install commands](https://man7.org/linux/man-pages/man5/modprobe.d.5.html).
