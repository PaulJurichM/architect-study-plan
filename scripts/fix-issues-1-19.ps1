# Разовое исправление после сбоя синхронизации 26.09.2026: восстанавливает заголовки, milestones
# и метки issues #1–#19 по scripts/modules.json. Описания (и отмеченные галочки) не трогает.
# Запуск: powershell -ExecutionPolicy Bypass -File "$HOME\Projects\architect-study-plan\scripts\fix-issues-1-19.ps1"

$ErrorActionPreference = 'Continue'
$repo = 'PaulJurichM/architect-study-plan'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$data = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'modules.json'), $utf8) | ConvertFrom-Json
$blockLabels = @($data.labels | ForEach-Object { $_.name })
$failed = @()

for ($n = 1; $n -le 19; $n++) {
    $i = $data.issues[$n - 1]
    $current = (gh issue view $n --repo $repo --json labels,body | Out-String | ConvertFrom-Json)
    $path = [regex]::Match($i.body, 'blob/main/([^)\s]+?\.md)').Groups[1].Value
    if (-not $current.body.Contains("blob/main/$path")) {
        Write-Host "#$n : описание не совпадает с модулем $path — пропускаю" -ForegroundColor Yellow
        $failed += $n; continue
    }
    $args2 = @('--title', $i.title, '--milestone', $i.milestone, '--add-label', $i.label)
    foreach ($l in @($current.labels | ForEach-Object { $_.name })) {
        if ($blockLabels -contains $l -and $l -ne $i.label) { $args2 += @('--remove-label', $l) }
    }
    $ok = $false
    for ($try = 1; $try -le 3 -and -not $ok; $try++) {
        gh issue edit $n --repo $repo @args2 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok = $true } else { Start-Sleep -Seconds 3 }
    }
    if ($ok) { Write-Host "#$n : $($i.title)" } else { Write-Host "#$n : НЕ УДАЛОСЬ" -ForegroundColor Red; $failed += $n }
    Start-Sleep -Milliseconds 700
}
if ($failed.Count) { Write-Host "`nНе исправлены: $($failed -join ', '). Запустите скрипт ещё раз." -ForegroundColor Red }
else { Write-Host "`nВсе 19 issues восстановлены." -ForegroundColor Green }
