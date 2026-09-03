# WinOptimizer.psm1 - Ядро модуля

function Mount-HKCU {
    <#
    .SYNOPSIS
    Монтирует HKEY_USERS\<SID> текущего интерактивного пользователя в HKU: 
    для доступа к HKCU из-под администратора.
    #>
    $consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
    
    if ([string]::IsNullOrWhiteSpace($consoleUser)) {
        Write-Warning "Не удалось определить интерактивного пользователя (возможно, скрипт запущен без активной сессии консоли)."
        return $null
    }
    
    try {
        $objUser = New-Object System.Security.Principal.NTAccount($consoleUser)
        $sid = $objUser.Translate([System.Security.Principal.SecurityIdentifier]).Value
        
        if ($sid) {
            if (-not (Test-Path "HKU:")) {
                New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Global | Out-Null
            }
            return "HKU:\$sid"
        }
    } catch {
        Write-Warning "Ошибка при получении SID для пользователя '$consoleUser': $_"
    }
    
    return $null
}

function Invoke-PreFlightCheck {
    <#
    .SYNOPSIS
    Выполняет предварительные проверки (ОС, права, железо).
    Возвращает объект со статусами оборудования, чтобы Analyze/Apply могли пропускать SKIP-компоненты.
    #>
    Write-Verbose "[Pre-Flight] Запуск проверок системы..."

    # 1. Права администратора
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Скрипт должен быть запущен с правами Администратора."
    }

    # 2. Версия Windows
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.Caption -notmatch "Windows 11") {
        Write-Warning "Внимание: Эта конфигурация протестирована только на Windows 11. Текущая ОС: $($os.Caption)"
    }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) {
        Write-Warning "Внимание: Номер сборки ($build) ниже ожидаемого для Windows 11 (22000+)."
    }

    # 3. Hardware Capability Profile
    $hwProfile = @{
        HasNFC = $false
        HasBattery = $false
        HasCamera = $false
        HasNPU = $false
    }

    # Проверка NFC (упрощённо через PNPDeviceID / Win32_PnPEntity)
    if (Get-PnpDevice -Class Proximity -ErrorAction SilentlyContinue) {
        $hwProfile.HasNFC = $true
    }

    # Проверка батареи (Laptop)
    if (Get-WmiObject Win32_Battery -ErrorAction SilentlyContinue) {
        $hwProfile.HasBattery = $true
    }

    # Проверка камеры
    if (Get-PnpDevice -Class Image -ErrorAction SilentlyContinue | Where-Object Status -eq "OK") {
        $hwProfile.HasCamera = $true
    }
    if (Get-PnpDevice -Class Camera -ErrorAction SilentlyContinue | Where-Object Status -eq "OK") {
        $hwProfile.HasCamera = $true
    }

    # Проверка NPU (упрощённо через имя в диспетчере устройств)
    if (Get-PnpDevice | Where-Object { $_.FriendlyName -match "NPU|Neural Processing Unit" -and $_.Status -eq "OK" }) {
        $hwProfile.HasNPU = $true
    }

    Write-Verbose "[Pre-Flight] Проверка завершена. Профиль оборудования:"
    $hwProfile.GetEnumerator() | ForEach-Object { Write-Verbose "  $($_.Name): $($_.Value)" }

    return $hwProfile
}

# -----------------
# GETTERS
# -----------------

function Get-AppxState {
    param([string]$PackageName)
    $pkg = Get-AppxPackage -Name $PackageName -AllUsers -ErrorAction SilentlyContinue
    if ($pkg) {
        return "Installed"
    }
    return "Absent"
}

function Get-ServiceState {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        return $svc.StartType.ToString() # "Automatic", "Disabled", "Manual"
    }
    return "Absent"
}

