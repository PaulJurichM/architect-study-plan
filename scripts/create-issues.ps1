# Запускает в GitHub Actions синхронизацию меток, milestones и issues (workflow «Синхронизировать issues»)
# и ждёт её окончания. Вся логика — в scripts/sync_issues.py, этот файл только нажимает кнопку.
# Запуск: powershell -ExecutionPolicy Bypass -File .\scripts\create-issues.ps1

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Set-Location (Split-Path $PSScriptRoot -Parent)

$repo = gh repo view --json nameWithOwner -q .nameWithOwner
if ($LASTEXITCODE -ne 0 -or -not $repo) { Write-Host 'Не удалось определить репозиторий (нужен gh и клон репозитория).'; exit 1 }

$before = gh run list --repo $repo --workflow sync-issues.yml --limit 1 --json databaseId -q '.[0].databaseId'
gh workflow run sync-issues.yml --repo $repo
if ($LASTEXITCODE -ne 0) { Write-Host 'Не удалось запустить workflow. Проверьте, что файл .github/workflows/sync-issues.yml запушен.'; exit 1 }

$id = $null
for ($k = 0; $k -lt 20 -and -not $id; $k++) {
    Start-Sleep -Seconds 3
    $last = gh run list --repo $repo --workflow sync-issues.yml --limit 1 --json databaseId -q '.[0].databaseId'
    if ($last -and $last -ne $before) { $id = $last }
}
if (-not $id) { Write-Host "Запуск не появился. Посмотрите: https://github.com/$repo/actions"; exit 1 }
gh run watch $id --repo $repo --exit-status
gh run view $id --repo $repo --log | Select-String -Pattern 'Итого|ВНИМАНИЕ|создан|Ошибка' | ForEach-Object { $_.Line -replace '^.*?\d{2}Z ', '' }
