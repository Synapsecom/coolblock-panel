<header>
  <span style="display: inline-flex; align-items: center;">
    <img src="https://cdn.coolblock.com/coolblock.svg" width="48" height="48" style="margin-right: 5px;">
    <h1>COOLBLOCK - BIOS Configuration - Yentek C4350Z-HD (i5-10210)</h1>
  </span>
</header>

> Before proceeding, make sure to restore to default options! `Save & Exit` -> `Restore Defaults`

1. `Advanced` -> `CPU Configuration` -> Intel (VMX) Virtualization: **Disabled**
2. `Advanced` -> `Trusted Computing` -> Security Device Support: **Disabled**
3. `Advanced` -> `ACPI Settings` -> Enable Hibernation: **Disabled**
4. `Advanced` -> `ACPI Settings` -> ACPI Sleep State: **Suspend Disabled**
5. `Advanced` -> `Miscellaneous Configuration` -> Restore AC Power Loss: **Power On**
6. `Advanced` -> `CSM Configuration` -> Boot option filter: **UEFI and Legacy** (Change it to UEFI when OS is installed to bypass the issue with the vanishing NVMe drive)
7. `Chipset` -> `System Agent (SA) Configuration` -> `Graphics Configuration` -> DVMT Total Gfx Mem: **128M**
8. `Chipset` -> `System Agent (SA) Configuration` -> Control Iommu Pre-boot Behavior: **Disable IOMMU**
9. `Chipset` -> `System Agent (SA) Configuration` -> VT-d: **Disabled**

Done `Save & Exit` -> `Save Changes and Reset`
