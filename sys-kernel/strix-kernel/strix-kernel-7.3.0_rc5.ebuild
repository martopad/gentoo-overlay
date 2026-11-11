# Copyright 2026 Martin Luther Yung
# Distributed under the terms of the GNU General Public License v2

# Strix Halo USB4 STREAM kernel for the m5 model pool (2x BOSGAME M5).
#
# Upstream 7.3-rc5 (the commit the driver's patch series is pinned to)
# plus the hyukudan/strix-halo-usb4-driver stable series + backports:
# provides the /dev/tbstreamN USB4 STREAM character devices, configfs
# stream services and the GPU-direct DMA-BUF transport that the
# 2-node GLM/DeepSeek engines (strix-glm5) use.
#
# What this ebuild does:
#  - applies the driver's pinned patch series to the pristine tree with
#    the driver's own tools/apply-series.sh: the exact `git apply --check`
#    + `git apply --whitespace=error-all` flow the lab qualified the
#    series against. We do NOT use portage's eapply/patch(1): it
#    mis-applies some hunks (observed on 0007) and corrupts later
#    context, so the driver's git-apply tool is the source of truth.
#    Ordering = their patches/series (the file the lab's provenance
#    manifest pins via series_sha256) + the backports glob, both
#    handled inside the script (which also does the fail-fast checks:
#    no unsafe/missing/symlinked entries).
#  - seeds config from the known-good m5 pool snapshot (files/) + the
#    driver's usb4-gpu fragment + a fresh per-build LOCALVERSION under
#    the lab prefix (their reviewed-build identity rules: unique, no
#    placeholder, no release reuse)
#  - builds and installs ALONGSIDE the distribution kernels (never
#    overwrites; 7.3.3 / 6.18.62 entries remain as rollbacks), with a
#    dracut initramfs via the distro kernel-build generic-uki path
#  - installs the driver's usb4stream-lab host tooling: modprobe policy
#    that blacklists thunderbolt_net ONLY on 7.3.0-rc5-strix-*
#    releases (stock kernels keep it, so the gufo RDMA stack comes
#    back when you boot back), the lab service + reviewed-kernel
#    dropin (pinned to the installed release in pkg_postinst), the
#    udev refresh rule and the read-only usb4stream-describe script
#
# What it does NOT do:
#  - change the default boot entry. Boot cutover is the caller's job
#    (on the m5 pool: GRUB_DEFAULT='submenu>...' — see the pool docs;
#    grub-reboot one-shots are inert on these boxes: the GRUB env
#    block lives on LVM and is unreadable at UEFI boot).
#  - the /dev/tbstream* -> prod group udev rule (99-tbstream-perm.rules)
#    is host-specific to the m5 privilege model and stays Ansible-owned.

EAPI=8

inherit kernel-build toolchain-funcs

# Pinned upstream commit: "Linux 7.3-rc5" — the exact tree the driver's
# stable series is qualified against (their provenance manifest).
GIT_SHA=72d3fcf802c45d00b300f25b848a93c3a2bd7c7e

# Pinned driver commit: the stable series + lab tooling revision the m5
# pool's live build (2026-11-11) used.
DRIVER_SHA=4668b95451cddd613c1268a0c85eedf0c7ae2898

DESCRIPTION="Strix Halo USB4 STREAM kernel: upstream 7.3-rc5 + strix-halo-usb4-driver series"
HOMEPAGE="
	https://github.com/hyukudan/strix-halo-usb4-driver
	https://kernel.org/
"
SRC_URI="
	https://github.com/torvalds/linux/archive/${GIT_SHA}.tar.gz -> linux-${PV}.tar.gz
	https://github.com/hyukudan/strix-halo-usb4-driver/archive/${DRIVER_SHA}.tar.gz -> strix-usb4-driver-${DRIVER_SHA}.tar.gz
"
S="${WORKDIR}/linux-${GIT_SHA}"
DRIVER_S="${WORKDIR}/strix-halo-usb4-driver-${DRIVER_SHA}"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64"

