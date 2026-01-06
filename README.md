# Network Gaming Opti

Script PowerShell pour optimiser une carte réseau sous Windows 11 pour le gaming, avec :

- Profils d’optimisation (de **Defaults** à **Ultra**)
- Sauvegardes JSON versionnées de l’état réseau
- Restauration d’un état précédent
- Diff entre deux sauvegardes
- Mode **dry-run** (aperçu des changements sans les appliquer)
- Affichage des cartes réseau avec leurs IP pour choisir facilement le bon `AdapterName`

Les sauvegardes sont stockées par défaut dans :

- `C:\ProgramData\NetGamingProfiles`

Les fichiers de backup sont nommés avec la date/heure en premier pour faciliter le tri chronologique, par exemple :

- `20260106-141230_backup_Ethernet_Agressif.json`

---

## Prérequis

- Windows 10/11 avec PowerShell 5.1+ ou PowerShell Core
- Exécution en **administrateur** (modification des propriétés NIC + registre)
- Cmdlets réseau disponibles (`Get-NetAdapter`, `Get-NetIPConfiguration`, `Get-NetAdapterAdvancedProperty`, etc.)

---

## Installation

```powershell
git clone https://github.com/vignemail1/network-gaming-opti.git
cd network-gaming-opti
# éventuellement :
Unblock-File .\NetGamingOptimizer.ps1
```

Exécuter PowerShell en tant qu’administrateur, puis lancer le script.

---

## Profils disponibles

- `Defaults`  
  Proche des valeurs par défaut Windows 11 :
  - Interrupt Moderation : Enabled  
  - Buffers RX/TX : 512  
  - `NetworkThrottlingIndex` : 10  
  - TCP/Nagle : `TcpAckFrequency=2`, `TCPNoDelay` + `TcpDelAckTicks` supprimés (Nagle actif)

- `Conservateur`  
  Compromis stabilité/latence :
  - Interrupt Moderation : Enabled  
  - Buffers RX/TX : 256  
  - `NetworkThrottlingIndex` : 10  
  - TCP/Nagle : `TcpAckFrequency=2`, `TCPNoDelay=0`

- `Agressif`  
  Latence réduite au détriment de l’occupation CPU :
  - Interrupt Moderation : Disabled  
  - Buffers RX/TX : 128  
  - `NetworkThrottlingIndex` : `0xffffffff` (désactivé)  
  - TCP/Nagle : `TcpAckFrequency=1`, `TCPNoDelay=1`

- `Ultra`  
  Profil très agressif (à tester) :
  - Interrupt Moderation : Disabled  
  - Buffers RX/TX : 64  
  - `NetworkThrottlingIndex` : `0xffffffff`  
  - TCP/Nagle : `TcpAckFrequency=1`, `TCPNoDelay=1`, `TcpDelAckTicks=0`

- `Restore`  
  Restaure un backup existant (`-RestoreVersion` requis).

- `ListBackups`  
  Liste les backups existants (nom + profil + adaptateur + date).

- `Diff`  
  Compare deux backups (ou les deux plus récents si `-Backup1`/`-Backup2` non fournis).

- `ShowAdapters`  
  Affiche les cartes réseau actives, leurs IPs et descriptions (pour trouver facilement le `-AdapterName`).

---

## Paramètres

- `-Profile` (obligatoire)  
  `Defaults | Conservateur | Agressif | Ultra | Restore | ListBackups | Diff | ShowAdapters`

- `-AdapterName` (optionnel, défaut : `"Ethernet"`)  
  Nom ou motif de l’alias d’interface (par ex. `"Ethernet"`, `"LAN"`).  
  Utilisé pour les profils (Defaults/Conservateur/Agressif/Ultra) et pour les backups liés à un adaptateur.

- `-BackupDir` (optionnel)  
  Répertoire où sont stockés les backups JSON.  
  Défaut : `C:\ProgramData\NetGamingProfiles`.

- `-BackupName` (optionnel)  
  Nom personnalisé du fichier de backup (sans chemin, `.json` ajouté si absent).  
  Le script préfixe toujours ce nom par le timestamp, par ex. :  
  `20260106-141500_avant_test_ultra.json`.

- `-RestoreVersion` (requis pour `Profile=Restore`)  
  Nom du fichier JSON à restaurer (sans chemin, dans `-BackupDir`).

- `-Backup1`, `-Backup2` (optionnels pour `Profile=Diff`)  
  Noms de fichiers JSON à comparer.  
  Si absents, les deux backups les plus récents (selon le système de fichiers) sont utilisés.

- `-DryRun` (optionnel)  
  Mode aperçu :
  - Avec `Profile=Restore` : backup de l’état courant puis diff entre l’état courant et le backup cible, sans restaurer.
  - Avec `Profile=Defaults/Conservateur/Agressif/Ultra` : affiche ce que le profil va faire, sans écrire.

---

## Exemples d’usage

### Lister les cartes réseau et leurs IP

```powershell
.\NetGamingOptimizer.ps1 -Profile ShowAdapters
```

### Appliquer un profil agressif (avec backup auto)

```powershell
.\NetGamingOptimizer.ps1 -Profile Agressif -AdapterName "Ethernet"
```

### Appliquer le profil Defaults pour revenir proche des valeurs stock

```powershell
.\NetGamingOptimizer.ps1 -Profile Defaults -AdapterName "Ethernet"
```

### Appliquer un profil avec un nom de backup personnalisé

```powershell
.\NetGamingOptimizer.ps1 -Profile Ultra -AdapterName "Ethernet" -BackupName "avant_test_ultra"
```

### Lister les backups

```powershell
.\NetGamingOptimizer.ps1 -Profile ListBackups
```

### Comparer les deux derniers backups

```powershell
.\NetGamingOptimizer.ps1 -Profile Diff
```

### Comparer deux backups précis

```powershell
.\NetGamingOptimizer.ps1 -Profile Diff -Backup1 "20260106-140000_backup_Ethernet_Agressif.json" -Backup2 "20260106-141000_backup_Ethernet_Ultra.json"
```

### Dry-run d’un profil (aperçu sans appliquer)

```powershell
.\NetGamingOptimizer.ps1 -Profile Agressif -AdapterName "Ethernet" -DryRun
```

### Dry-run d’une restauration

```powershell
.\NetGamingOptimizer.ps1 -Profile Restore -RestoreVersion "20260106-140000_backup_Ethernet_Agressif.json" -DryRun
```

---

## Emplacement des sauvegardes

Par défaut :

- `C:\ProgramData\NetGamingProfiles`

Ce dossier peut être modifié via `-BackupDir`.  
Les fichiers sont de simples JSON, facilement versionnables (Git, sauvegardes, etc.).

---

## Avertissements

- Toujours tester en dry-run (`-DryRun`) avant de pousser un profil agressif sur une machine sensible.
- Certains noms de propriétés NIC (`DisplayName`) varient selon le pilote (Intel, Realtek, etc.).  
  Ajuster si besoin avec :

```powershell
Get-NetAdapterAdvancedProperty -Name "Ethernet" -AllProperties
```

---

## Contribution

- Issues / PR bienvenues pour :
  - Support de cartes particulières (Intel/Realtek/2.5G/10G)
  - Profils supplémentaires
  - UI (WinUI/WPF) ou wrapper CLI plus friendly
```
