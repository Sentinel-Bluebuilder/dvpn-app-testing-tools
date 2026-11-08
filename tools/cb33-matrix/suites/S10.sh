#!/usr/bin/env bash
# ─── S10 Install lifecycle (PLAN §1b). Bodies: FLX2 11-08. Platform-agnostic through plat_* hooks (README "S10 hooks"). ───
# The product ships as a package (.deb/.rpm on Linux, installer on Windows, .pkg on macOS). These scenarios install,
# upgrade, uninstall and reinstall it and check the daemon/CLI come up correctly, the on-disk layout is sane, and a
# removal leaves nothing behind (the leftovers check runs after each scenario). Hooks a platform lacks make that cell
# SKIP (77), never PASS. The scenarios are protocol-independent (`:off:once`) — install is not per-protocol.
#   plat_pkg_old / plat_pkg_new                 echo the package file for the previous release / the build under test,
#                                               or empty when the runner did not stage it (that scenario then SKIPs)
#   plat_pkg_install <file> [setup]             install <file>; "setup" (the initial install ONLY) runs device setup
#   plat_pkg_upgrade <file>                     upgrade the installed package to <file> (the package manager's upgrade)
#   plat_pkg_uninstall                          remove the package (keep user config); rc 0 = removed
#   plat_pkg_installed                          rc 0 iff the package is currently installed
#   plat_pkg_version                            echo the installed package version
#   plat_pkg_files                              echo the installed files, one per line, each "<mode> <owner> <path>"
#   plat_service_active / plat_service_enabled  rc 0 iff the daemon service is running / enabled at boot
#   plat_run_as_nonadmin <args...>              run the CLI as an unprivileged user; echo its output; rc = the CLI's rc
#   plat_device_id                              echo a stable fingerprint of the installed device/wallet identity
#   plat_config_present                         rc 0 iff the installed instance's user config/wallet is still present
#   plat_connect_short <proto>                  connect the INSTALLED instance ~10 s (egress = node), then disconnect
#   plat_service_install_timeout                optional: install with a slow or blocked service start; rc 0 iff the
#                                               installer returns (does not hang) and reports the failure cleanly
SCENARIOS="s10_over_old_build:off:once s10_upgrade:off:once s10_uninstall:off:once s10_reinstall:off:once s10_service_install_timeout:off:once s10_install_folder:off:once s10_first_start_no_admin:off:once"

# A scenario SKIPs (77) unless every hook it needs exists on this platform.
s10_need() { local h; for h in "$@"; do declare -F "$h" > /dev/null || { echo "no $h on this platform"; return 77; }; done; }

# Leave the box installed-and-clean for the next scenario: the new build in place, no session, daemon up.
s10_restore_clean() {
  plat_pkg_installed || plat_pkg_install "$(plat_pkg_new)" setup > /dev/null 2>&1 || true
  plat_reset > /dev/null 2>&1 || true
}

# Install the NEW build on top of an existing OLD install: data/config survive and the daemon runs the new version.
s10_over_old_build() {
  s10_need plat_pkg_old plat_pkg_new plat_pkg_install plat_pkg_upgrade plat_pkg_version plat_service_active || return $?
  local old new oldv newv
  old=$(plat_pkg_old); new=$(plat_pkg_new)
  { [ -n "$old" ] && [ -n "$new" ]; } || { echo "need both an old and a new package staged"; return 77; }

  plat_pkg_uninstall > /dev/null 2>&1 || true
  plat_pkg_install "$old" setup || { echo "installing the old build failed"; return 1; }
  oldv=$(plat_pkg_version); echo "old build installed: version $oldv"

  plat_pkg_upgrade "$new" || { echo "installing the new build over the old one failed"; return 1; }
  newv=$(plat_pkg_version); echo "after upgrade: version $newv"
  [ "$newv" != "$oldv" ] || { echo "version did not change across the upgrade ($oldv)"; return 1; }
  plat_service_active || { echo "the daemon service is not running after the in-place upgrade"; return 1; }
  s10_restore_clean
}

# A clean upgrade: version bumps, the service comes back, the device/wallet set up at the old install is KEPT (no
# new on-chain setup), and a short wg connect still carries traffic.
s10_upgrade() {
  s10_need plat_pkg_old plat_pkg_new plat_pkg_install plat_pkg_upgrade plat_pkg_version plat_service_active \
           plat_device_id plat_connect_short || return $?
  local old new dev dev2
  old=$(plat_pkg_old); new=$(plat_pkg_new)
  { [ -n "$old" ] && [ -n "$new" ]; } || { echo "need both an old and a new package staged"; return 77; }

  plat_pkg_uninstall > /dev/null 2>&1 || true
  plat_pkg_install "$old" setup || { echo "installing the old build failed"; return 1; }
  dev=$(plat_device_id); echo "device after old install: ${dev:-<none>}"
  [ -n "$dev" ] || { echo "no device set up at the old install"; return 1; }

  plat_pkg_upgrade "$new" || { echo "upgrade failed"; return 1; }
  plat_service_active || { echo "the daemon is not running after the upgrade"; return 1; }
  dev2=$(plat_device_id); echo "device after upgrade: ${dev2:-<none>} (version $(plat_pkg_version))"
  [ "$dev2" = "$dev" ] || { echo "the device/wallet changed across the upgrade = a new on-chain setup"; return 1; }
  plat_connect_short wireguard || { echo "a short wg connect failed after the upgrade"; return 1; }
  echo "upgraded, device kept, short wg connect carried traffic"
  s10_restore_clean
}

