# Создаёт метки, milestones и issues по модулям программы.
# Требуется GitHub CLI (gh), авторизованный под владельцем репозитория: gh auth status
# Запуск из любой папки:  powershell -ExecutionPolicy Bypass -File .\scripts\create-issues.ps1
# Повторный запуск безопасен: существующие milestones и issues (по заголовку) пропускаются.

$ErrorActionPreference = 'Continue'   # native-команды проверяются по $LASTEXITCODE
$repo = 'PaulJurichM/architect-study-plan'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$data = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'modules.json'), $utf8) | ConvertFrom-Json

foreach ($l in $data.labels) {
    gh label create $l.name --color $l.color --description $l.description --repo $repo --force | Out-Null
}
Write-Host "Метки готовы"

$existingMs = @(gh api "repos/$repo/milestones?state=all&per_page=100" | ConvertFrom-Json)
foreach ($m in $data.milestones) {
    if ($existingMs | Where-Object { $_.title -eq $m.title }) { continue }
    gh api "repos/$repo/milestones" -f "title=$($m.title)" -f "description=$($m.description)" | Out-Null
    Write-Host "Milestone: $($m.title)"
}

$existingIssues = @(gh issue list --repo $repo --state all --limit 200 --json title | ConvertFrom-Json)
foreach ($i in $data.issues) {
    if ($existingIssues | Where-Object { $_.title -eq $i.title }) { Write-Host "Пропущен (уже есть): $($i.title)"; continue }
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $i.body, $utf8)
    gh issue create --repo $repo --title $i.title --milestone $i.milestone --label $i.label --body-file $tmp | Out-Null
    Remove-Item $tmp
    Write-Host "Issue: $($i.title)"
}
Write-Host "Готово: https://github.com/$repo/milestones"
