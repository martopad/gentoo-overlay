# gentoo-overlay

Martopad's personal Gentoo overlay.

## Contents

- `sys-kernel/strix-kernel` — Linux 7.3-rc5 + the
  `hyukudan/strix-halo-usb4-driver` patch series: the USB4 STREAM /
  GPU-direct transport kernel for the 2x Strix Halo (BOSGAME M5) model
  pool. Installs the kernel alongside the distribution kernels (never
  overwriting), with dracut initramfs and the driver's `usb4stream-lab`
  host tooling. See the ebuild comments for the boot-cutover rules.

## Registration (on a build/install host)

Add to `/etc/portage/repos.conf/` (or a separate `.repo` file there):

```
[strix]
location = /var/db/repos/strix
sync-type = git
sync-uri = https://github.com/martopad/gentoo-overlay.git
```

then `emaint sync --repo strix` (or `emerge --sync strix`) and
`emerge strix-kernel`.

## Notes

- EAPI 8 (required by the distribution's `kernel-build` eclass).
- Builds use the host toolchain; expect ~30-60 min for a full build on
  a Strix Halo box.
- The ebuild never changes the default boot entry; boot selection is
  owned by the caller (see `GRUB_DEFAULT` handling in the m5 pool docs).
