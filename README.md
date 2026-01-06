# NetGamingOptimizer

PowerShell script to optimize a Windows 10/11 network adapter for competitive gaming with:

- Network optimization **profiles** from **Defaults** to **Ultra**
- Versioned JSON **backups** of adapter advanced settings and key registry tweaks
- **Restore** to any previous state
- **Diff** between two backups (NIC advanced properties + registry)
- **Dry-run** mode (preview changes without applying)
- **Adapter listing** with IPv4/IPv6 to easily find the correct `AdapterName`

Backups are stored by default in:

- `C:\ProgramData\NetGamingProfiles`

Backup files are named with the timestamp first so lexicographical order matches chronological order, e.g.:

- `20260106-141230_backup_Ethernet_Aggressive.json`

---

## Requirements

- Windows 10/11 with PowerShell 5.1 or PowerShell 7+
- Run the script **as Administrator**
- Network cmdlets available:
  - `Get-NetAdapter`, `Get-NetIPConfiguration`
  - `Get-NetAdapterAdvancedProperty`, `Set-NetAdapterAdvancedProperty`

---

## Profiles

Selected via `-Profile` (optional, default: `Defaults`):

- `Defaults`  
  Close to Windows defaults for most NICs:
  - Interrupt Moderation: Enabled  
  - RX/TX Buffers: 512  
  - `NetworkThrottlingIndex`: 10  
  - TCP/Nagle:
    - `TcpAckFrequency = 2`
    - `TCPNoDelay` and `TcpDelAckTicks` removed (Nagle enabled)

- `Conservateur`  
  Safer low-latency compromise:
  - Interrupt Moderation: Enabled  
  - RX/TX Buffers: 256  
  - `NetworkThrottlingIndex`: 10  
  - TCP/Nagle:
    - `TcpAckFrequency = 2`
    - `TCPNoDelay = 0`

- `Agressif`  
  Lower latency, more CPU interrupts:
  - Interrupt Moderation: Disabled  
  - RX/TX Buffers: 128  
  - `NetworkThrottlingIndex`: `0xffffffff` (disabled)  
  - TCP/Nagle:
    - `TcpAckFrequency = 1`
    - `TCPNoDelay = 1`

- `Ultra`  
  Very aggressive (test and validate on your system):
  - Interrupt Moderation: Disabled  
  - RX/TX Buffers: 64  
  - `NetworkThrottlingIndex`: `0xffffffff`  
  - TCP/Nagle:
    - `TcpAckFrequency = 1`
    - `TCPNoDelay = 1`
    - `TcpDelAckTicks = 0`

If no action switch is passed (`-ShowAdapters`, `-ListBackups`, `-Restore`, `-Diff`), the script assumes you want to **apply** the selected profile on the chosen adapter.

---

## Actions (switches)

- `-ShowAdapters`  
  Show active network adapters with:
  - Name (alias)
  - Description
  - IPv4 / IPv6 addresses

- `-ListBackups`  
  List existing backups in `-BackupDir` (file name, adapter, profile, timestamp).

- `-Restore`  
  Restore settings from a backup file (requires `-RestoreVersion`).  
  Can be combined with `-DryRun` for a preview.

- `-Diff`  
  Compare two backups (or the two latest if `-Backup1`/`-Backup2` are omitted).

- `-DryRun`  
  Preview changes without modifying the system:
  - With profile application: show what would be applied.
  - With `-Restore`: show differences between current state and target backup.

---

## Parameters

- `-Profile`  
  One of: `Defaults | Conservateur | Agressif | Ultra`  
  Default: `Defaults`.

- `-AdapterName`  
  NIC alias or pattern; default: `"Ethernet"`.  
  Used when applying a profile and when backing up current state.

- `-BackupDir`  
  Directory to store JSON backups.  
  Default: `C:\ProgramData\NetGamingProfiles`.

- `-BackupName`  
  Custom backup file base name (no path).  
  The script always prefixes the name with the timestamp, e.g.:  
  `20260106-141500_my_custom_backup.json`.

- `-RestoreVersion`  
  Backup file name (without path) to restore, required with `-Restore`.

- `-Backup1`, `-Backup2`  
  Backup file names to compare for `-Diff`.  
  If omitted, the two lexicographically newest `.json` files are used.

- `-DryRun`  
  Do not write any system changes; only show what would change.

---

## Usage examples

### List network adapters and IPs

```powershell
.\NetGamingOptimizer.ps1 -ShowAdapters
```

### Apply an aggressive profile to “Ethernet” (with automatic backup)

```powershell
.\NetGamingOptimizer.ps1 -Profile Agressif -AdapterName "Ethernet"
```

### Apply Defaults profile (soft reset)

```powershell
.\NetGamingOptimizer.ps1 -Profile Defaults -AdapterName "Ethernet"
```

### Apply Ultra profile with a custom backup name

```powershell
.\NetGamingOptimizer.ps1 -Profile Ultra -AdapterName "Ethernet" -BackupName "before_ultra_test"
```

### List existing backups

```powershell
.\NetGamingOptimizer.ps1 -ListBackups
```

### Compare the two latest backups

```powershell
.\NetGamingOptimizer.ps1 -Diff
```

### Compare two specific backups

```powershell
.\NetGamingOptimizer.ps1 -Diff -Backup1 "20260106-140000_backup_Ethernet_Agressif.json" -Backup2 "20260106-141000_backup_Ethernet_Ultra.json"
```

### Dry-run a profile (no changes applied)

```powershell
.\NetGamingOptimizer.ps1 -Profile Agressif -AdapterName "Ethernet" -DryRun
```

### Restore from a backup

```powershell
.\NetGamingOptimizer.ps1 -Restore -RestoreVersion "20260106-140000_backup_Ethernet_Agressif.json"
```

### Dry-run a restore

```powershell
.\NetGamingOptimizer.ps1 -Restore -RestoreVersion "20260106-140000_backup_Ethernet_Agressif.json" -DryRun
```

---

## Backup location

Default backup directory:

- `C:\ProgramData\NetGamingProfiles`

You can override with `-BackupDir`.  
Backup files are plain JSON and can be versioned with Git or backed up as needed.
