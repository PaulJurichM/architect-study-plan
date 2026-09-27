# Публикация программы на GitHub: коммит, push, GitHub Pages.
# Запуск (PowerShell, из любой папки):
#   powershell -ExecutionPolicy Bypass -File "$HOME\Projects\architect-study-plan\scripts\publish.ps1"
# Своё сообщение коммита:  ... publish.ps1 -Message "Заметки к 2.1"
# Issues синхронизирует GitHub Actions (workflow «Синхронизировать issues») — автоматически при изменении
# scripts/modules.json; запустить вручную можно ключом -SyncIssues.
# Первая публикация из папки без git (создать репозиторий на GitHub): ключ -Init.

param([string]$Message = 'Update study plan', [switch]$SyncIssues, [switch]$Init)

$ErrorActionPreference = 'Continue'   # native-команды проверяются по $LASTEXITCODE
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

if (-not (Has git)) { Write-Host 'git не найден. Установите: winget install Git.Git'; exit 1 }
if (-not (Has gh)) { Write-Host 'GitHub CLI не найден. Установите: winget install GitHub.cli, затем gh auth login'; exit 1 }
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'GitHub CLI не авторизован. Выполните: gh auth login' -ForegroundColor Yellow; exit 1 }

if (-not (Test-Path .git)) {
    if (-not $Init) {
        Write-Host "Папка $root — не клон репозитория (нет .git)." -ForegroundColor Red
        Write-Host 'Публикуйте из папки, куда репозиторий склонирован (git clone ...).'
        Write-Host 'Если это действительно первая публикация и репозитория на GitHub ещё нет — запустите с ключом -Init.'
        exit 1
    }
    git init -b main | Out-Null
}

# Репозиторий определяется по origin; без origin (первая публикация) — по вашему логину и имени папки
$remote = git remote get-url origin 2>$null
if ($remote -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$') { $owner = $Matches[1]; $name = $Matches[2] }
else { $owner = gh api user --jq .login; $name = Split-Path $root -Leaf }
$repo = "$owner/$name"
$site = "https://$($owner.ToLower()).github.io/$name/"

Step 'Коммит'
git add -A
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    $msgFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($msgFile, "$Message`n", (New-Object System.Text.UTF8Encoding $false))
    git commit -q -F $msgFile
    Remove-Item $msgFile
    Write-Host 'Коммит создан'
} else { Write-Host 'Изменений нет' }

Step "Репозиторий $repo"
gh repo view $repo --json name 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    if (-not $Init) { Write-Host "Репозиторий $repo на GitHub не найден." -ForegroundColor Red; exit 1 }
    gh repo create $repo --public --description 'Study plan for a systems analyst / solution architect' | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host 'Не удалось создать репозиторий'; exit 1 }
    Write-Host "Создан https://github.com/$repo"
}
if (-not $remote) { git remote add origin "https://github.com/$repo.git" }
git push -u origin main
if ($LASTEXITCODE -ne 0) {
    Write-Host 'git push не прошёл. Если на GitHub есть коммиты, которых нет здесь, выполните git pull --rebase и повторите. Никогда не используйте push --force.' -ForegroundColor Red
    exit 1
}

Step 'GitHub Pages'
gh api "repos/$repo/pages" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    gh api -X POST "repos/$repo/pages" -f 'source[branch]=main' -f 'source[path]=/' | Out-Null
    Write-Host 'Pages включены, первая сборка займёт 1–2 минуты'
} else { Write-Host 'Pages уже включены' }
gh repo edit $repo --homepage $site | Out-Null

if ($SyncIssues) {
    Step 'Milestones и issues'
    & (Join-Path $PSScriptRoot 'create-issues.ps1')
} else {
    Write-Host "`nIssues обновит GitHub Actions, если менялся scripts/modules.json. Запустить вручную: ключ -SyncIssues."
}

Write-Host "`nГотово:" -ForegroundColor Green
Write-Host "  Сайт:     $site"
Write-Host "  Репо:     https://github.com/$repo"
Write-Host "  Actions:  https://github.com/$repo/actions"
