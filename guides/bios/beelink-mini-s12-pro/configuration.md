<header>
  <span style="display: inline-flex; align-items: center;">
    <img src="https://cdn.coolblock.com/coolblock.svg" width="48" height="48" style="margin-right: 5px;">
    <h1>COOLBLOCK - BIOS Configuration - Beelink Mini S12 Pro</S></h1>
  </span>
</header>

> Before proceeding, make sure to restore to default options! `Save & Exit` -> `Restore Defaults`

1. **Disable** `Advanced` -> `CPU Configuration` -> `Intel (VMX) Virtualization Technology`
2. Navigate to `Advanced` -> `ACPI Settings`
   1. **Disable** `Enable Hibernation`
   2. **Suspend Disable** `ACPI Sleep State`
3. Navigate to `Advanced` -> `CSM conf`
    1. **Disable** `CSM Support`
4. Navigate to `Advanced` -> `Network Stack Configuration`
    1. **Disable** `Network Stack`
5. Navigate to `Advanced` -> `S5 RTC Wake Settings`
    1. **Disable** `Wake system from S5`
6. Navigate to `Chipset` -> `PCH-IO Configuration`
    1. **SET** `State After G3` -> `S0 State`
    2. Navigate to `HD Audio Configuration`
       1. **Disable** `HD Audio`
7. Navigate to `Chipset` -> `System Agent (SA) Configuration`
    1. **Disable** `VT-d`
    2. Navigate to `Graphics Configuration`
       1. **Set** `DVMT Pre-Allocated` to `32M`
8. Navigate to `Boot`
    1. **Set** `Fast Boot` to `Enabled`
9. Done `Save & Exit` -> `Save Changes and Reset`