# debug: install the unstripped vmlinux debug image (off — no debug
# vmlinux on the pool boxes). The kernel-build eclass also declares
# strip/modules-sign (on by default) and secureboot (via its eclass);
# those are merged automatically.
#
# NOTE: deliberately NOT generic-uki. That is a gentoo-kernel-bin flag
# ("ship a generic PREBUILT UKI instead of generating a custom
# initramfs"); on a source-compiled kernel it makes the eclass build a
# 0-byte placeholder image and skip the custom initramfs. This kernel
# generates its own initramfs via installkernel (dracut hook) at postinst,
# driven by kernel-install_pkg_postinst called from pkg_postinst below.
IUSE="debug"

# The driver's apply-series.sh applies the pinned series with `git apply`;
# the rest of the build (kernel-build eclass) is toolchain-only.
BDEPEND="
	dev-vcs/git
	sys-kernel/dracut
"

src_prepare() {
	# Apply the driver's pinned patch series with their own tool
	# (tools/apply-series.sh, see below). Ordering source of truth = the
	# driver's patches/series file (the one their provenance manifest pins
	# via series_sha256): series entries in listed order, then every
	# patches/kernel-backports/*.patch in glob order.
	#
	# A failed apply leaves the tree partially patched — harmless: the next
	# emerge unpacks a fresh copy (their tool says the same thing).
	eapply_user

	# The driver's own tool: applies their pinned series (patches/series in
	# listed order) + the kernel-backports glob, each via `git apply --check`
	# then `git apply --whitespace=error-all`, fail-fast naming the first bad
	# patch. Works on a plain (non-git) unpacked tree — the script sets
	# GIT_CEILING_DIRECTORIES to the tree's parent and unsets GIT_DIR so
	# `git apply` targets the kernel tree, not any surrounding checkout.
	# (No ewv/einfo here: this distro ships without eutils.eclass, so the
	#  eutils messaging functions are undefined; the driver script prints
	#  its own "applied N patch(es)" line to the build log.)
	sh "${DRIVER_S}/tools/apply-series.sh" --with-backports "${S}"

	# Per-build unique identity under the lab prefix. Bump the suffix
	# letter while the module directory for that release already exists
	# (same-day rebuilds on a box that already carries one).
	local base="strix-gpu-bosgame-$(date +%Y%m%d)" rel c
	rel=""
	for c in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
		if [[ ! -e "/lib/modules/7.3.0-rc5-${base}${c}" ]]; then
			rel="${base}${c}"
			break
		fi
	done
	[[ -n ${rel} ]] || die "no free build id under ${base}"

	# Known-good m5 pool config (snapshot of the live build's config with
	# the build-time LOCALVERSION pin stripped) + the driver's fragment +
	# the fresh LOCALVERSION.
	#
	# kernel-build_merge_configs merges its arguments IN ORDER onto .config
	# (later arguments win per symbol). The driver's fragment ships a
	# PLACEHOLDER CONFIG_LOCALVERSION ("-...-SET-A-UNIQUE-BUILD-ID"; its own
	# comment shows the substitution), so version.config (the real per-build
	# ID) MUST be merged last, or the placeholder wins and the driver's
	# reviewed-kernel-dropin gate rejects the build at postinst.
	cp "${FILESDIR}/config-${PV}-x86_64" ./.config || die
	echo "CONFIG_LOCALVERSION=\"-${rel}\"" > "${T}/version.config" || die
	kernel-build_merge_configs \
		"${DRIVER_S}/config/usb4-gpu.fragment" \
		"${T}/version.config"
}

