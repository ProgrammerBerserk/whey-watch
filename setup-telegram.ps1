<#
.SYNOPSIS
    Descobre o chat_id do teu grupo de Telegram e grava os dois secrets no GitHub.

.DESCRIPTION
    Corre isto TU, no teu terminal. O token e pedido de forma oculta e nunca e
    escrito em ficheiro nem passado na linha de comandos - vai para o gh por
    stdin, para nao ficar no historico da shell nem visivel na lista de processos.

    Antes de correr:
      1. Cria o bot com o @BotFather (/newbot) e guarda o token
      2. Adiciona o bot ao grupo
      3. No grupo, escreve uma mensagem que COMECE POR "/" (ex.: /ola)

    O passo 3 nao e capricho: os bots do Telegram tem privacy mode ligado por
    omissao e nao recebem mensagens normais de grupo. Sem uma mensagem com "/"
    (ou a entrada do bot no grupo), o getUpdates devolve lista vazia.

.PARAMETER Repo
    owner/nome do repositorio. Por omissao le o remote "origin" deste repo.

.PARAMETER NoSecrets
    So descobre e mostra o chat_id, sem gravar nada no GitHub.

.EXAMPLE
    .\setup-telegram.ps1
    .\setup-telegram.ps1 -NoSecrets
#>
[CmdletBinding()]
param(
    [string] $Repo,
    [switch] $NoSecrets
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Find-Gh {
    $c = Get-Command gh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\GitHub CLI\gh.exe", "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------- repo

if (-not $Repo) {
    try {
        $url = (git -C $PSScriptRoot remote get-url origin 2>$null)
        if ($url -match 'github\.com[:/]([^/]+)/(.+?)(\.git)?$') {
            $Repo = '{0}/{1}' -f $Matches[1], $Matches[2]
        }
    } catch { }
}

# ---------------------------------------------------------------- token

Write-Host ''
Write-Host 'Token do bot (do @BotFather). Nao aparece no ecra.' -ForegroundColor Cyan
$sec = Read-Host -Prompt 'Token' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try   { $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

if (-not $token -or $token -notmatch '^\d+:[\w-]{20,}$') {
    Write-Host 'Isso nao parece um token do Telegram (formato: 123456789:AAff...).' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- validar o bot

try {
    $me = Invoke-RestMethod -Uri ('https://api.telegram.org/bot{0}/getMe' -f $token) -TimeoutSec 30
}
catch {
    Write-Host ('O Telegram rejeitou o token: {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
Write-Host ('Bot: @{0} ({1})' -f $me.result.username, $me.result.first_name) -ForegroundColor Green

# ---------------------------------------------------------------- descobrir chats

$upd = Invoke-RestMethod -Uri ('https://api.telegram.org/bot{0}/getUpdates?limit=100' -f $token) -TimeoutSec 30

$chats = @{}
foreach ($u in @($upd.result)) {
    foreach ($holder in @($u.message, $u.edited_message, $u.channel_post, $u.my_chat_member)) {
        if ($holder -and $holder.chat) {
            $ch = $holder.chat
            $name = $ch.title
            if (-not $name) { $name = (('{0} {1}' -f $ch.first_name, $ch.last_name)).Trim() }
            if (-not $name) { $name = $ch.username }
            $chats[[string] $ch.id] = [pscustomobject]@{ Id = $ch.id; Tipo = $ch.type; Nome = $name }
        }
    }
}

if ($chats.Count -eq 0) {
    Write-Host ''
    Write-Host 'Nenhuma conversa encontrada. Quase sempre e uma destas tres:' -ForegroundColor Yellow
    Write-Host '  1. o bot ainda nao esta no grupo'
    Write-Host '  2. nao escreveste no grupo uma mensagem a comecar por "/" (privacy mode)'
    Write-Host '  3. ha um webhook activo a consumir os updates - ve:'
    Write-Host ('     https://api.telegram.org/bot<TOKEN>/getWebhookInfo')
    Write-Host ''
    Write-Host 'Escreve "/ola" no grupo e corre isto outra vez.' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host 'Conversas encontradas:' -ForegroundColor Cyan
$list = @($chats.Values | Sort-Object { $_.Tipo -ne 'group' -and $_.Tipo -ne 'supergroup' })
for ($i = 0; $i -lt $list.Count; $i++) {
    Write-Host ('  [{0}] {1,-14} {2,-16} {3}' -f $i, $list[$i].Tipo, $list[$i].Id, $list[$i].Nome)
}

$pick = 0
if ($list.Count -gt 1) {
    Write-Host ''
    $ans = Read-Host -Prompt ('Qual? [0-{0}]' -f ($list.Count - 1))
    if ($ans -match '^\d+$' -and [int] $ans -lt $list.Count) { $pick = [int] $ans }
}
$chat = $list[$pick]

if ($chat.Tipo -notin @('group', 'supergroup')) {
    Write-Host ''
    Write-Host ('Atencao: escolheste um chat do tipo "{0}", nao um grupo. Os alertas' -f $chat.Tipo) -ForegroundColor Yellow
    Write-Host 'irao so para ti, e a ideia era a outra pessoa recebe-los tambem.'   -ForegroundColor Yellow
}

Write-Host ''
Write-Host ('Escolhido: {0}  (chat_id {1})' -f $chat.Nome, $chat.Id) -ForegroundColor Green

# ---------------------------------------------------------------- mensagem de teste

# com -NoSecrets so queres descobrir o chat_id; nao ha nada a validar e uma
# segunda mensagem de teste no grupo e so ruido
if ($NoSecrets) {
    Write-Host ''
    Write-Host ('chat_id = {0}' -f $chat.Id) -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Usa-o em ALLOWED_CHAT_IDS no bot/wrangler.toml.' -ForegroundColor DarkGray
    exit 0
}

$txt = 'whey-watch ligado. E aqui que vao aparecer as promocoes.'
try {
    [void] (Invoke-RestMethod -Uri ('https://api.telegram.org/bot{0}/sendMessage' -f $token) `
              -Method Post -TimeoutSec 30 `
              -Body @{ chat_id = $chat.Id; text = $txt; disable_web_page_preview = $true })
    Write-Host 'Mensagem de teste enviada - confirma que apareceu no grupo.' -ForegroundColor Green
}
catch {
    Write-Host ('Nao consegui enviar para o grupo: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Se o bot foi removido ou nao tem permissao de escrita, corrige e repete.' -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- secrets

$gh = Find-Gh
if (-not $gh) {
    Write-Host ''
    Write-Host 'gh nao encontrado. Corre com -NoSecrets e grava os secrets a mao.' -ForegroundColor Yellow
    exit 1
}
if (-not $Repo) {
    Write-Host ''
    Write-Host 'Nao consegui deduzir o repositorio. Repete com -Repo owner/nome.' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host ('A gravar os secrets em {0}...' -f $Repo) -ForegroundColor Cyan

# por stdin: nao fica no historico da shell nem visivel na lista de processos
$token       | & $gh secret set TELEGRAM_BOT_TOKEN --repo $Repo
[string] $chat.Id | & $gh secret set TELEGRAM_CHAT_ID  --repo $Repo

Write-Host ''
Write-Host 'Feito. Os secrets estao gravados e o Telegram fica activo na proxima ronda.' -ForegroundColor Green
Write-Host 'Para nao esperar pelo cron:' -ForegroundColor DarkGray
Write-Host ('  gh workflow run whey-watch.yml --repo {0}' -f $Repo)
