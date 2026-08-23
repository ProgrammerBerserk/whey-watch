<#
.SYNOPSIS
    Valida um PAT do GitHub contra as chamadas que o bot faz, e grava-o no Worker.

.DESCRIPTION
    Um 401 vindo do Worker nao diz qual dos problemas e: token errado, expirado,
    ou com o valor trocado. Este script testa cada chamada que o bot precisa
    ANTES de o token ir para producao, e diz exactamente o que falta.

    O token e pedido de forma oculta e entregue ao wrangler por stdin: nao fica
    no historico da shell, nem em ficheiro, nem visivel na lista de processos.

    O PAT deve ser fine-grained, limitado ao repositorio, com:
      Actions  - read and write   (para o /update disparar o workflow)
      Contents - read             (para ler o config e o docs/status.json)

.PARAMETER Owner
    Dono do repositorio. Por omissao le-o do wrangler.toml.

.PARAMETER Repo
    Nome do repositorio. Por omissao le-o do wrangler.toml.

.PARAMETER CheckOnly
    So testa; nao grava nada no Worker.

.EXAMPLE
    .\set-gh-token.ps1
    .\set-gh-token.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [string] $Owner,
    [string] $Repo,
    [string] $Workflow,
    [switch] $CheckOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$base = $PSScriptRoot
if (-not $base) { $base = (Get-Location).Path }

# ---------------------------------------------------------------- ler o wrangler.toml

$toml = Join-Path $base 'wrangler.toml'
if (Test-Path $toml) {
    $t = Get-Content $toml -Raw
    if (-not $Owner)    { $m = [regex]::Match($t, 'GH_OWNER\s*=\s*"([^"]+)"');    if ($m.Success) { $Owner    = $m.Groups[1].Value } }
    if (-not $Repo)     { $m = [regex]::Match($t, 'GH_REPO\s*=\s*"([^"]+)"');     if ($m.Success) { $Repo     = $m.Groups[1].Value } }
    if (-not $Workflow) { $m = [regex]::Match($t, 'GH_WORKFLOW\s*=\s*"([^"]+)"'); if ($m.Success) { $Workflow = $m.Groups[1].Value } }
}
if (-not $Owner -or -not $Repo) {
    Write-Host 'Nao consegui deduzir o repositorio. Passa -Owner e -Repo.' -ForegroundColor Red
    exit 1
}
if (-not $Workflow) { $Workflow = 'whey-watch.yml' }

Write-Host ''
Write-Host ('Repositorio: {0}/{1}   workflow: {2}' -f $Owner, $Repo, $Workflow) -ForegroundColor DarkGray

# ---------------------------------------------------------------- token

Write-Host ''
Write-Host 'PAT do GitHub. Nao aparece no ecra.' -ForegroundColor Cyan
$sec  = Read-Host -Prompt 'Token' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try   { $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$token = ($token -replace '\s', '')   # espacos colados por acidente dao 401
if (-not $token) { Write-Host 'Token vazio.' -ForegroundColor Red; exit 1 }

# aviso cedo: se nao parece um token do GitHub, provavelmente e o valor errado
if ($token -notmatch '^(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})$') {
    Write-Host ''
    Write-Host 'Aviso: isto nao tem o formato de um PAT do GitHub.' -ForegroundColor Yellow
    Write-Host 'Os fine-grained comecam por "github_pat_"; os classicos por "ghp_".' -ForegroundColor Yellow
    Write-Host 'Se colaste por engano o segredo do webhook ou o token do Telegram, para aqui.' -ForegroundColor Yellow
    Write-Host ''
    $go = Read-Host -Prompt 'Continuar mesmo assim? (s/N)'
    if ($go -notmatch '^[sSyY]') { exit 1 }
}

$hdr = @{
    'Accept'               = 'application/vnd.github+json'
    'Authorization'        = "Bearer $token"
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'whey-watch-bot-setup'
}

$fails = 0
function Try-Call {
    param([string] $Label, [string] $Url, [string] $Hint)
    try {
        $r = Invoke-RestMethod -Uri $Url -Headers $hdr -TimeoutSec 30
        Write-Host ('  OK    {0}' -f $Label) -ForegroundColor Green
        return $r
    }
    catch {
        $script:fails++
        $st = ''
        if ($_.Exception.Response) { $st = [int] $_.Exception.Response.StatusCode }
        Write-Host ('  FALHA {0}  (HTTP {1})' -f $Label, $st) -ForegroundColor Red
        if ($st -eq 401) { Write-Host '        401 = credencial invalida: o token esta errado ou expirado' -ForegroundColor DarkGray }
        elseif ($st -eq 403) { Write-Host '        403 = token valido mas sem esta permissao' -ForegroundColor DarkGray }
        elseif ($st -eq 404) { Write-Host '        404 = sem acesso a este recurso (ou o repo nao esta no scope do token)' -ForegroundColor DarkGray }
        if ($Hint) { Write-Host ('        {0}' -f $Hint) -ForegroundColor DarkGray }
        return $null
    }
}

Write-Host ''
Write-Host 'A testar as chamadas que o bot faz:' -ForegroundColor Cyan

$me = Try-Call 'identidade (GET /user)' 'https://api.github.com/user' `
        'Se isto falha com 401, o token esta invalido e nada mais vale a pena.'
if ($me) { Write-Host ('        autenticado como {0}' -f $me.login) -ForegroundColor DarkGray }

$api = "https://api.github.com/repos/$Owner/$Repo"

[void] (Try-Call 'Contents: read - config' "$api/contents/whey-watch.config.json?ref=main" `
          'Precisa de Contents: read. Usado pelo /shop.')
[void] (Try-Call 'Contents: read - status' "$api/contents/docs/status.json?ref=main" `
          'Precisa de Contents: read. Usado pelo /best e pelo /status.')
[void] (Try-Call 'Actions: read - execucoes' "$api/actions/workflows/$Workflow/runs?per_page=1" `
          'Precisa de Actions: read. Usado pelo /status e pela guarda do /update.')

Write-Host ''
if ($fails -gt 0) {
    Write-Host ('{0} chamada(s) a falhar. Corrige o token antes de o gravar.' -f $fails) -ForegroundColor Red
    Write-Host ''
    Write-Host 'Cria um novo em:' -ForegroundColor DarkGray
    Write-Host '  https://github.com/settings/personal-access-tokens/new'
    Write-Host ('  Repository access: only select repositories -> {0}/{1}' -f $Owner, $Repo)
    Write-Host '  Permissions: Actions = Read and write, Contents = Read-only'
    exit 1
}

Write-Host 'Todas as leituras passaram.' -ForegroundColor Green
Write-Host ''
Write-Host 'Nao testei o disparo do workflow de proposito: isso gastaria uma ronda.' -ForegroundColor DarkGray
Write-Host 'Se o Actions estiver so em Read, o /update falha com 403 - ve-se no primeiro uso.' -ForegroundColor DarkGray

if ($CheckOnly) { exit 0 }

# ---------------------------------------------------------------- gravar

$wr = Get-Command wrangler -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'A gravar no Worker...' -ForegroundColor Cyan
Push-Location $base
try {
    if ($wr) { $token | & wrangler secret put GH_TOKEN }
    else     { $token | & npx --yes wrangler secret put GH_TOKEN }
}
finally { Pop-Location }

Write-Host ''
Write-Host 'Feito. Testa no grupo com /best.' -ForegroundColor Green