src_install() {
	kernel-build_src_install

	# Stage a DETERMINISTIC "installed release" marker, read from the CLEAN
	# build image: ${D}/lib/modules holds ONLY this build's module dir
	# (unlike the system /lib/modules, which may also hold a manual build
	# and any placeholder from a failed/earlier run). pkg_postinst reads
	# this marker instead of globbing the system, so a stray/placeholder
	# dir can never make the dropin pin to the wrong release.
	local rel_img
	rel_img=$(ls -1 "${D}/lib/modules/" 2>/dev/null | grep -F "strix-gpu-bosgame-" | tail -1)
	[[ -n ${rel_img} ]] || die "no strix module dir in the build image's /lib/modules"
	insinto /usr/local/share/strix-kernel
	echo "${rel_img}" > "${T}/strix-installed-release" || die
	newins "${T}/strix-installed-release" installed-release

	# Driver's lab tooling (their INSTALL recipe, ebuild-ified).
	local lab=${DRIVER_S}/tools/lab

	insinto /etc/modprobe.d
	doins "${lab}/usb4stream-dedicated.conf"

	insinto /etc/systemd/system
	doins "${lab}/usb4stream-lab.service" "${lab}/usb4stream-describe-refresh.service"

	insinto /etc/udev/rules.d
	doins "${lab}/90-usb4stream-describe.rules"

	# The reviewed-kernel dropin generator + the module it imports.
	# The script resolves check_kconfig.py relative to its PARENT
	# directory, so the two install one level apart:
	#   /usr/local/sbin/strix-lab/reviewed-kernel-dropin
	#   /usr/local/sbin/check_kconfig.py
	insinto /usr/local/sbin/strix-lab
	doins "${lab}/reviewed-kernel-dropin"
	insinto /usr/local/sbin
	doins "${DRIVER_S}/tools/check_kconfig.py"
}

pkg_postinst() {
	# Stage the kernel image into /boot + generate the initramfs + update
	# GRUB, via the kernel-install eclass's OWN postinst. My ebuild defines
	# its own pkg_postinst, which would otherwise SHADOW the eclass's
	# kernel-install_pkg_postinst (the step that runs installkernel to place
	# /boot/kernel-<rel> + the initramfs + run grub-mkconfig). Without this
	# call the modules land in /lib/modules but no bootable image reaches
	# /boot and the kernel never appears in GRUB.
	kernel-install_pkg_postinst

	# Ensure an initramfs exists for this release. The eclass install path
	# generates one only when installkernel carries the dracut USE flag; on
	# the m5 boxes installkernel is installed without it, so generate the
	# initramfs directly with dracut when it is missing. LVM/DM/XFS are
	# built into this kernel, so a missing initramfs would still boot, but
	# we keep one for consistency with the proven manual build.
	if [[ ! -s /boot/initramfs-${KV_FULL}.img ]]; then
		einfo "No initramfs for ${KV_FULL}; generating one with dracut."
		dracut --force /boot/initramfs-${KV_FULL}.img "${KV_FULL}" || \
			ewarn "dracut initramfs generation failed; the kernel still boots (LVM/DM/XFS are built-in)"
	fi

	# Pin the lab service to this exact release (their reviewed-build
	# gate: the unit starts only on a release that passed review). The
	# release is read from the deterministic marker staged by src_install
	# (from the clean build image), NOT by globbing the system
	# /lib/modules — the system may hold a manual build and/or a
	# placeholder dir from an earlier failed run, which a mtime-glob
	# could pick and make the dropin pin to the wrong (rejected) release.
	local rel conf
	rel=$(cat "${EROOT}/usr/local/share/strix-kernel/installed-release" 2>/dev/null)
	[[ -n ${rel} ]] || die "no installed-release marker in ${EROOT}/usr/local/share/strix-kernel (did src_install run?)"
	conf="${EROOT}/etc/systemd/system/usb4stream-lab.service.d/10-reviewed-kernel.conf"
	python3 "${EROOT}/usr/local/sbin/strix-lab/reviewed-kernel-dropin" \
		"${rel}" --output "${conf}" || die "reviewed-kernel dropin failed"

	systemctl daemon-reload || die
	udevadm control --reload
	systemctl enable usb4stream-lab.service || die
	# No-op on a stock-kernel host: the unit's ConditionKernelVersion
	# (restricted to the installed release by the dropin) gates it.
	systemctl restart usb4stream-lab.service || true

	elog "Installed ${rel}."
	elog "Boot cutover is the caller's job: select the ${rel} GRUB entry"
	elog "(on the m5 pool: the 'Advanced options' submenu entry). This"
	elog "ebuild never changes the default boot entry."
}
