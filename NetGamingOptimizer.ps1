<#
.SYNOPSIS
  Gestion de profils d'optimisation réseau (Gaming) avec backup versionné, diff et dry-run.

.PARAMETER Profile
  Nom du profil à appliquer : Defaults | Conservateur | Agressif | Ultra | Restore | ListBackups | Diff | ShowAdapters

.PARAMETER AdapterName
  Nom (ou motif) de la carte réseau (ex. "Ethernet").

.PARAMETER BackupDir
  Répertoire de stockage des backups JSON.

.PARAMETER BackupName
  Nom de fichier de backup personnalisé (optionnel, sans chemin).

.PARAMETER RestoreVersion
  Nom de fichier de backup à restaurer (sans chemin).

.PARAMETER Backup1
  Premier backup pour la diff (nom du fichier).

.PARAMETER Backup2
  Deuxième backup pour la diff (nom du fichier, optionnel = déduction auto si absent).

.PARAMETER DryRun
  Si présent, fait un aperçu (diff/infos) sans écrire dans le système.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Defaults","Conservateur","Agressif","Ultra","Restore","ListBackups","Diff","ShowAdapters")]
    [string]$Profile,

    [Parameter(Mandatory = $false)]
    [string]$AdapterName = "Ethernet",

    [Parameter(Mandatory = $false)]
    [string]$BackupDir = "$env:ProgramData\NetGamingProfiles",

    [Parameter(Mandatory = $false)]
    [string]$BackupName,

    [Parameter(Mandatory = $false)]
    [string]$RestoreVersion,

    [Parameter(Mandatory = $false)]
    [string]$Backup1,

    [Parameter(Mandatory = $false)]
    [string]$Backup2,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

# --- Fonctions utilitaires ---

function Show-AdaptersInfo {
    <#
    Affiche toutes les cartes réseau avec nom et IP(s)
    #>
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           CARTES RÉSEAU - ÉTAT COURANT                    ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    $adapters = Get-NetAdapter | Where-Object Status -eq "Up" | Sort-Object Name
    
    foreach ($adapter in $adapters) {
        $config = Get-NetIPConfiguration -InterfaceAlias $adapter.Name -ErrorAction SilentlyContinue
        $ipv4 = $config.IPv4Address.IPAddress -join ", " 
        $ipv6 = $config.IPv6Address.IPAddress -join ", "
        
        $status = $adapter.Status
        $statusColor = if ($status -eq "Up") { "Green" } else { "Yellow" }
        
        Write-Host "`n  [$(($adapters.IndexOf($adapter) + 1))] $('{0,-20}' -f $adapter.Name)" -ForegroundColor $statusColor -NoNewline
        Write-Host " | Status: " -NoNewline
        Write-Host $status -ForegroundColor $statusColor
        Write-Host "      Description: $('{0,-40}' -f $adapter.InterfaceDescription.Substring(0,[Math]::Min(40,$adapter.InterfaceDescription.Length)))"
        Write-Host "      IPv4: $ipv4"
        if ($ipv6) {
            Write-Host "      IPv6: $ipv6"
        }
    }
    Write-Host "`n"
}

function Ensure-BackupDir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-Adapter {
    param([string]$Name)
    $adapter = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
    if (-not $adapter) {
        # tente sur un motif
        $adapter = Get-NetAdapter -Name "*$Name*" -ErrorAction SilentlyContinue | Where-Object Status -eq "Up" | Select-Object -First 1
    }
    if (-not $adapter) {
        throw "Aucun adaptateur réseau trouvé pour '$Name'."
    }
    return $adapter
}

