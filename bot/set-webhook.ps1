<#
.SYNOPSIS
    Aponta o bot do Telegram ao Cloudflare Worker e registra o menu de comandos.

.DESCRIPTION
    Corre isto depois do "wrangler deploy". Gera um segredo aleatorio para o
    header X-Telegram-Bot-Api-Secret-Token, chama o setWebhook com ele, e
    registra a lista de comandos para aparecerem no menu do Telegram.

    O segredo e mostrado no fim para o gravares no Worker:
      wrangler secret put TELEGRAM_WEBHOOK_SECRET

    Sem esse segredo dos dois lados, o Worker devolve 403 a tudo - de proposito:
    e o que impede alguem de fingir ser o Telegram e disparar rondas.

.PARAMETER WorkerUrl
    O URL do Worker, ex.: https://whey-watch-bot.o-teu-subdominio.workers.dev

.PARAMETER Info
    Mostra o estado actual do webhook e sai.

.PARAMETER Delete
    Remove o webhook (o bot volta a nao receber nada) e sai.

.EXAMPLE
    .\set-webhook.ps1 -WorkerUrl https://whey-watch-bot.abc.workers.dev
    .\set-webhook.ps1 -Info
    .\set-webhook.ps1 -Delete
#>
[CmdletBinding()]
param(
    [string] $WorkerUrl,
    [switch] $Info,
    [switch] $Delete
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Write-Host ''
Write-Host 'Token do bot (do @BotFather). Nao aparece no ecra.' -ForegroundColor Cyan
$sec  = Read-Host -Prompt 'Token' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try   { $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

if (-not $token -or $token -notmatch '^\d+:[\w-]{20,}$') {
    Write-Host 'Isso nao parece um token do Telegram.' -ForegroundColor Red
    exit 1
}

$api = 'https://api.telegram.org/bot{0}/{1}'

# ---------------------------------------------------------------- -Info

if ($Info) {
    $r = Invoke-RestMethod -Uri ($api -f $token, 'getWebhookInfo') -TimeoutSec 30
    $i = $r.result
    Write-Host ''
    Write-Host ('url                : {0}' -f $(if ($i.url) { $i.url } else { '(nenhum)' }))
    Write-Host ('certificado proprio: {0}' -f $i.has_custom_certificate)
    Write-Host ('updates pendentes  : {0}' -f $i.pending_update_count)
    if ($i.max_connections)  { Write-Host ('ligacoes maximas   : {0}' -f $i.max_connections) }
    if ($i.allowed_updates)  { Write-Host ('updates permitidos : {0}' -f ($i.allowed_updates -join ', ')) }

    if ($i.last_error_message) {
        $when = ([DateTimeOffset]::FromUnixTimeSeconds([int64] $i.last_error_date)).LocalDateTime
        Write-Host ''
        Write-Host ('ultima falha de entrega: {0}' -f $i.last_error_message) -ForegroundColor Yellow
        Write-Host ('                        {0:dd/MM HH:mm}' -f $when) -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Um 403 aqui significa que o segredo difere entre o Telegram e o Worker.' -ForegroundColor DarkGray
    }
    else {
        Write-Host ''
        Write-Host 'Sem falhas de entrega registadas.' -ForegroundColor Green
    }

    # o Telegram nao expoe se o secret_token esta definido, de proposito. a unica
    # forma de o saber e pela ausencia de 403 nas entregas, acima
    Write-Host ''
    Write-Host 'Nota: o Telegram nao revela o secret_token, portanto nao aparece aqui.' -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------- -Delete

if ($Delete) {
    [void] (Invoke-RestMethod -Uri ($api -f $token, 'deleteWebhook') -Method Post `
              -Body @{ drop_pending_updates = 'false' } -TimeoutSec 30)
    Write-Host 'Webhook removido. O bot deixa de receber mensagens.' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------- setWebhook

if (-not $WorkerUrl) {
    Write-Host 'Falta -WorkerUrl (o endereco que o wrangler deploy imprimiu).' -ForegroundColor Red
    exit 1
}
if ($WorkerUrl -notmatch '^https://') {
    Write-Host 'O Telegram so aceita webhooks em HTTPS.' -ForegroundColor Red
    exit 1
}
$WorkerUrl = $WorkerUrl.TrimEnd('/')

# confirmar que o Worker esta de pe antes de apontar o Telegram para ele
try {
    $ping = Invoke-WebRequest -Uri $WorkerUrl -UseBasicParsing -TimeoutSec 20
    Write-Host ('Worker responde: {0}' -f $ping.Content.Trim()) -ForegroundColor Green
}
catch {
    Write-Host ('Aviso: o Worker nao respondeu ({0}). Continuo, mas confirma o deploy.' -f $_.Exception.Message) -ForegroundColor Yellow
}

# segredo aleatorio, 32 bytes em base64url (o Telegram aceita A-Z a-z 0-9 _ -)
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$whSecret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')

$body = @{
    url                  = $WorkerUrl
    secret_token         = $whSecret
    max_connections      = 10
    drop_pending_updates = 'true'
    allowed_updates      = '["message"]'
}
[void] (Invoke-RestMethod -Uri ($api -f $token, 'setWebhook') -Method Post -Body $body -TimeoutSec 30)
Write-Host 'Webhook apontado ao Worker.' -ForegroundColor Green

# ---------------------------------------------------------------- menu

$cmds = @(
    @{ command = 'best';   description = 'Melhor valor em stock agora' }
    @{ command = 'shop';   description = 'Lojas e produtos vigiados' }
    @{ command = 'status'; description = 'Ultima ronda e saude do sistema' }
    @{ command = 'update'; description = 'Forcar uma consulta de precos' }
)
[void] (Invoke-RestMethod -Uri ($api -f $token, 'setMyCommands') -Method Post `
          -ContentType 'application/json' `
          -Body (@{ commands = $cmds } | ConvertTo-Json -Depth 4) -TimeoutSec 30)
Write-Host 'Menu de comandos registado.' -ForegroundColor Green

# ---------------------------------------------------------------- fim

Write-Host ''
Write-Host 'Falta gravar este segredo no Worker:' -ForegroundColor Cyan
Write-Host ''
Write-Host ('  ' + $whSecret) -ForegroundColor White
Write-Host ''
Write-Host 'Corre, e cola-o quando pedir:' -ForegroundColor DarkGray
Write-Host '  wrangler secret put TELEGRAM_WEBHOOK_SECRET'
Write-Host ''
Write-Host 'Enquanto o Worker nao tiver este segredo, devolve 403 a tudo.' -ForegroundColor Yellow
