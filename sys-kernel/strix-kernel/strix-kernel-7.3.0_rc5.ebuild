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
#  - applies the driver's pinned patch series to the pristine tree
#    with portage's native patcher: the patch list is read from the
#    driver's own patches/series file (the file the lab's provenance
#    manifest pins via series_sha256) + the backports glob, in that
#    order. The driver's tools/apply-series.sh is a distro-agnostic
#    `git apply` convenience wrapper; on Gentoo we keep its ordering
#    source of truth but use eapply (EAPI-8 built-in) for the apply.
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

KERNEL_IUSE_GENERIC_UKI=1

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

# generic-uki: the kernel-build eclass only builds the dracut initramfs
# when this flag is on (off by default). A lab kernel that ships
# without an initramfs never reaches GRUB on these boxes, so it is
# on by default here (+ prefix: bare flags default off).
IUSE="+generic-uki"

src_prepare() {
	# Apply the pinned patch series with portage's native patcher.
	#
	# Ordering source of truth = the driver's patches/series (the file
	# the lab's provenance manifest pins via series_sha256), exactly as
	# their apply-series.sh consumes it: series entries in listed
	# order, then every patches/kernel-backports/*.patch in glob
	# (alphabetical) order. Their fail-fast checks (entry exists, not a
	# symlink, no path-traversal entries) are reproduced below; the
	# apply itself is `eapply` (patch -p1 based).
	#
	# A failed apply leaves the tree partially patched — harmless: the
	# next emerge unpacks a fresh copy (their tool says the same thing).
	eapply_user

	local p b patches=()
	while IFS= read -r p || [[ -n ${p} ]]; do
		[[ ${p} == '' || ${p} == \#* ]] && continue
		[[ ${p} == */* || ${p} == .* ]] &&
			die "apply-series: unsafe series entry: ${p}"
		[[ -f ${DRIVER_S}/patches/${p} && ! -L ${DRIVER_S}/patches/${p} ]] ||
			die "apply-series: ${p} missing or symlinked in ${DRIVER_S}/patches"
		patches+=( "${DRIVER_S}/patches/${p}" )
	done < "${DRIVER_S}/patches/series"

	for b in ${DRIVER_S}/patches/kernel-backports/*.patch; do
		[[ -f ${b} ]] || continue
		patches+=( "${b}" )
	done

	ewv "applying ${#patches[@]} driver patches (pinned series + backports)"
	eapply "${patches[@]}"

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
	# the fresh LOCALVERSION. merge order: latest file wins per symbol.
	cp "${FILESDIR}/config-${PV}-x86_64 .config" || die
	echo "CONFIG_LOCALVERSION=\"-${rel}\"" > "${T}/version.config" || die
	kernel-build_merge_configs \
		"${T}/version.config" \
		"${DRIVER_S}/config/usb4-gpu.fragment"
}

src_install() {
	kernel-build_src_install

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
	# Pin the lab service to this exact release (their reviewed-build
	# gate: the unit starts only on a release that passed review).
	local rel conf
	rel=$(ls -1dtr /lib/modules/*-strix-gpu-bosgame-* 2>/dev/null | tail -1 | sed 's:.*/::')
	[[ -n ${rel} ]] || die "no strix kernel release found in /lib/modules"
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