function Backup-NetworkState {
    param(
        [Microsoft.Management.Infrastructure.CimInstance]$Adapter,
        [string]$BackupDir,
        [string]$ProfileName,
        [string]$CustomName
    )

    Ensure-BackupDir -Path $BackupDir

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    if ($CustomName) {
        if (-not $CustomName.EndsWith(".json")) {
            $fileName = "$timestamp`_$CustomName.json"
        } else {
            $fileName = "$timestamp`_$CustomName"
        }
    } else {
        # pattern triable chronologiquement
        $fileName  = "${timestamp}_backup_${($Adapter.Name)}_${ProfileName}.json"
    }
    $fullPath  = Join-Path $BackupDir $fileName

    # Propriétés avancées NIC
    $advProps = Get-NetAdapterAdvancedProperty -Name $Adapter.Name -AllProperties -ErrorAction SilentlyContinue |
                Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue

    # Clés registre latence (Nagle, NetworkThrottlingIndex)
    $regBaseProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    $regProfile = Get-ItemProperty -Path $regBaseProfile -ErrorAction SilentlyContinue

    $regInterfacesPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    $interfaces = Get-ChildItem $regInterfacesPath | ForEach-Object {
        $props = Get-ItemProperty -Path $_.PsPath -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Guid            = $_.PSChildName
            DhcpIPAddress   = $props.DhcpIPAddress
            IPAddress       = $props.IPAddress
            TcpAckFrequency = $props.TcpAckFrequency
            TCPNoDelay      = $props.TCPNoDelay
            TcpDelAckTicks  = $props.TcpDelAckTicks
        }
    }

    $data = [PSCustomObject]@{
        Timestamp       = $timestamp
        Profile         = $ProfileName
        AdapterName     = $Adapter.Name
        AdapterDesc     = $Adapter.InterfaceDescription
        AdvancedProps   = @($advProps)
        RegSystemProfile= $regProfile
        RegInterfaces   = @($interfaces)
    }

    $data | ConvertTo-Json -Depth 5 | Out-File -FilePath $fullPath -Encoding UTF8

    Write-Host "✓ Backup sauvegardé : " -ForegroundColor Green -NoNewline
    Write-Host "$(Split-Path $fullPath -Leaf)" -ForegroundColor Cyan
    return @{
        FullPath = $fullPath
        FileName = Split-Path $fullPath -Leaf
        Data     = $data
    }
}

function Restore-NetworkState {
    param(
        [string]$BackupDir,
        [string]$FileName,
        [switch]$DryRunMode
    )

    if (-not $FileName) {
        throw "RestoreVersion est obligatoire pour Restore."
    }

    $fullPath = Join-Path $BackupDir $FileName
    if (-not (Test-Path $fullPath)) {
        throw "Backup introuvable : $fullPath"
    }

    $json = Get-Content $fullPath -Raw | ConvertFrom-Json

    if (-not $DryRunMode) {
        # Restaure propriétés avancées
        foreach ($p in $json.AdvancedProps) {
            try {
                if ($p.DisplayValue) {
                    Set-NetAdapterAdvancedProperty `
                        -Name $json.AdapterName `
                        -DisplayName $p.DisplayName `
                        -DisplayValue $p.DisplayValue `
                        -NoRestart -ErrorAction Stop
                }
            } catch {
                Write-Warning "Impossible de restaurer '$($p.DisplayName)': $($_.Exception.Message)"
            }
        }

        # Restaure SystemProfile (NetworkThrottlingIndex, etc.)
        $regBaseProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        if ($json.RegSystemProfile) {
            $props = $json.RegSystemProfile | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            foreach ($name in $props) {
                if ($name -match "^PS(Path|ParentPath|ChildName|Drive|Provider)") { continue }
                Set-ItemProperty -Path $regBaseProfile -Name $name -Value $json.RegSystemProfile.$name -ErrorAction SilentlyContinue
            }
        }

        # Restaure Nagle-like sur interfaces
        $regInterfacesPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
        foreach ($iface in $json.RegInterfaces) {
            $subKey = Join-Path $regInterfacesPath $iface.Guid
            if (Test-Path $subKey) {
                if ($null -ne $iface.TcpAckFrequency) {
                    Set-ItemProperty -Path $subKey -Name "TcpAckFrequency" -Value $iface.TcpAckFrequency -Type DWord -ErrorAction SilentlyContinue
                }
                if ($null -ne $iface.TCPNoDelay) {
                    Set-ItemProperty -Path $subKey -Name "TCPNoDelay" -Value $iface.TCPNoDelay -Type DWord -ErrorAction SilentlyContinue
                }
                if ($null -ne $iface.TcpDelAckTicks) {
                    Set-ItemProperty -Path $subKey -Name "TcpDelAckTicks" -Value $iface.TcpDelAckTicks -Type DWord -ErrorAction SilentlyContinue
                }
            }
        }

        Write-Host "✓ Restauration terminée à partir de : " -ForegroundColor Green -NoNewline
        Write-Host "$(Split-Path $fullPath -Leaf)" -ForegroundColor Cyan
    } else {
        Write-Host "Dry-run restauration : aucun changement appliqué." -ForegroundColor Yellow
    }
    
    return $json
}

