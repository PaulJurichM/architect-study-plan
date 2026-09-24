# Публикация программы на GitHub: коммит, репозиторий, GitHub Pages, issues.
# Запуск (PowerShell, из любой папки):
#   powershell -ExecutionPolicy Bypass -File "$HOME\Projects\architect-study-plan\scripts\publish.ps1"
# Повторный запуск безопасен. Своё сообщение коммита: ... publish.ps1 -Message "Заметки к 2.1"

param([string]$Message = 'Update study plan')

$ErrorActionPreference = 'Continue'   # native-команды проверяются по $LASTEXITCODE
$owner = 'PaulJurichM'
$name  = 'architect-study-plan'
$repo  = "$owner/$name"
$root  = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

if (-not (Has git)) { Write-Host 'git не найден. Установите: winget install Git.Git'; exit 1 }

Step 'Локальный репозиторий'
if (-not (Test-Path .git)) { git init -b main | Out-Null }
git add -A
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    $msgFile = [System.IO.Path]::GetTempFileName()
    $msg = "$Message`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01Y7eHyoDQAq1rpW3Kd5ePZc`n"
    [System.IO.File]::WriteAllText($msgFile, $msg, (New-Object System.Text.UTF8Encoding $false))
    git commit -q -F $msgFile
    Remove-Item $msgFile
    Write-Host 'Коммит создан'
} else { Write-Host 'Изменений нет' }

$hasGh = Has gh
if ($hasGh) {
    gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'GitHub CLI не авторизован. Выполните: gh auth login   и запустите скрипт ещё раз.' -ForegroundColor Yellow
        exit 1
    }
}

Step 'Репозиторий на GitHub'
$remoteUrl = "https://github.com/$repo.git"
if (-not (git remote 2>$null | Select-String -SimpleMatch 'origin')) { git remote add origin $remoteUrl }
if ($hasGh) {
    gh repo view $repo --json name 2>$null | Out-Null
} else {
    $env:GCM_INTERACTIVE = 'never'; $env:GIT_TERMINAL_PROMPT = '0'
    git ls-remote $remoteUrl 2>$null | Out-Null
    Remove-Item Env:GCM_INTERACTIVE, Env:GIT_TERMINAL_PROMPT
}
if ($LASTEXITCODE -ne 0) {
    if ($hasGh) {
        gh repo create $repo --public --description 'Study plan for a systems analyst / solution architect: HTTP & API security, PostgreSQL internals, microservices & DDD' | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host 'Не удалось создать репозиторий'; exit 1 }
        Write-Host "Создан https://github.com/$repo"
    } else {
        Write-Host "Репозитория ещё нет, а GitHub CLI не установлен." -ForegroundColor Yellow
        Write-Host "1) Создайте ПУСТОЙ публичный репозиторий: https://github.com/new?name=$name&visibility=public"
        Write-Host "   (без README, .gitignore и лицензии)"
        Write-Host "2) Запустите этот скрипт ещё раз."
        exit 1
    }
}
git push -u origin main
if ($LASTEXITCODE -ne 0) { Write-Host 'git push не прошёл' -ForegroundColor Red; exit 1 }

if (-not $hasGh) {
    Write-Host "`nКод опубликован. GitHub CLI не найден, поэтому Pages и issues не настроены." -ForegroundColor Yellow
    Write-Host "Либо установите его (winget install GitHub.cli, затем gh auth login) и запустите скрипт снова,"
    Write-Host "либо включите Pages вручную: https://github.com/$repo/settings/pages -> Deploy from a branch -> main / (root)"
    exit 0
}

Step 'GitHub Pages'
gh api "repos/$repo/pages" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    gh api -X POST "repos/$repo/pages" -f 'source[branch]=main' -f 'source[path]=/' | Out-Null
    Write-Host 'Pages включены, первая сборка займёт 1–2 минуты'
} else { Write-Host 'Pages уже включены' }
gh repo edit $repo --homepage "https://$($owner.ToLower()).github.io/$name/" | Out-Null

Step 'Milestones и issues'
& (Join-Path $PSScriptRoot 'create-issues.ps1')

Write-Host "`nГотово:" -ForegroundColor Green
Write-Host "  Сайт:     https://$($owner.ToLower()).github.io/$name/"
Write-Host "  Репо:     https://github.com/$repo"
Write-Host "  Прогресс: https://github.com/$repo/milestones"
