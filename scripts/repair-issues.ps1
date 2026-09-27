# Восстановление всех issues программы после сбоя синхронизации 26.09.2026.
# Для каждого issue #1..#N читает его описание, по пути к файлу модуля находит модуль в modules.json
# и выставляет правильные заголовок, milestone и метку. Описания и галочки не меняет.
# Каждый вызов gh — строго для одного номера issue. При превышении лимита GitHub ждёт и повторяет.
# Запуск: powershell -ExecutionPolicy Bypass -File "$HOME\Projects\architect-study-plan\scripts\repair-issues.ps1"

$ErrorActionPreference = 'Continue'
$repo = 'PaulJurichM/architect-study-plan'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$data = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'modules.json'), $utf8) | ConvertFrom-Json
$modules = @($data.issues | ForEach-Object { $_ })
$blockLabels = @($data.labels | ForEach-Object { $_.name })
$maxIssue = $modules.Count
$failed = @()

function Invoke-Gh([string[]]$ghArgs) {
    for ($try = 1; $try -le 6; $try++) {
        $out = & gh @ghArgs 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return $out }
        if ($out -match 'rate limit') {
            Write-Host "  лимит GitHub исчерпан, жду 5 минут (попытка $try из 6)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 300
        } else {
            Write-Host "  ошибка: $($out.Trim())" -ForegroundColor Yellow
            Start-Sleep -Seconds (5 * $try)
        }
    }
    return $null
}

for ($n = 1; $n -le $maxIssue; $n++) {
    $json = Invoke-Gh @('issue', 'view', "$n", '--repo', $repo, '--json', 'number,body,labels,title,milestone')
    if (-not $json) { $failed += $n; continue }
    $cur = $json | ConvertFrom-Json
    $m = $modules | Where-Object {
        $p = [regex]::Match($_.body, 'blob/main/([^)\s]+?\.md)').Groups[1].Value
        $p -and $cur.body -and $cur.body.Contains("blob/main/$p")
    } | Select-Object -First 1
    if (-not $m) { Write-Host "#$n : модуль не найден по описанию — пропускаю" -ForegroundColor Yellow; $failed += $n; continue }

    $curLabels = @($cur.labels | ForEach-Object { $_.name })
    $curMs = if ($cur.milestone) { $cur.milestone.title } else { '' }
    $wrongLabels = @($curLabels | Where-Object { $blockLabels -contains $_ -and $_ -ne $m.label })
    if ($cur.title -eq $m.title -and $curMs -eq $m.milestone -and ($curLabels -contains $m.label) -and $wrongLabels.Count -eq 0) {
        Write-Host "#$n : уже в порядке"; continue
    }
    $editArgs = @('issue', 'edit', "$n", '--repo', $repo, '--title', $m.title, '--milestone', $m.milestone, '--add-label', $m.label)
    foreach ($l in $wrongLabels) { $editArgs += @('--remove-label', $l) }
    if (Invoke-Gh $editArgs) { Write-Host "#$n : $($m.title)" } else { Write-Host "#$n : НЕ УДАЛОСЬ" -ForegroundColor Red; $failed += $n }
    Start-Sleep -Milliseconds 1500
}

if ($failed.Count) { Write-Host "`nНе исправлены: $($failed -join ', '). Запустите скрипт ещё раз позже." -ForegroundColor Red }
else { Write-Host "`nВсе $maxIssue issues в порядке." -ForegroundColor Green }