function List-Backups {
    param([string]$BackupDir)
    
    Ensure-BackupDir -Path $BackupDir
    
    $backups = Get-ChildItem $BackupDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object Name
    
    if (-not $backups) {
        Write-Host "Aucun backup trouvé." -ForegroundColor Yellow
        return
    }
    
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                      BACKUPS EXISTANTS                     ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    $idx = 0
    $backups | ForEach-Object { 
        $idx++
        $jsonContent = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $timestamp = $jsonContent.Timestamp
        $profile = $jsonContent.Profile
        $adapter = $jsonContent.AdapterName
        
        Write-Host "  [$idx] " -NoNewline -ForegroundColor Cyan
        Write-Host "$($_.Name)" -ForegroundColor White
        Write-Host "      Carte: " -NoNewline
        Write-Host "$adapter" -ForegroundColor Yellow -NoNewline
        Write-Host " | Profil: " -NoNewline
        Write-Host "$profile" -ForegroundColor Green -NoNewline
        Write-Host " | Timestamp: $timestamp"
    }
    Write-Host ""
}

function Compare-Backups {
    param(
        [string]$BackupDir,
        [string]$File1,
        [string]$File2
    )
    
    Ensure-BackupDir -Path $BackupDir
    
    # Si File1 ou File2 pas spécifié, prend les 2 plus récents par nom (tri lexical = chrono grâce au timestamp)
    if (-not $File1 -or -not $File2) {
        $recent = Get-ChildItem $BackupDir -Filter "*.json" | Sort-Object Name -Descending | Select-Object -First 2
        if ($recent.Count -lt 2) {
            Write-Host "Besoin d'au moins 2 backups pour faire une diff." -ForegroundColor Yellow
            return
        }
        $File2 = $recent[0].Name
        $File1 = $recent[1].Name
    }
    
    $path1 = Join-Path $BackupDir $File1
    $path2 = Join-Path $BackupDir $File2
    
    if (-not (Test-Path $path1)) { throw "Backup non trouvé : $path1" }
    if (-not (Test-Path $path2)) { throw "Backup non trouvé : $path2" }
    
    $json1 = Get-Content $path1 -Raw | ConvertFrom-Json
    $json2 = Get-Content $path2 -Raw | ConvertFrom-Json
    
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    COMPARAISON BACKUPS                     ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    Write-Host "`n  ANCIEN (baseline) : $(Split-Path $path1 -Leaf)" -ForegroundColor Yellow
    Write-Host "  NOUVEAU (cible)   : $(Split-Path $path2 -Leaf)" -ForegroundColor Green
    
    # Comparaison des propriétés avancées NIC
    Write-Host "`n  ▸ Propriétés avancées NIC:" -ForegroundColor Cyan
    
    $dict1 = @{}
    $dict2 = @{}
    
    foreach ($p in $json1.AdvancedProps) {
        $key = "$($p.DisplayName)_$($p.RegistryKeyword)"
        $dict1[$key] = $p.DisplayValue
    }
    foreach ($p in $json2.AdvancedProps) {
        $key = "$($p.DisplayName)_$($p.RegistryKeyword)"
        $dict2[$key] = $p.DisplayValue
    }
    
    $allKeys = @($dict1.Keys) + @($dict2.Keys) | Sort-Object -Unique
    $diffCount = 0
    
    foreach ($k in $allKeys) {
        $v1 = $dict1[$k]
        $v2 = $dict2[$k]
        
        if ($v1 -ne $v2) {
            $diffCount++
            $displayName = $k -split "_" | Select-Object -First 1
            Write-Host "    ✗ $displayName" -NoNewline -ForegroundColor Red
            Write-Host " | Ancien: " -NoNewline
            Write-Host "$v1" -ForegroundColor Yellow -NoNewline
            Write-Host " → Nouveau: " -NoNewline
            Write-Host "$v2" -ForegroundColor Green
        }
    }
    
    if ($diffCount -eq 0) {
        Write-Host "    (Pas de différence)" -ForegroundColor DarkGreen
    }
    
    # Comparaison Registre SystemProfile
    Write-Host "`n  ▸ Paramètres SystemProfile (Registre):" -ForegroundColor Cyan
    
    $regDiff = 0
    $regKeys = @("NetworkThrottlingIndex")
    
    foreach ($key in $regKeys) {
        $v1 = $json1.RegSystemProfile.$key
        $v2 = $json2.RegSystemProfile.$key
        
        if ($v1 -ne $v2) {
            $regDiff++
            Write-Host "    ✗ $key" -NoNewline -ForegroundColor Red
            Write-Host " | Ancien: " -NoNewline
            Write-Host "$v1" -ForegroundColor Yellow -NoNewline
            Write-Host " → Nouveau: " -NoNewline
            Write-Host "$v2" -ForegroundColor Green
        }
    }
    
    if ($regDiff -eq 0) {
        Write-Host "    (Pas de différence)" -ForegroundColor DarkGreen
    }
    
    # Comparaison Nagle (interfaces)
    Write-Host "`n  ▸ Paramètres TCP (Nagle par interface):" -ForegroundColor Cyan
    
    $tcpDiff = 0
    foreach ($iface1 in $json1.RegInterfaces) {
        $iface2 = $json2.RegInterfaces | Where-Object Guid -eq $iface1.Guid
        if ($iface2) {
            $tcpKeys = "TcpAckFrequency", "TCPNoDelay", "TcpDelAckTicks"
            foreach ($tcpKey in $tcpKeys) {
                $v1 = $iface1.$tcpKey
                $v2 = $iface2.$tcpKey
                if ($v1 -ne $v2) {
                    $tcpDiff++
                    Write-Host "    ✗ $($iface1.Guid.Substring(0,8))... / $tcpKey" -NoNewline -ForegroundColor Red
                    Write-Host " | Ancien: " -NoNewline
                    Write-Host "$v1" -ForegroundColor Yellow -NoNewline
                    Write-Host " → Nouveau: " -NoNewline
                    Write-Host "$v2" -ForegroundColor Green
                }
            }
        }
    }
    
    if ($tcpDiff -eq 0) {
        Write-Host "    (Pas de différence)" -ForegroundColor DarkGreen
    }
    
    Write-Host "`n  Total de différences: " -NoNewline -ForegroundColor Cyan
    $totalDiff = $diffCount + $regDiff + $tcpDiff
    Write-Host "$totalDiff" -ForegroundColor $(if ($totalDiff -gt 0) { "Red" } else { "Green" })
    Write-Host ""
}

