#Requires -RunAsAdministrator
# Analyze.ps1 - Аудит состояния системы по components.json

[CmdletBinding()]
param()
$RootDir = Split-Path $PSScriptRoot -Parent

Write-Host "[DIAG] Скрипт Analyze.ps1 запущен."

$ConfigPath = Join-Path $RootDir "components.json"
$ReportPath = Join-Path $RootDir "analyze_report.txt"

Write-Host "[DIAG] Проверка файла конфигурации..."
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Не найден файл конфигурации: $ConfigPath"
    exit 1
}

Write-Host "[DIAG] Импорт модуля WinOptimizer.psd1..."
Import-Module (Join-Path $RootDir "WinOptimizer\WinOptimizer.psd1") -Force
Write-Host "[DIAG] Модуль импортирован."

Write-Host "[DIAG] Вызов Invoke-PreFlightCheck..."
$hwProfile = Invoke-PreFlightCheck
Write-Host "[DIAG] Invoke-PreFlightCheck завершен."

Write-Verbose "=== Чтение конфигурации ==="
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$components = $config.components

$stats = @{
    Compliant = 0
    Drift = 0
    MissingData = 0
    Skipped = 0
    Errors = 0
}

$report = @()

Write-Host "[DIAG] Начало цикла по компонентам..."
foreach ($comp in $components) {
    Write-Verbose "Анализ компонента: [$($comp.id)] $($comp.name)"
    
    if ($comp.action -eq "SKIP" -or $comp.action -eq "-") {
        Write-Verbose " -> Пропущен (SKIP/—)"
        $stats.Skipped++
        continue
    }

    $isMissingData = $false

    # Проверка на MISSING_DATA
    if ($comp.automation -eq "Registry" -or $comp.automation -eq "GroupPolicy") {
        foreach ($val in $comp.payload.values) {
            if ($val.type -eq "FIXME" -or $val.value -eq "FIXME" -or $val.path -eq "FIXME") {
                $isMissingData = $true
                break
            }
        }
    } elseif ($comp.automation -eq "Script") {
        if ($comp.payload.script_block -match "FIXME") {
            $isMissingData = $true
        }
    } elseif ($comp.automation -eq "Manual" -or $comp.automation -eq "None") {
        Write-Verbose " -> Ручной/None механизм (не анализируется автоматически)"
        $stats.Skipped++
        continue
    }

    if ($isMissingData) {
        Write-Verbose " -> MISSING_DATA (Присутствуют FIXME значения)"
        $stats.MissingData++
        $report += "[MISSING_DATA] $($comp.name) ($($comp.id))"
        continue
    }

    try {
        $drift = $false
        $currentState = "Unknown"
        $expectedState = "Unknown"

        switch ($comp.automation) {
            "Appx" {
                $currentState = Get-AppxState -PackageName $comp.payload.package_name
                if ($comp.action -eq "REMOVE") {
                    $expectedState = "Absent"
                } else {
                    $expectedState = "Installed"
                }
                if ($currentState -ne $expectedState) { $drift = $true }
            }
            "Service" {
                $currentState = Get-ServiceState -ServiceName $comp.payload.service_name
                $expectedState = $comp.payload.target_start_type
                if ($currentState -ne $expectedState) { $drift = $true }
            }
            "Registry" {
                foreach ($val in $comp.payload.values) {
                    $currentValObj = Get-RegistryState -Hive $val.hive -Path $val.path -Name $val.name
                    $actualValue = if ($null -ne $currentValObj) { $currentValObj.Value } else { $null }
                    $currentState = $actualValue
                    $expectedState = $val.value
                    
                    if ($comp.action -eq "DISABLE" -or $comp.action -eq "CONFIGURE" -or $comp.action -eq "KEEP") {
                        if (-not (Test-StateEquals -Before $actualValue -After $val.value)) { $drift = $true; break }
                    } elseif ($comp.action -eq "REMOVE" -or $comp.action -eq "CLEAR") {
                        if ($null -ne $actualValue) { $drift = $true; break }
                        $expectedState = "Null"
                    }
                }
            }
            "ScheduledTask" {
                $currentState = Get-ScheduledTaskState -TaskPaths $comp.payload.task_paths
                if ($comp.action -eq "DISABLE") {
                    if ($currentState -contains "Ready" -or $currentState -contains "Running") { $drift = $true }
                    $expectedState = "Disabled/Absent"
                } elseif ($comp.action -eq "REMOVE") {
                    if ($currentState -match "Ready|Disabled|Running") { $drift = $true }
                    $expectedState = "Absent"
                } else {
                    # KEEP
                    if ($currentState -contains "Absent") { $drift = $true }
                    $expectedState = "Ready/Running/Disabled"
                }
                $currentState = $currentState -join ", "
            }
            "OptionalFeature" {
                $currentState = Get-OptionalFeatureState -FeatureName $comp.payload.feature_name
                if ($comp.action -eq "REMOVE" -or $comp.action -eq "DISABLE") {
                    $expectedState = "Disabled/Absent"
                    if ($currentState -eq "Enabled") { $drift = $true }
                } else {
                    $expectedState = "Enabled"
                    if ($currentState -ne "Enabled") { $drift = $true }
                }
            }
            "Capability" {
                $currentState = Get-CapabilityState -FeatureName $comp.payload.feature_name
                if ($comp.action -eq "REMOVE") {
                    $expectedState = "NotPresent/Absent"
                    if ($currentState -eq "Installed") { $drift = $true }
                } else {
                    $expectedState = "Installed"
                    if ($currentState -ne "Installed") { $drift = $true }
                }
            }
            "Script" {
                # Скрипты оцениваются как Drift, если они не Manual, но у нас нет EvaluateScriptBlock
                # Пока что скрипты всегда в Drift, если Action != KEEP
                if ($comp.action -ne "KEEP") {
                    $drift = $true
                    $expectedState = "Executed"
                    $currentState = "Pending"
                }
            }
        }

        if ($drift) {
            $stats.Drift++
            $warnStr = if ($comp.confidence -eq "Low") { " [ВНИМАНИЕ: Low Confidence]" } else { "" }
            Write-Verbose " -> DRIFT: Ожидалось '$expectedState', получено '$currentState'$warnStr"
            $report += "[DRIFT] $($comp.name) ($($comp.id)) - Expected: $expectedState, Actual: $currentState$warnStr"
        } else {
            $stats.Compliant++
            Write-Verbose " -> COMPLIANT"
        }

    } catch {
        Write-Verbose " -> ОШИБКА: $($_.Exception.Message)"
        $stats.Errors++
        $report += "[ERROR] $($comp.name) ($($comp.id)) - $($_.Exception.Message)"
    }
}

Write-Host "========================================="
Write-Host "Итоги аудита WinOptimizer"
Write-Host "========================================="
Write-Host "Всего компонентов: $($components.Count)"
Write-Host "Соответствует (Compliant): $($stats.Compliant)"
Write-Host "Требует применения (Drift): $($stats.Drift)"
Write-Host "Пропущено (Skipped): $($stats.Skipped)"
Write-Host "Отсутствуют тех. данные (MissingData): $($stats.MissingData)"
Write-Host "Ошибок (Errors): $($stats.Errors)"
Write-Host "========================================="

$reportContent = $report -join "`r`n"
Set-Content -Path $ReportPath -Value $reportContent -Encoding UTF8
Write-Host "Отчёт сохранён в: $ReportPath"
