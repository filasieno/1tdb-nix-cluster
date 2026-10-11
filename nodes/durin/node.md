# durin

Hardware present on the running host, collected 2026-10-11.

## Platform

| | |
|---|---|
| Vendor | Supermicro |
| Board | H13SAE-MF, revision 2.00 |
| Board serial | OM261S133897 |
| Board date | 2026-01-28 |
| Chipset | AMD 600 series |
| Socket | AM5 |
| Firmware | AMI 2.8a (2026-08-11), 32 MiB, UEFI |
| SMBIOS | 3.7.0 |
| Chassis | Supermicro main server chassis, one power cord |
| TPM | 2.0 (ACPI MSFT0101) |

The system and chassis serials are still the OEM placeholder `0123456789`. The firmware does not identify the power supply.

## Processor

AMD EPYC 4545P (Zen 5, Granite Ridge). One socket, populated and enabled.

| | |
|---|---|
| Cores / threads | 16 / 32 |
| Base / max | 3.0 GHz / 5.45 GHz |
| Microcode | `0xb404038` |
| L1 | 48 KiB data + 32 KiB instruction per core |
| L2 | 1 MiB per core (16 MiB) |
| L3 | 64 MiB (2 × 32 MiB) |
| Virtualization | AMD-V |

## Memory

96 GiB installed, multi-bit ECC. The OS sees 91.92 GiB. Four DDR5 UDIMM slots, maximum capacity 192 GiB. Both modules run at 5200 MT/s.

| Slot | Module |
|---|---|
| DIMMA1 | Kingston 48 GiB DDR5-5600 ECC UDIMM, dual rank, 1.1 V, part `9965794-036.A00G`, serial `00422707`, date 2025 week 52 |
| DIMMA2 | empty |
| DIMMB1 | Kingston 48 GiB DDR5-5600 ECC UDIMM, dual rank, 1.1 V, part `9965794-036.A00G`, serial `0042273E`, date 2025 week 52 |
| DIMMB2 | empty |

## Storage

No rotational disks. The chipset SATA controller has six links; two are occupied at 6.0 Gb/s and four are empty.

| Location | Device | Capacity | Firmware | Serial | Link |
|---|---|---|---|---|---|
| SATA ata1 | Samsung PM893 `MZ7L3480HCHQ-00A07`, 2.5" | 480 GB | JXTC604Q | `S664NN0YA04255` | SATA 6.0 Gb/s, 512e |
| SATA ata2 | Samsung PM893 `MZ7L3480HCHQ-00A07`, 2.5" | 480 GB | JXTC604Q | `S664NN0YA04245` | SATA 6.0 Gb/s, 512e |
| M.2-C1 | Intel Optane SSD DC P4801X `SSDPEL1K375GA` | 375 GB | E2010600 | `PHKM23010138375A` | PCIe 3.0 x4 (8 GT/s) |
| M.2-C2 | Samsung 990 PRO with heatsink | 2.00 TB | 8B2QJXD7 | `S7DRNJ0YB12728K` | PCIe 4.0 x4 (16 GT/s) |

Both M.2 slots are PCIe 4.0 x4. The Optane drive negotiates PCIe 3.0.

## Network

Two onboard Intel I210 copper ports, both linked at 1000 Mb/s full duplex.

| Port | Device | MAC |
|---|---|---|
| LAN1 (`eno1`) | Intel I210 (`8086:1533`) | `90:5a:08:c2:f9:56` |
| LAN2 (`eno2`) | Intel I210 (`8086:1533`) | `90:5a:08:c2:f9:57` |

## Graphics and audio

| Device | Where | State |
|---|---|---|
| AMD Radeon Graphics (Granite Ridge, `1002:13c0`) | CPU, integrated | Present, `amdgpu` not bound |
| ASPEED AST2600 VGA | BMC, VGA output active | Driver `ast` |
| AMD Radeon HD Audio, Ryzen HD Audio, AMD ACP | CPU, integrated | Present |

No add-in GPU or sound card.

## Management controller

ASPEED AST2600. IPMI 2.0, firmware 1.09, Super Micro product id `0x1C97`.

| | |
|---|---|
| Dedicated LAN MAC | `90:5a:08:b9:52:7a` |
| Virtual devices | USB keyboard/mouse and a USB RNDIS Ethernet gadget on the chipset USB hub |

## Expansion

Empty slots:

| Slot | Type |
|---|---|
| CPU SLOT4 | PCIe 5.0 x8 |
| CPU SLOT6 | PCIe 5.0 x16 |
| PCH SLOT7 | PCIe 4.0 x4 |
| DIMMA2, DIMMB2 | DDR5 UDIMM |
| SATA links 3–6 | 6.0 Gb/s capable, no drive |

## USB

| Controller | Ports |
|---|---|
| AMD 600-series USB 3.2 xHCI | 12 × USB 2.0, 5 × USB 3.2 (20 Gb/s) |
| CPU USB 3.1 xHCI (`11:00.3`) | 2 × USB 2.0, 2 × USB 3.1 (10 Gb/s) |
| CPU USB 3.1 xHCI (`11:00.4`) | 2 × USB 2.0, 2 × USB 3.1 (10 Gb/s) |

A 250 MB USB flash drive (Ours Technology `0ea0:2168`, "Flash Disk") is plugged into chipset USB port 2. It is removable, not a fixed disk.
