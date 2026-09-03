#Requires -RunAsAdministrator
# Apply.ps1 - Применение настроек WinOptimizer

[CmdletBinding(SupportsShouldProcess=$true)]
param()
$RootDir = Split-Path $PSScriptRoot -Parent

$VerbosePreference = "Continue"

$ConfigPath = Join-Path $RootDir "components.json"
$LogPath = Join-Path $RootDir "applied_changes.jsonl"

Write-Verbose "=== Инициализация Apply ==="
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Конфигурация $ConfigPath не найдена."
    exit 1
}

Import-Module (Join-Path $RootDir "WinOptimizer\WinOptimizer.psd1") -Force
$hwProfile = Invoke-PreFlightCheck

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$components = $config.components

# ФАЗЫ ПРИМЕНЕНИЯ (Строгий порядок из PRODUCT.md)
$phases = @(
    "Appx",
    "Service",
    "OptionalFeature",
    "Capability",
    "ScheduledTask",
    "Registry",
    "Script"
)

$stats = @{
    Applied = 0
    Skipped = 0
    Errors = 0
    Executed = 0
}

foreach ($phase in $phases) {
    Write-Host "`n>>> ФАЗА: $phase <<<" -ForegroundColor Cyan
    $phaseComponents = $components | Where-Object { $_.automation -eq $phase }
    
    foreach ($comp in $phaseComponents) {
        Write-Verbose "Обработка: [$($comp.id)] $($comp.name)"
        
        if ($comp.action -eq "SKIP" -or $comp.action -eq "-") {
            Write-Verbose "Пропущен (SKIP)"
            $stats.Skipped++
            continue
        }
        
        # Проверка на FIXME
        $isMissingData = $false
        if ($comp.automation -eq "Registry" -or $comp.automation -eq "GroupPolicy") {
            foreach ($val in $comp.payload.values) {
                if ($val.type -eq "FIXME" -or $val.value -eq "FIXME" -or $val.path -eq "FIXME") {
                    $isMissingData = $true; break
                }
            }
        } elseif ($comp.automation -eq "Script" -and $comp.payload.script_block -match "FIXME") {
            $isMissingData = $true
        }

        if ($isMissingData) {
            Write-Verbose "Пропущен (MISSING_DATA/FIXME)"
            $stats.Skipped++
            continue
        }
        
        if ($comp.action -eq "KEEP" -and $comp.automation -notin @("Registry", "Service")) {
            # Для не-Registry/Service KEEP означает "ничего не делать"
            Write-Verbose "Действие KEEP, пропуск."
            $stats.Skipped++
            continue
        }

        try {
            if ($PSCmdlet.ShouldProcess($comp.name, "Apply $($comp.action)")) {
                $result = $null
                $locator = $null

                switch ($comp.automation) {
                    "Appx" {
                        $result = Set-AppxState -PackageName $comp.payload.package_name -Action $comp.action
                        $locator = @{ package_name = $comp.payload.package_name }
                    }
                    "Service" {
                        $result = Set-ServiceState -ServiceName $comp.payload.service_name -Action $comp.action -TargetStartType $comp.payload.target_start_type
                        $locator = @{ service_name = $comp.payload.service_name }
                    }
                    "Registry" {
                        $registryChanged = $false
                        foreach ($val in $comp.payload.values) {
                            $targetSid = $null
                            if ($val.hive -eq "HKCU") {
                                $mnt = Mount-HKCU
                                if ($mnt -match "^HKU:\\(.*)$") {
                                    $targetSid = $matches[1]
                                } else {
                                    throw "Не удалось определить SID интерактивного пользователя для записи HKCU."
                                }
                            }
                            $r = Set-RegistryState -Hive $val.hive -Path $val.path -Name $val.name -Type $val.type -Value $val.value -Action $comp.action
                            $loc = @{ hive = $val.hive; path = $val.path; name = $val.name; type = $r.before_type }
                            if ($targetSid) { $loc.sid = $targetSid }
                            if (-not (Test-StateEquals -Before $r.before -After $r.after)) {
                                Write-AuditLog -LogPath $LogPath -Automation "Registry" -Locator $loc -Before $r.before -After $r.after
                                $registryChanged = $true
                            }
                        }
                        if ($registryChanged) { $stats.Applied++ } else { $stats.Skipped++ }
                        continue # Registry пишет лог внутри цикла по значениям
                    }
                    "ScheduledTask" {
                        $taskChanged = $false
                        foreach ($tpath in $comp.payload.task_paths) {
                            $result = Set-ScheduledTaskState -TaskPaths @($tpath) -Action $comp.action
                            $locator = @{ task_paths = @($tpath) }
                            if (-not (Test-StateEquals -Before $result.before -After $result.after)) {
                                Write-AuditLog -LogPath $LogPath -Automation "ScheduledTask" -Locator $locator -Before $result.before -After $result.after
                                $taskChanged = $true
                            }
                        }
                        if ($taskChanged) { $stats.Applied++ } else { $stats.Skipped++ }
                        continue
                    }
                    "Manual" {
                        Write-Verbose "Компонент Manual не поддерживается автоматизацией. Пропуск."
                        $stats.Skipped++
                        continue
                    }
                    "None" {
                        Write-Verbose "Компонент None не поддерживается автоматизацией. Пропуск."
                        $stats.Skipped++
                        continue
                    }
                    "OptionalFeature" {
                        $result = Set-OptionalFeatureState -FeatureName $comp.payload.feature_name -Action $comp.action
                        $locator = @{ feature_name = $comp.payload.feature_name }
                    }
                    "Capability" {
                        $result = Set-CapabilityState -FeatureName $comp.payload.feature_name -Action $comp.action
                        $locator = @{ feature_name = $comp.payload.feature_name }
                    }
                    "Script" {
                        $scriptBlock = [scriptblock]::Create($comp.payload.script_block)
                        Write-Verbose "[Script] Выполнение скрипта для $($comp.id)"
                        Invoke-Command -ScriptBlock $scriptBlock
                        $stats.Executed++
                        continue
                    }
                }

                if ($result -and $locator) {
                    if (-not (Test-StateEquals -Before $result.before -After $result.after)) {
                        Write-AuditLog -LogPath $LogPath -Automation $comp.automation -Locator $locator -Before $result.before -After $result.after
                        $stats.Applied++
                    } else {
                        $stats.Skipped++
                    }
                }
            } else {
                Write-Host "WhatIf: Выполнение $($comp.action) для $($comp.name)" -ForegroundColor Yellow
            }
        } catch {
            Write-Error "Ошибка применения $($comp.name): $($_.Exception.Message)"
            $stats.Errors++
        }
    }
}

Write-Host "========================================="
Write-Host "Итоги применения WinOptimizer"
Write-Host "========================================="
Write-Host "Изменено (Applied): $($stats.Applied)"
Write-Host "Пропущено (Skipped): $($stats.Skipped)"
Write-Host "Выполнено скриптов (Executed): $($stats.Executed)"
Write-Host "Ошибок (Errors): $($stats.Errors)"
Write-Host "========================================="
