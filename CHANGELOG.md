# Changelog

## Unreleased

- hwmon compatibility fix for kernels where `hwmon_device_register()` is deprecated.
- registration flow now prefers:
  `hwmon_device_register_with_info()` -> `hwmon_device_register_with_groups()` -> `hwmon_device_register()`.
- fixed hwmon cleanup error paths to avoid unregister on `ERR_PTR` and to reset internal hwmon state safely.
- preserved existing driver temperature sysfs attributes (`temp0_input`, `temp0_alarmthresh`, `temp0_dalarmthresh`).
- validated runtime on 5.15.148-tegra (Jetson AGX Orin): module load/unload stable, links up, MTU 9000 change works.
- validated matrix build:
  3.18.140, 4.1.52, 4.4.302, 4.9.337, 4.14.336, 4.19.325, 5.4.302, 5.10.250, 5.15.200, 6.1.163, 6.6.124, 6.12.71, 6.18.10.

