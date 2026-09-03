#Requires -RunAsAdministrator
# Restore.ps1 - Откат настроек WinOptimizer на основе лога

[CmdletBinding(SupportsShouldProcess=$true)]
param()
$RootDir = Split-Path $PSScriptRoot -Parent

$VerbosePreference = "Continue"
$LogPath = Join-Path $RootDir "applied_changes.jsonl"

Write-Verbose "=== Инициализация Restore ==="
if (-not (Test-Path $LogPath)) {
    Write-Error "Лог изменений $LogPath не найден. Откат невозможен."
    exit 1
}

Import-Module (Join-Path $RootDir "WinOptimizer\WinOptimizer.psd1") -Force
$hwProfile = Invoke-PreFlightCheck

Write-Verbose "Чтение лога..."
$lines = Get-Content $LogPath -Encoding UTF8
if (-not $lines -or $lines.Count -eq 0) {
    Write-Warning "Лог пуст. Нет изменений для отката."
    exit 0
}

# LIFO - с конца в начало
[array]::Reverse($lines)

$stats = @{ Restored = 0; Skipped = 0; Errors = 0 }

foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    
    try {
        $entry = $line | ConvertFrom-Json
        
        Write-Verbose "Откат: $($entry.automation) -> $($entry.locator | ConvertTo-Json -Compress)"
        
        $actionResult = $null

        if ($entry.automation -eq "Script" -or $entry.automation -eq "Manual") {
            Write-Verbose " -> Пропуск: Тип $($entry.automation) не поддерживает автоматический откат."
            $actionResult = "Skipped"
        } elseif (-not $PSCmdlet.ShouldProcess("Откат $($entry.automation)", "Restore state to $($entry.before)")) {
            Write-Host "WhatIf: Откат $($entry.automation)" -ForegroundColor Yellow
            $actionResult = "WhatIf"
        } else {
            switch ($entry.automation) {
                "Registry" {
                    $loc = $entry.locator
                    $actualHive = $loc.hive
                    if ($loc.hive -eq "HKCU") {
                        $actualHive = Mount-HKCU
                        if (-not $actualHive) {
                            Write-Warning "Не удалось примонтировать HKCU. Пропуск отката ключа $($loc.path)"
                            $actionResult = "Skipped"
                            break
                        }
                        $currentSid = $actualHive -replace "^HKU:\\", ""
                        if ($loc.sid -and ($loc.sid -ne $currentSid)) {
                            Write-Warning "SID mismatch: лог записан для пользователя $($loc.sid), а текущий профиль $currentSid. Пропуск отката ключа $($loc.path)"
                            $actionResult = "Skipped"
                            break
                        }
                    } elseif ($loc.hive -eq "HKLM") {
                        $actualHive = "HKLM:"
                    }
                    $fullPath = Join-Path $actualHive $loc.path

                    if ($null -eq $entry.before) {
                        Remove-ItemProperty -Path $fullPath -Name $loc.name -ErrorAction Stop
                    } else {
                        if (-not (Test-Path $fullPath)) { New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null }
                        if ($loc.type) {
                            Set-ItemProperty -Path $fullPath -Name $loc.name -Value $entry.before -Type $loc.type -ErrorAction Stop
                        } else {
                            Set-ItemProperty -Path $fullPath -Name $loc.name -Value $entry.before -ErrorAction Stop
                        }
                    }
                    $actionResult = "Restored"
                }
                "Service" {
                    $loc = $entry.locator
                    if ($entry.before -ne "Absent" -and $entry.before -ne "Unknown") {
                        Set-Service -Name $loc.service_name -StartupType $entry.before -ErrorAction Stop
                    }
                    $actionResult = "Restored"
                }
                "Appx" {
                    Write-Verbose " -> Откат Appx не полностью поддерживается. Требуется ручная переустановка из Store."
                    $actionResult = "Skipped"
                }
                "ScheduledTask" {
                    $loc = $entry.locator
                    $paths = @($loc.task_paths)
                    $states = @($entry.before -split ",")
                    
                    if ($paths.Count -ne $states.Count) {
                        throw "Количество путей ($($paths.Count)) не совпадает с количеством состояний ($($states.Count))."
                    }
                    
                    for ($i = 0; $i -lt $paths.Count; $i++) {
                        $path = $paths[$i]
                        $state = $states[$i]
                        
                        if ($state -in @("Ready", "Running", "Queued", "Enabled")) {
                            if ($path -match "^(.*)\\([^\\]+)$") {
                                $parent = $matches[1]
                                $tName = $matches[2]
                                $tPath = if ($parent -eq "") { "\" } else { "$parent\" }
                                Enable-ScheduledTask -TaskPath $tPath -TaskName $tName -ErrorAction Stop | Out-Null
                            } else {
                                Enable-ScheduledTask -TaskPath "\" -TaskName $path -ErrorAction Stop | Out-Null
                            }
                        } elseif ($state -eq "Absent") {
                            throw "Откат задачи $path невозможен: задача была удалена (Absent), XML-манифест не сохранён."
                        }
                    }
                    $actionResult = "Restored"
                }
                "OptionalFeature" {
                    $loc = $entry.locator
                    if ($entry.before -eq "Enabled") {
                        dism.exe /Online /Enable-Feature /FeatureName:$($loc.feature_name) /NoRestart
                        if ($LASTEXITCODE -notin @(0, 3010)) {
                            throw "DISM завершился с ошибкой (код $LASTEXITCODE) при восстановлении OptionalFeature $($loc.feature_name)."
                        }
                    }
                    $actionResult = "Restored"
                }
                "Capability" {
                    $loc = $entry.locator
                    if ($entry.before -eq "Installed") {
                        dism.exe /Online /Add-Capability /CapabilityName:$($loc.feature_name) /NoRestart
                        if ($LASTEXITCODE -notin @(0, 3010)) {
                            throw "DISM завершился с ошибкой (код $LASTEXITCODE) при восстановлении Capability $($loc.feature_name)."
                        }
                    }
                    $actionResult = "Restored"
                }
                default {
                    throw "Неизвестный тип automation: $($entry.automation)"
                }
            }
        }

        if ($null -eq $actionResult) {
            throw "Internal error: actionResult was not assigned for $($entry.automation)."
        }

        if ($actionResult -eq "Restored") { $stats.Restored++ }
        if ($actionResult -eq "Skipped") { $stats.Skipped++ }
    } catch {
        Write-Error "Ошибка отката записи: $($_.Exception.Message)"
        $stats.Errors++
    }
}

Write-Host "========================================="
Write-Host "Итоги отката WinOptimizer"
Write-Host "========================================="
Write-Host "Восстановлено (Restored): $($stats.Restored)"
Write-Host "Пропущено (Skipped): $($stats.Skipped)"
Write-Host "Ошибок (Errors): $($stats.Errors)"
Write-Host "========================================="
