# Создаёт метки, milestones и issues по модулям программы.
# Требуется GitHub CLI (gh), авторизованный под владельцем репозитория: gh auth status
# Запуск из любой папки:  powershell -ExecutionPolicy Bypass -File .\scripts\create-issues.ps1
# Повторный запуск безопасен: существующие milestones пропускаются, существующие issues (по пути к файлу модуля)
# обновляются — заголовок, milestone, метка; описание не трогается, чтобы не сбросить отмеченные галочки.

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

$existingIssues = @(gh issue list --repo $repo --state all --limit 500 --json number,title,body,milestone,labels | ConvertFrom-Json)
foreach ($i in $data.issues) {
    # Существующий issue ищется по пути к файлу модуля в описании — так переименование модуля не создаёт дубль
    $path = [regex]::Match($i.body, 'blob/main/([^)\s]+?\.md)').Groups[1].Value
    $found = $existingIssues | Where-Object { $_.body -and $path -and $_.body.Contains("blob/main/$path") } | Select-Object -First 1
    if (-not $found) { $found = $existingIssues | Where-Object { $_.title -eq $i.title } | Select-Object -First 1 }
    if ($found) {
        $editArgs = @()
        if ($found.title -ne $i.title) { $editArgs += @('--title', $i.title) }
        $ms = if ($found.milestone) { $found.milestone.title } else { '' }
        if ($ms -ne $i.milestone) { $editArgs += @('--milestone', $i.milestone) }
        if (-not ($found.labels | Where-Object { $_.name -eq $i.label })) { $editArgs += @('--add-label', $i.label) }
        if ($editArgs.Count -gt 0) {
            gh issue edit $found.number --repo $repo @editArgs | Out-Null
            Write-Host "Обновлён #$($found.number): $($i.title)"
        }
        continue
    }
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $i.body, $utf8)
    gh issue create --repo $repo --title $i.title --milestone $i.milestone --label $i.label --body-file $tmp | Out-Null
    Remove-Item $tmp
    Write-Host "Создан: $($i.title)"
}
Write-Host "Готово: https://github.com/$repo/milestones"
