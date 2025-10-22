<header>
  <span style="display: inline-flex; align-items: center;">
    <img src="https://cdn.coolblock.com/coolblock.svg" width="48" height="48" style="margin-right: 5px;">
    <h1>COOLBLOCK - BIOS Configuration - Advantech P1571Z-C6 V2.0(6650U)</h1>
  </span>
</header>

> Before proceeding, make sure to restore to default options! `Save & Exit` -> `Restore Defaults`

1. **Disable** `Advanced` -> `CPU Configuration` -> `Intel (VMX) Virtualization Technology`
2. Navigate to `Advanced` -> `ACPI Settings`
   1. **Disable** `Enable ACPI Auto Configuration`
   2. **Disable** `Enable Hibernation`
   3. **Disable** `ACPI Sleep State`
   4. **Disable** `S3 Video Repost`
3. Navigate to `Advanced` -> `ACPI Settings`
   1. **Disable** `Resume On RTC Alarm`
   2. **Set** `Restore AC Power Loss` to `Last State`
   3. **Disable** `Watchdog Controller`
   4. **Disable** `Resume On RTC Alarm`
4. Navigate to `Advanced` -> `USB Configuration` and **Enable** everything
5. Navigate to `Advanced` -> `Network Stack Configuration` and **Disable** the whole stack
6. Navigate to `Advanced` -> `CSM Configuration` and **Disable** CSM Support
7. Navigate to `Chipset` -> `System Agent (SA) Configuration`
   1. **Disable** `VT-d`
   2. Navigate to `Graphics Configuration`
      1. **Enable** `Internal Graphics`
      2. Set `DVMT Total Gfx Mem` to `256M`
      3. **Disable** `eDP/VGA Output Disable`
8. Navigate to `Chipset` -> `PCH-IO Configuration` -> `HD Audio Configuration`
   1. **Disable** `HD Audio`
   2. **Disable** `Jack Detection`
9. Navigate to `Security` -> `Secure Boot`
   1. **Disable** `Secure Boot`
10. Navigate to `Boot`
    1. Set `Setup Prompt Timeout` to `1`
    2. **Enable** `Quiet Boot`
    3. **Enable** `Fast Boot`
11. Done `Save & Exit` -> `Save Changes and Reset`