function Get-RegistryState {
    param(
        [string]$Hive,
        [string]$Path,
        [string]$Name
    )
    
    # Обработка HKCU
    $actualHive = $Hive
    if ($Hive -eq "HKCU") {
        $mounted = Mount-HKCU
        if ($mounted) {
            $actualHive = $mounted
        } else {
            throw "Не удалось примонтировать HKCU интерактивного пользователя. Пропуск компонента для предотвращения повреждения реестра."
        }
    } elseif ($Hive -eq "HKLM") {
        $actualHive = "HKLM:"
    }

    # Формируем полный путь для PowerShell
    $fullPath = Join-Path $actualHive $Path
    
    try {
        $val = Get-ItemPropertyValue -Path $fullPath -Name $Name -ErrorAction Stop
        $key = Get-Item -Path $fullPath -ErrorAction Stop
        $kind = $key.GetValueKind($Name).ToString()
        return @{ Value = $val; Type = $kind }
    } catch {
        return $null # Не существует ключа или значения
    }
}

function Get-ScheduledTaskState {
    param([string[]]$TaskPaths)
    $states = @()
    foreach ($path in $TaskPaths) {
        $task = $null
        if ($path -match "^(.*)\\([^\\]+)$") {
            $parent = $matches[1]
            $tName = $matches[2]
            $tPath = if ($parent -eq "") { "\" } else { "$parent\" }
            $task = Get-ScheduledTask -TaskPath $tPath -TaskName $tName -ErrorAction SilentlyContinue
        } else {
            $task = Get-ScheduledTask -TaskPath "\" -TaskName $path -ErrorAction SilentlyContinue
        }
        
        if ($task) {
            $states += $task.State.ToString()
        } else {
            $states += "Absent"
        }
    }
    return $states
}

$script:OptFeatureCache = $null

function Get-OptionalFeatureState {
    [CmdletBinding()]
    param([string]$FeatureName)
    
    if ($null -eq $script:OptFeatureCache) {
        Write-Host "[DISM] Кэширование списка Optional Features (через dism.exe)..." -ForegroundColor Yellow
        $script:OptFeatureCache = @{}
        $dismOut = dism.exe /Online /Get-Features /English
        $currentFeat = $null
        foreach ($line in $dismOut) {
            if ($line -match "^Feature Name : (.*)$") {
                $currentFeat = $matches[1].Trim()
            } elseif ($line -match "^State : (.*)$" -and $currentFeat) {
                $script:OptFeatureCache[$currentFeat] = $matches[1].Trim()
                $currentFeat = $null
            }
        }
        Write-Host "[DISM] Кэширование Optional Features завершено." -ForegroundColor Green
    }
    
    if ($script:OptFeatureCache.ContainsKey($FeatureName)) {
        return $script:OptFeatureCache[$FeatureName] # "Enabled" или "Disabled"
    }
    return "Absent"
}

$script:CapabilityCache = $null

function Get-CapabilityState {
    [CmdletBinding()]
    param([string]$FeatureName)
    
    if ($null -eq $script:CapabilityCache) {
        Write-Host "[DISM] Кэширование списка Capabilities (через dism.exe)..." -ForegroundColor Yellow
        $script:CapabilityCache = @{}
        $dismOut = dism.exe /Online /Get-Capabilities /English
        $currentCap = $null
        foreach ($line in $dismOut) {
            if ($line -match "^Capability Identity : (.*)$") {
                $currentCap = $matches[1].Trim()
            } elseif ($line -match "^State : (.*)$" -and $currentCap) {
                # DISM выводит "Not Present" с пробелом, нормализуем под старый формат
                $state = $matches[1].Trim() -replace " ", ""
                $script:CapabilityCache[$currentCap] = $state
                $currentCap = $null
            }
        }
        Write-Host "[DISM] Кэширование Capabilities завершено." -ForegroundColor Green
    }
    
    if ($script:CapabilityCache.ContainsKey($FeatureName)) {
        return $script:CapabilityCache[$FeatureName]
    }
    return "Absent"
}


# -----------------
# SETTERS
# -----------------

function Set-AppxState {
    [CmdletBinding()]
    param([string]$PackageName, [string]$Action)
    
    $before = Get-AppxState -PackageName $PackageName
    $after = $before
    
    if ($Action -eq "REMOVE" -and $before -eq "Installed") {
        Write-Verbose "[Appx] Удаление $PackageName"
        Get-AppxPackage -Name $PackageName -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction Stop
        $after = "Absent"
    }
    
    return @{ before = $before; after = $after }
}

function Set-ServiceState {
    [CmdletBinding()]
    param([string]$ServiceName, [string]$Action, [string]$TargetStartType)
    
    $before = Get-ServiceState -ServiceName $ServiceName
    $after = $before
    
    if ($Action -eq "KEEP") {
        Write-Verbose "[Service] Сохранение текущего состояния (KEEP) для $ServiceName"
        return @{ before = $before; after = $after }
    }
    
    if ($Action -in @("DISABLE", "CONFIGURE")) {
        $actualTarget = if ($Action -eq "DISABLE") { "Disabled" } else { $TargetStartType }
        if ($before -ne $actualTarget -and $before -ne "Absent") {
            Write-Verbose "[Service] Изменение $ServiceName на $actualTarget"
            Set-Service -Name $ServiceName -StartupType $actualTarget -ErrorAction Stop
            if ($actualTarget -eq "Disabled") {
                Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            }
            $after = $actualTarget
        }
    }
    
    return @{ before = $before; after = $after }
}

function Set-RegistryState {
    [CmdletBinding()]
    param([string]$Hive, [string]$Path, [string]$Name, [string]$Type, [string]$Value, [string]$Action)
    
    $beforeObj = Get-RegistryState -Hive $Hive -Path $Path -Name $Name
    $beforeValue = if ($null -ne $beforeObj) { $beforeObj.Value } else { $null }
    $beforeType  = if ($null -ne $beforeObj) { $beforeObj.Type } else { $null }
    
    $afterValue = $beforeValue
    
    if ($Action -eq "KEEP") {
        Write-Verbose "[Registry] Сохранение текущего состояния (KEEP) для $Hive\$Path\$Name"
        return @{ before = $beforeValue; before_type = $beforeType; after = $afterValue }
    }

    $actualHive = $Hive
    if ($Hive -eq "HKCU") {
        $mounted = Mount-HKCU
        if ($mounted) { 
            $actualHive = $mounted 
        } else { 
            throw "Не удалось примонтировать HKCU интерактивного пользователя. Пропуск компонента для предотвращения повреждения реестра." 
        }
    } elseif ($Hive -eq "HKLM") {
        $actualHive = "HKLM:"
    }
    
    $fullPath = Join-Path $actualHive $Path

    if ($Action -eq "DISABLE" -or $Action -eq "CONFIGURE") {
        if ($beforeValue -ne $Value) {
            Write-Verbose "[Registry] Запись $fullPath\$Name = $Value ($Type)"
            if (-not (Test-Path $fullPath)) {
                New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
            }
            
            # Конвертация типов для реестра
            $regType = "String"
            if ($Type -eq "REG_DWORD") { $regType = "DWord"; $Value = [int]$Value }
            elseif ($Type -eq "REG_QWORD") { $regType = "QWord"; $Value = [long]$Value }
            elseif ($Type -eq "REG_BINARY") { $regType = "Binary"; $Value = [byte[]]$Value } # Упрощенно
            elseif ($Type -eq "REG_MULTI_SZ") { $regType = "MultiString" }
            elseif ($Type -eq "REG_EXPAND_SZ") { $regType = "ExpandString" }
            
            Set-ItemProperty -Path $fullPath -Name $Name -Value $Value -Type $regType -ErrorAction Stop
            $afterValue = $Value
        }
    } elseif ($Action -eq "REMOVE" -or $Action -eq "CLEAR") {
        if ($beforeValue -ne $null) {
            Write-Verbose "[Registry] Удаление $fullPath\$Name"
            Remove-ItemProperty -Path $fullPath -Name $Name -ErrorAction Stop
            $afterValue = $null
        }
    }
    
    return @{ before = $beforeValue; before_type = $beforeType; after = $afterValue }
}

function Set-ScheduledTaskState {
    [CmdletBinding()]
    param([string[]]$TaskPaths, [string]$Action)
    
    $beforeStates = @()
    $afterStates = @()

    foreach ($path in $TaskPaths) {
        $task = $null
        if ($path -match "^(.*)\\([^\\]+)$") {
            $parent = $matches[1]
            $tName = $matches[2]
            $tPath = if ($parent -eq "") { "\" } else { "$parent\" }
            $task = Get-ScheduledTask -TaskPath $tPath -TaskName $tName -ErrorAction SilentlyContinue
        } else {
            $task = Get-ScheduledTask -TaskPath "\" -TaskName $path -ErrorAction SilentlyContinue
        }

          if ($task) {
              $stateBefore = $task.State.ToString()
              
              if ($stateBefore -in @("Ready", "Running", "Queued")) {
                  $configStateBefore = "Enabled"
              } else {
                  $configStateBefore = $stateBefore
              }
              
              $beforeStates += $configStateBefore
              
              if ($Action -eq "DISABLE" -and $stateBefore -ne "Disabled") {
                  Write-Verbose "[Task] Отключение задачи $path"
                  Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
                  $afterStates += "Disabled"
              } elseif ($Action -eq "REMOVE") {
                  Write-Verbose "[Task] Удаление задачи $path"
                  Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
                  $afterStates += "Absent"
              } else {
                  $afterStates += $configStateBefore
              }
          } else {
            $beforeStates += "Absent"
            $afterStates += "Absent"
        }
    }
    
    return @{ before = ($beforeStates -join ","); after = ($afterStates -join ",") }
}

function Set-OptionalFeatureState {
    [CmdletBinding()]
    param([string]$FeatureName, [string]$Action)
    
    $before = Get-OptionalFeatureState -FeatureName $FeatureName
    $after = $before
    
    if (($Action -eq "REMOVE" -or $Action -eq "DISABLE") -and $before -eq "Enabled") {
        Write-Verbose "[OptionalFeature] Отключение $FeatureName (dism.exe)"
        dism.exe /Online /Disable-Feature /FeatureName:$FeatureName /NoRestart
        if ($LASTEXITCODE -notin @(0, 3010)) {
            throw "DISM завершился с ошибкой (код $LASTEXITCODE) при отключении $FeatureName."
        }
        $after = "Disabled"
    }
    
    return @{ before = $before; after = $after }
}

function Set-CapabilityState {
    [CmdletBinding()]
    param([string]$FeatureName, [string]$Action)
    
    $before = Get-CapabilityState -FeatureName $FeatureName
    $after = $before
    
    if ($Action -eq "REMOVE" -and $before -eq "Installed") {
        Write-Verbose "[Capability] Удаление $FeatureName (dism.exe)"
        dism.exe /Online /Remove-Capability /CapabilityName:$FeatureName /NoRestart
        if ($LASTEXITCODE -notin @(0, 3010)) {
            throw "DISM завершился с ошибкой (код $LASTEXITCODE) при удалении $FeatureName."
        }
        $after = "NotPresent"
    }
    
    return @{ before = $before; after = $after }
}

function Write-AuditLog {
    [CmdletBinding()]
    param(
        [string]$LogPath,
        [string]$Automation,
        [object]$Locator,
        [object]$Before,
        [object]$After
    )
    
    $entry = [ordered]@{
        automation = $Automation
        locator = $Locator
        before = $Before
        after = $After
        timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    
    $json = $entry | ConvertTo-Json -Depth 5 -Compress
    Add-Content -Path $LogPath -Value $json -Encoding UTF8
}

function Test-StateEquals {
    param(
        [object]$Before,
        [object]$After
    )
    
    try {
        if ($null -eq $Before -and $null -eq $After) { return $true }
        if ($null -eq $Before -or $null -eq $After) { return $false }
        
        if ($Before.GetType() -ne $After.GetType()) { return $false }
        
        if ($Before -is [array]) {
            if ($Before.Length -ne $After.Length) { return $false }
            for ($i = 0; $i -lt $Before.Length; $i++) {
                if ($Before[$i] -ne $After[$i]) { return $false }
            }
            return $true
        }
        
        if ($Before -is [string]) {
            return $Before -ceq $After
        }
        
        return $Before.Equals($After)
    } catch {
        return $false
    }
}