function Apply-Profile {
    param(
        [string]$Profile,
        [Microsoft.Management.Infrastructure.CimInstance]$Adapter,
        [switch]$DryRunMode
    )

    $modeLabel = if ($DryRunMode) { "(DRY-RUN) " } else { "" }
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host ("║         APPLICATION PROFIL: {0}{1}" -f $modeLabel,$Profile).PadRight(60) -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    # Exemples de mappings DisplayName -> valeurs par profil (à adapter selon le driver).
    $settingsCommon = @(
        @{ DisplayName = "Energy-Efficient Ethernet"; Value = "Disabled" },
        @{ DisplayName = "Green Ethernet";           Value = "Disabled" },
        @{ DisplayName = "Power Saving Mode";        Value = "Disabled" }
    )

    $settingsDefaults = @(
        @{ DisplayName = "Interrupt Moderation";     Value = "Enabled" },
        @{ DisplayName = "Receive Buffers";          Value = "512" },
        @{ DisplayName = "Transmit Buffers";         Value = "512" }
    )

    $settingsConservateur = @(
        @{ DisplayName = "Interrupt Moderation";     Value = "Enabled" },
        @{ DisplayName = "Receive Buffers";          Value = "256" },
        @{ DisplayName = "Transmit Buffers";         Value = "256" }
    )

    $settingsAgressif = @(
        @{ DisplayName = "Interrupt Moderation";     Value = "Disabled" },
        @{ DisplayName = "Receive Buffers";          Value = "128" },
        @{ DisplayName = "Transmit Buffers";         Value = "128" }
    )

    $settingsUltra = @(
        @{ DisplayName = "Interrupt Moderation";     Value = "Disabled" },
        @{ DisplayName = "Receive Buffers";          Value = "64" },
        @{ DisplayName = "Transmit Buffers";         Value = "64" }
    )

    $allSettings = @()
    $allSettings += $settingsCommon
    switch ($Profile) {
        "Defaults"      { $allSettings += $settingsDefaults }
        "Conservateur"  { $allSettings += $settingsConservateur }
        "Agressif"      { $allSettings += $settingsAgressif }
        "Ultra"         { $allSettings += $settingsUltra }
    }

    Write-Host "`n  ▸ Propriétés avancées NIC:" -ForegroundColor Cyan
    
    foreach ($s in $allSettings) {
        try {
            if (-not $DryRunMode) {
                Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName $s.DisplayName -DisplayValue $s.Value -NoRestart -ErrorAction Stop
            }
            Write-Host "    ✓ $($s.DisplayName) → $($s.Value)" -ForegroundColor Green
        } catch {
            Write-Host "    ✗ $($s.DisplayName): Échec ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }

    # Tweaks registre Nagle + NetworkThrottlingIndex selon profil
    Write-Host "`n  ▸ Paramètres registre (SystemProfile):" -ForegroundColor Cyan
    
    $regBaseProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    switch ($Profile) {
        "Defaults" {
            if (-not $DryRunMode) {
                New-ItemProperty -Path $regBaseProfile -Name "NetworkThrottlingIndex" -PropertyType DWord -Value 10 -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Write-Host "    ✓ NetworkThrottlingIndex → 10 (default)" -ForegroundColor Green
        }
        "Conservateur" {
            if (-not $DryRunMode) {
                New-ItemProperty -Path $regBaseProfile -Name "NetworkThrottlingIndex" -PropertyType DWord -Value 10 -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Write-Host "    ✓ NetworkThrottlingIndex → 10" -ForegroundColor Green
        }
        "Agressif" {
            if (-not $DryRunMode) {
                New-ItemProperty -Path $regBaseProfile -Name "NetworkThrottlingIndex" -PropertyType DWord -Value 0xffffffff -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Write-Host "    ✓ NetworkThrottlingIndex → 0xffffffff (disabled)" -ForegroundColor Green
        }
        "Ultra" {
            if (-not $DryRunMode) {
                New-ItemProperty -Path $regBaseProfile -Name "NetworkThrottlingIndex" -PropertyType DWord -Value 0xffffffff -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Write-Host "    ✓ NetworkThrottlingIndex → 0xffffffff (disabled)" -ForegroundColor Green
        }
    }

    # Nagle sur toutes les interfaces
    Write-Host "`n  ▸ Paramètres TCP (Nagle):" -ForegroundColor Cyan
    
    $regInterfacesPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    $nagleCount = 0
    Get-ChildItem $regInterfacesPath | ForEach-Object {
        $path = $_.PsPath
        switch ($Profile) {
            "Defaults" {
                if (-not $DryRunMode) {
                    New-ItemProperty -Path $path -Name "TcpAckFrequency" -PropertyType DWord -Value 2 -Force -ErrorAction SilentlyContinue | Out-Null
                    Remove-ItemProperty -Path $path -Name "TCPNoDelay"     -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $path -Name "TcpDelAckTicks" -ErrorAction SilentlyContinue
                }
            }
            "Conservateur" {
                if (-not $DryRunMode) {
                    New-ItemProperty -Path $path -Name "TcpAckFrequency" -PropertyType DWord -Value 2 -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $path -Name "TCPNoDelay"      -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                }
            }
            "Agressif" {
                if (-not $DryRunMode) {
                    New-ItemProperty -Path $path -Name "TcpAckFrequency" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $path -Name "TCPNoDelay"      -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                }
            }
            "Ultra" {
                if (-not $DryRunMode) {
                    New-ItemProperty -Path $path -Name "TcpAckFrequency" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $path -Name "TCPNoDelay"      -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $path -Name "TcpDelAckTicks"  -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
        $nagleCount++
    }
    Write-Host "    ✓ Nagle $(if ($DryRunMode) { '(prêt) ' } else { 'appliqué ' })sur $nagleCount interface(s)" -ForegroundColor Green

    if (-not $DryRunMode) {
        Write-Host "`n  ⚠ Un redémarrage est recommandé pour consolidation complète." -ForegroundColor Yellow
    } else {
        Write-Host "`n  ⚠ Dry-run: aucune modification n'a été effectuée." -ForegroundColor Yellow
    }
    Write-Host ""
}

# --- Main ---

try {
    # Affiche info cartes réseau au démarrage (sauf si ShowAdapters, où c’est la seule action)
    if ($Profile -ne "ShowAdapters") {
        Show-AdaptersInfo
    }

    Ensure-BackupDir -Path $BackupDir

    switch ($Profile) {
        "ShowAdapters" {
            Show-AdaptersInfo
        }
        "Restore" {
            if (-not $RestoreVersion) {
                throw "Pour Restore, le paramètre -RestoreVersion est obligatoire."
            }

            # Backup de l'état courant avant de comparer/restaurer
            $adapter = Get-Adapter -Name $AdapterName
            $currentBackup = Backup-NetworkState -Adapter $adapter -BackupDir $BackupDir -ProfileName "BeforeRestore" -CustomName "current_before_restore"

            if ($DryRun) {
                $targetJson = Get-Content (Join-Path $BackupDir $RestoreVersion) -Raw | ConvertFrom-Json
                $tmpFile = Join-Path $BackupDir "tmp_restore_target.json"
                $targetJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $tmpFile -Encoding UTF8
                Compare-Backups -BackupDir $BackupDir -File1 $currentBackup.FileName -File2 "tmp_restore_target.json"
                Remove-Item $tmpFile -ErrorAction SilentlyContinue
                Write-Host "Dry-run: restauration non appliquée." -ForegroundColor Yellow
            } else {
                Restore-NetworkState -BackupDir $BackupDir -FileName $RestoreVersion -DryRunMode:$false | Out-Null
            }
        }
        "ListBackups" {
            List-Backups -BackupDir $BackupDir
        }
        "Diff" {
            Compare-Backups -BackupDir $BackupDir -File1 $Backup1 -File2 $Backup2
        }
        default {
            $adapter = Get-Adapter -Name $AdapterName
            
            # Backup avant modification
            $currentBackup = Backup-NetworkState -Adapter $adapter -BackupDir $BackupDir -ProfileName "Before_$Profile" -CustomName $BackupName
            
            if ($DryRun) {
                Write-Host "`nDry-run : affichage des changements attendus pour le profil $Profile." -ForegroundColor Yellow
                Apply-Profile -Profile $Profile -Adapter $adapter -DryRunMode:$true
                Write-Host "Dry-run: aucune modification réelle appliquée." -ForegroundColor Yellow
            } else {
                Apply-Profile -Profile $Profile -Adapter $adapter -DryRunMode:$false
            }
        }
    }

} catch {
    Write-Error $_.Exception.Message
}