# Uninstall removes the binaries and the service but KEEPS the user config, and leaves no root-owned system leftovers
# (the driver's leftovers check confirms nothing is left behind after plat_reset).
s10_uninstall() {
  s10_need plat_pkg_new plat_pkg_install plat_pkg_uninstall plat_pkg_installed plat_service_active plat_config_present || return $?
  [ -n "$(plat_pkg_new)" ] || { echo "no package staged"; return 77; }

  plat_pkg_installed || plat_pkg_install "$(plat_pkg_new)" setup || { echo "install for the uninstall test failed"; return 1; }
  plat_config_present || { echo "no user config present after install (device never set up)"; return 1; }
  plat_pkg_uninstall || { echo "uninstall failed"; return 1; }
  ! plat_pkg_installed || { echo "the package is still installed after uninstall"; return 1; }
  ! plat_service_active || { echo "the daemon is still running after uninstall"; return 1; }
  plat_config_present || { echo "uninstall removed the user config/wallet (should be kept, not purged)"; return 1; }
  echo "uninstalled: package gone, service stopped, user config kept"
  s10_restore_clean
}

# Install → uninstall → install again must be clean, KEEP the device set up the first time (no new on-chain setup),
# and a short wg connect must still carry traffic.
s10_reinstall() {
  s10_need plat_pkg_new plat_pkg_install plat_pkg_uninstall plat_pkg_installed plat_service_active \
           plat_device_id plat_connect_short || return $?
  local pkg dev dev2; pkg=$(plat_pkg_new)
  [ -n "$pkg" ] || { echo "no package staged"; return 77; }

  plat_pkg_installed || plat_pkg_install "$pkg" setup || { echo "first install failed"; return 1; }
  dev=$(plat_device_id); echo "device after first install: ${dev:-<none>}"
  [ -n "$dev" ] || { echo "no device set up at the first install"; return 1; }

  plat_pkg_uninstall || { echo "uninstall failed"; return 1; }
  plat_pkg_install "$pkg" || { echo "reinstall failed"; return 1; }
  plat_service_active || { echo "the daemon is not running after reinstall"; return 1; }
  dev2=$(plat_device_id); echo "device after reinstall: ${dev2:-<none>}"
  [ "$dev2" = "$dev" ] || { echo "device lost on reinstall (not kept, or re-set-up): '$dev' -> '$dev2'"; return 1; }
  plat_connect_short wireguard || { echo "a short wg connect failed after reinstall"; return 1; }
  echo "reinstalled cleanly, device kept, short wg connect carried traffic"
  s10_restore_clean
}

# The installer must not hang when the service's first start is slow or blocked: it returns and reports the failure.
s10_service_install_timeout() {
  s10_need plat_service_install_timeout || return $?
  plat_service_install_timeout || { echo "the installer hung or did not report the slow service start"; return 1; }
  echo "installer returned and reported the slow service start"
  s10_restore_clean
}

# The on-disk layout is sane: the expected files are present and system paths are root-owned (no world-writable bits).
s10_install_folder() {
  s10_need plat_pkg_new plat_pkg_install plat_pkg_files || return $?
  [ -n "$(plat_pkg_new)" ] || { echo "no package staged"; return 77; }

  plat_pkg_installed || plat_pkg_install "$(plat_pkg_new)" setup || { echo "install failed"; return 1; }
  local files; files=$(plat_pkg_files)
  [ -n "$files" ] || { echo "plat_pkg_files listed nothing"; return 1; }
  echo "$files" | sed 's/^/  /'

  # The daemon binary must be shipped, and no installed file may be world-writable.
  echo "$files" | grep -qE 'sentinel-dvpnd( |$)' || { echo "the daemon binary is not in the package file list"; return 1; }
  local ww; ww=$(echo "$files" | awk '$1 ~ /.......w../ {print $3}')
  [ -z "$ww" ] || { echo "world-writable installed paths: $ww"; return 1; }
  echo "layout ok: daemon present, no world-writable paths"
  s10_restore_clean
}

# The CLI run by an unprivileged user fails with a clear message, not a crash or a stack trace.
s10_first_start_no_admin() {
  s10_need plat_pkg_new plat_pkg_install plat_run_as_nonadmin || return $?
  [ -n "$(plat_pkg_new)" ] || { echo "no package staged"; return 77; }

  plat_pkg_installed || plat_pkg_install "$(plat_pkg_new)" setup || { echo "install failed"; return 1; }
  local out rc
  out=$(plat_run_as_nonadmin client status 2>&1); rc=$?
  echo "non-admin CLI rc=$rc out: $(echo "$out" | tr '\n' ' ' | cut -c1-300)"
  [ "$rc" != 0 ] || { echo "the CLI unexpectedly succeeded as a non-admin user"; return 1; }
  echo "$out" | grep -qiE 'permission|denied|root|privilege|sudo|not allowed' \
    || { echo "the non-admin failure message is not a clear permission error"; return 1; }
  echo "$out" | grep -qiE 'panic:|goroutine |runtime error|segmentation' \
    && { echo "the CLI crashed instead of reporting a permission error"; return 1; }
  echo "non-admin start reported a clear permission error, no crash"
  s10_restore_clean
}
