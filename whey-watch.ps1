<#
.SYNOPSIS
    Vigia precos de whey protein em lojas portuguesas e avisa quando ha promocao a serio.

.DESCRIPTION
    Le os alvos de whey-watch.config.json, extrai os precos dos dados estruturados
    (JSON-LD / microdata schema.org) de cada pagina, normaliza para EUR por 100 g de
    proteina real, e compara com o historico que o proprio script vai acumulando.

    Duas decisoes de desenho que interessa conhecer:

    1. O alerta NAO usa a percentagem de desconto anunciada pela loja. Varias mantem
       um "preco de tabela" permanentemente inflacionado - a Zumub esta sempre a -43%.
       O unico sinal fiavel e o preco cair abaixo do minimo ou da mediana que o proprio
       script ja observou.

    2. Quando uma loja publica uma oferta por sabor (a Bulk publica ~20 por formato),
       as ofertas sao colapsadas por gramagem e fica a mais barata QUE ESTEJA EM STOCK.
       Uma promocao num sabor esgotado nao e uma promocao.

.PARAMETER Report
    Imprime a tabela e sai, sem gravar estado nem notificar.

.PARAMETER Discover
    Lista os SKUs em bruto de cada pagina, para preencheres skuGrams no config.

.PARAMETER Only
    Corre so os alvos cujo id contenha este texto. Util para nao martelar as
    restantes lojas enquanto afinas uma.

.PARAMETER Force
    Notifica mesmo sem alteracao (para testar as notificacoes).

.PARAMETER NoNotify
    So consola e log.

.EXAMPLE
    .\whey-watch.ps1 -Report
    .\whey-watch.ps1 -Discover -Only zumub
    .\whey-watch.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'whey-watch.config.json'),
    [string] $StatePath  = (Join-Path $PSScriptRoot 'whey-watch.state.json'),
    [string] $LogPath    = (Join-Path $PSScriptRoot 'whey-watch.log'),
    [string] $Only,
    [switch] $Report,
    [switch] $Discover,
    [switch] $Doctor,
    [switch] $Force,
    [switch] $NoNotify,
    [string] $StatusPath,
    [string] $SummaryPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
} catch { }

# ================================================================= plataforma

function Test-IsWindows {
    # $IsWindows so existe no PowerShell 6+; no 5.1 e sempre Windows
    if ($null -eq $IsWindows) { return $true }
    return [bool] $IsWindows
}

# ================================================================= log

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $LogPath -Value $line -Encoding utf8 } catch { }
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'HIT'   { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor DarkGray }
    }
}

# ================================================================= http

$script:LastHit = @{}

function Get-Page {
    param([string] $Url, [int] $MaxAttempts = 4, [int] $MinGapSec = 6)

    $target = ([Uri] $Url).Host

    # cortesia: nunca dois pedidos seguidos ao mesmo dominio sem intervalo
    if ($script:LastHit.ContainsKey($target)) {
        $elapsed = ((Get-Date) - $script:LastHit[$target]).TotalSeconds
        if ($elapsed -lt $MinGapSec) {
            Start-Sleep -Seconds ([int][Math]::Ceiling($MinGapSec - $elapsed))
        }
    }

    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
          '(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
    $headers = @{
        'Accept'                    = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        'Accept-Language'           = 'pt-PT,pt;q=0.9,en;q=0.8'
        'Upgrade-Insecure-Requests' = '1'
        'Sec-Fetch-Dest'            = 'document'
        'Sec-Fetch-Mode'            = 'navigate'
        'Sec-Fetch-Site'            = 'none'
    }

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $ua `
                                   -Headers $headers -TimeoutSec 45
            $script:LastHit[$target] = Get-Date
            return $r.Content
        }
        catch {
            $script:LastHit[$target] = Get-Date
            $msg = $_.Exception.Message
            if ($i -eq $MaxAttempts) { throw "$MaxAttempts tentativas falharam - $msg" }
            # backoff exponencial com jitter: o Prozis atira 429 com muita facilidade
            $wait = [int]([Math]::Pow(2, $i) * 5) + (Get-Random -Minimum 0 -Maximum 5)
            Write-Log ('   {0} tentativa {1} falhou ({2}) - espero {3}s' -f $target, $i, $msg, $wait) 'WARN'
            Start-Sleep -Seconds $wait
        }
    }
}

# ================================================================= numeros

function ConvertTo-Decimal {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = ([string] $Value).Trim()
    if (-not $s) { return $null }
    # "1.234,56" -> "1234.56"
    if ($s -match '^\d{1,3}(\.\d{3})+,\d{1,2}$') { $s = $s -replace '\.', '' }
    $s = $s -replace ',', '.'
    $s = $s -replace '[^\d\.]', ''
    if (-not $s) { return $null }
    try { return [double]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

function ConvertTo-Grams {
    # aceita "2.5kg", "900 g", ou um QuantitativeValue {value:1, unitText:"kg"}
    param($Value)
    if ($null -eq $Value) { return $null }

    if ($Value -is [string]) {
        $m = [regex]::Match($Value, '(?i)(\d+(?:[.,]\d+)?)\s*(kg|g)\b')
        if (-not $m.Success) { return $null }
        $v = ConvertTo-Decimal $m.Groups[1].Value
        if ($null -eq $v) { return $null }
        if ($m.Groups[2].Value -match '(?i)kg') { return $v * 1000 }
        return $v
    }

    $props = $Value.PSObject.Properties
    if (-not $props) { return $null }
    $names = @($props.Name)
    if ($names -notcontains 'value') { return $null }

    $v = ConvertTo-Decimal $Value.value
    if ($null -eq $v) { return $null }

    $unit = ''
    foreach ($k in @('unitText', 'unitCode')) {
        if ($names -contains $k -and $Value.$k) { $unit = [string] $Value.$k; break }
    }
    if ($unit -match '(?i)^\s*(kg|kgm)\s*$') { return $v * 1000 }
    return $v
}

function Get-Median {
    param($Values)
    $v = @($Values)
    if ($v.Count -eq 0) { return $null }
    $s = @($v | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return [double] $s[[int](($n - 1) / 2)] }
    return ([double] $s[$n / 2 - 1] + [double] $s[$n / 2]) / 2
}

# ================================================================= parser: JSON-LD

function Get-JsonLdNodes {
    param([string] $Html)

    $nodes = @()
    $rx = '(?s)<script[^>]*application/ld\+json[^>]*>(.*?)</script>'
    foreach ($m in [regex]::Matches($Html, $rx)) {
        $raw = $m.Groups[1].Value
        # o Prozis envolve o JSON em comentarios CDATA
        $raw = $raw -replace '/\*\s*<!\[CDATA\[\s*\*/', ''
        $raw = $raw -replace '/\*\s*\]\]>\s*\*/', ''
        $raw = $raw -replace '<!\[CDATA\[', ''
        $raw = $raw -replace '\]\]>', ''
        $raw = $raw.Trim()
        if (-not $raw) { continue }
        try { $nodes += , (ConvertFrom-Json $raw) } catch { }
    }
    return $nodes
}

function Find-OfferNodes {
    # desce a arvore JSON-LD acumulando sku / nome / peso dos nos ascendentes,
    # porque o Offer traz o preco mas o peso vive no Product ou na variante acima
    param($Node, $Ctx, $Acc)

    if ($null -eq $Node) { return }
    if ($Node -is [string] -or $Node -is [ValueType]) { return }

    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { Find-OfferNodes -Node $item -Ctx $Ctx -Acc $Acc }
        return
    }

    $props = $Node.PSObject.Properties
    if (-not $props) { return }
    $names = @($props.Name)

    $ctx2 = @{ Sku = $Ctx.Sku; Name = $Ctx.Name; Grams = $Ctx.Grams }

    foreach ($k in @('sku', 'mpn', 'gtin13', 'gtin')) {
        if ($names -contains $k -and $Node.$k) { $ctx2.Sku = [string] $Node.$k; break }
    }
    if ($names -contains 'name' -and $Node.name) { $ctx2.Name = [string] $Node.name }
    if ($names -contains 'weight' -and $Node.weight) {
        $g = ConvertTo-Grams $Node.weight
        if ($null -ne $g -and $g -gt 0) { $ctx2.Grams = $g }
    }

    if ($names -contains 'price') {
        [void] $Acc.Add([pscustomobject]@{ Node = $Node; Ctx = $ctx2 })
    }
    foreach ($p in $props) { Find-OfferNodes -Node $p.Value -Ctx $ctx2 -Acc $Acc }
}

function Get-OffersFromJsonLd {
    param([string] $Html)

    $acc  = New-Object System.Collections.ArrayList
    $root = @{ Sku = ''; Name = ''; Grams = $null }
    foreach ($n in (Get-JsonLdNodes -Html $Html)) {
        Find-OfferNodes -Node $n -Ctx $root -Acc $acc
    }

    $offers = @()
    foreach ($hit in $acc) {
        $o     = $hit.Node
        $ctx   = $hit.Ctx
        $names = @($o.PSObject.Properties.Name)

        # descartar nos de especificacao (preco por kg, preco de referencia)
        $type = ''
        if ($names -contains '@type') { $type = [string] $o.'@type' }
        if ($type -match 'PriceSpecification') { continue }

        # um Offer a serio traz moeda ou disponibilidade
        if (-not ($names -contains 'priceCurrency' -or $names -contains 'availability')) { continue }

        $price = ConvertTo-Decimal $o.price
        if ($null -eq $price -or $price -le 0) { continue }

        $sku = $ctx.Sku
        foreach ($k in @('sku', 'mpn', 'gtin13', 'gtin')) {
            if ($names -contains $k -and $o.$k) { $sku = [string] $o.$k; break }
        }

        $avail = ''
        if ($names -contains 'availability' -and $o.availability) {
            $avail = (([string] $o.availability) -split '[/#]')[-1]
        }

        $offers += [pscustomobject]@{
            Sku          = $sku
            Name         = $ctx.Name
            Grams        = $ctx.Grams
            Price        = [math]::Round($price, 2)
            ListPrice    = $null
            Availability = $avail
        }
    }
    return $offers
}

# ================================================================= parser: microdata (Zumub)

function Get-OffersFromMicrodata {
    param([string] $Html)

    $offers = @()
    # uma pagina da Zumub traz um bloco schema.org/Product por formato (30g .. 4kg)
    $blocks = [regex]::Split($Html, 'itemtype\s*=\s*"https?://schema\.org/Product"')

    foreach ($b in $blocks) {
        $skuM = [regex]::Match($b, 'itemprop\s*=\s*"sku"[^>]*>\s*([^<\s]+)\s*<')
        if (-not $skuM.Success) {
            $skuM = [regex]::Match($b, 'itemprop\s*=\s*"sku"[^>]*content\s*=\s*"([^"]+)"')
        }
        if (-not $skuM.Success) { continue }

        # o primeiro itemprop=price do bloco e o preco a pagar; o de tabela vem
        # depois, dentro de UnitPriceSpecification
        $curM = [regex]::Match($b, 'itemprop\s*=\s*"price"[^>]*content\s*=\s*"([\d.,]+)"')
        if (-not $curM.Success) { continue }

        $lstM = [regex]::Match($b, '(?s)ListPrice.*?itemprop\s*=\s*"price"[^>]*content\s*=\s*"([\d.,]+)"')

        $avail = ''
        $avM = [regex]::Match($b, 'itemprop\s*=\s*"availability"[^>]*content\s*=\s*"([^"]+)"')
        if (-not $avM.Success) {
            $avM = [regex]::Match($b, 'itemprop\s*=\s*"availability"[^>]*>\s*([^<\s]+)')
        }
        if ($avM.Success) { $avail = ($avM.Groups[1].Value -split '[/#]')[-1] }

        $nameM = [regex]::Match($b, 'itemprop\s*=\s*"name"[^>]*>\s*([^<]{1,120})')
        $name  = ''
        if ($nameM.Success) { $name = $nameM.Groups[1].Value.Trim() }

        $price = ConvertTo-Decimal $curM.Groups[1].Value
        if ($null -eq $price -or $price -le 0) { continue }

        $list = $null
        if ($lstM.Success) { $list = ConvertTo-Decimal $lstM.Groups[1].Value }
        if ($null -ne $list) { $list = [math]::Round($list, 2) }

        $offers += [pscustomobject]@{
            Sku          = $skuM.Groups[1].Value
            Name         = $name
            Grams        = $null
            Price        = [math]::Round($price, 2)
            ListPrice    = $list
            Availability = $avail
        }
    }
    return $offers
}

# ================================================================= normalizacao

function Resolve-Grams {
    param($Offer, $Target)

    $tNames = @($Target.PSObject.Properties.Name)

    # 1. mapa explicito no config
    if ($tNames -contains 'skuGrams' -and $Target.skuGrams) {
        if (@($Target.skuGrams.PSObject.Properties.Name) -contains $Offer.Sku) {
            return [double] $Target.skuGrams.($Offer.Sku)
        }
    }
    # 2. gramagem embutida no sku (Bulk: BPB-WPC8-CHOC-2500)
    if ($tNames -contains 'gramsFromSkuRegex' -and $Target.gramsFromSkuRegex) {
        $m = [regex]::Match([string] $Offer.Sku, $Target.gramsFromSkuRegex)
        if ($m.Success) { return [double] $m.Groups[1].Value }
    }
    # 3. schema.org/weight (MyProtein)
    if ($null -ne $Offer.Grams -and $Offer.Grams -gt 0) { return [double] $Offer.Grams }
    # 4. gramagem no nome da variante
    if ($Offer.Name) {
        $g = ConvertTo-Grams $Offer.Name
        if ($null -ne $g -and $g -ge 25) { return [double] $g }
    }
    return $null
}

function Group-OffersByGrams {
    # colapsa ofertas com a mesma gramagem (a Bulk publica uma por sabor).
    # fica a mais barata EM STOCK; se nenhuma estiver em stock, a mais barata.
    param($Offers)

    $buckets = @{}
    $loose   = @()

    foreach ($o in @($Offers)) {
        if ($null -eq $o.Grams) { $loose += $o; continue }
        $k = 'g{0}' -f [int] $o.Grams
        if (-not $buckets.ContainsKey($k)) { $buckets[$k] = @() }
        $buckets[$k] += $o
    }

    $out = @()
    foreach ($k in $buckets.Keys) {
        $group   = @($buckets[$k])
        $inStock = @($group | Where-Object { Test-InStock $_.Availability })
        if ($inStock.Count -gt 0) { $pool = $inStock } else { $pool = $group }
        $out += ($pool | Sort-Object Price | Select-Object -First 1)
    }

    # as sem gramagem ficam de fora do colapso, mas desduplicadas por sku+preco
    $seen = @{}
    foreach ($o in $loose) {
        $k = '{0}|{1}' -f $o.Sku, $o.Price
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += $o
    }
    return $out
}

function Test-InStock {
    param([string] $Availability)
    if (-not $Availability) { return $true }   # loja que nao declara: assumir disponivel
    return ($Availability -match 'InStock|LimitedAvailability|PreOrder|BackOrder')
}

function Format-Size {
    param([double] $Grams)
    if ($Grams -ge 1000) { return '{0}kg' -f [math]::Round($Grams / 1000, 2) }
    return '{0}g' -f [int] $Grams
}

# ================================================================= estado

function Read-State {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return @{} }
    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return @{} }
        $obj = ConvertFrom-Json $raw
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    catch {
        Write-Log ('estado ilegivel ({0}); comeco de novo' -f $_.Exception.Message) 'WARN'
        return @{}
    }
}

function Write-State {
    param([hashtable] $State, [string] $Path)
    $tmp = $Path + '.tmp'
    ($State | ConvertTo-Json -Depth 8) | Out-File -FilePath $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $Path -Force
}

# ================================================================= notificacoes

function Send-Toast {
    param([string] $Title, [string] $Body)
    if (-not (Test-IsWindows)) { return $false }   # no runner Linux nao existe toast
    try {
        [void] [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void] [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

        $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
                   [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $tpl.GetElementsByTagName('text')
        [void] $texts.Item(0).AppendChild($tpl.CreateTextNode($Title))
        [void] $texts.Item(1).AppendChild($tpl.CreateTextNode($Body))

        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

        $toast = $null
        try   { $toast = [Windows.UI.Notifications.ToastNotification]::new($tpl) }
        catch { $toast = New-Object Windows.UI.Notifications.ToastNotification -ArgumentList $tpl }

        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return $true
    }
    catch {
        Write-Log ('toast falhou: {0}' -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Resolve-Secret {
    # prefere a variavel de ambiente (secret do GitHub Actions) e cai no config
    param($Cfg, [string] $EnvVarField, [string] $LiteralField)
    if (-not $Cfg) { return '' }
    $names = @($Cfg.PSObject.Properties.Name)
    if ($names -contains $EnvVarField -and $Cfg.$EnvVarField) {
        $v = [Environment]::GetEnvironmentVariable([string] $Cfg.$EnvVarField)
        if ($v) { return $v.Trim() }
    }
    if ($names -contains $LiteralField -and $Cfg.$LiteralField) { return ([string] $Cfg.$LiteralField).Trim() }
    return ''
}

function Send-Telegram {
    param($Cfg, [string] $Text)
    if (-not $Cfg) { return }

    $token  = Resolve-Secret -Cfg $Cfg -EnvVarField 'botTokenEnvVar' -LiteralField 'botToken'
    $chatId = Resolve-Secret -Cfg $Cfg -EnvVarField 'chatIdEnvVar'   -LiteralField 'chatId'

    # basta o segredo existir: na nuvem o secret esta definido, localmente nao
    if (-not $token -or -not $chatId) {
        if ($Cfg.enabled) { Write-Log 'telegram: enabled mas sem token/chatId resolvidos' 'WARN' }
        return
    }

    try {
        $uri  = 'https://api.telegram.org/bot{0}/sendMessage' -f $token
        $body = @{ chat_id = $chatId; text = $Text; disable_web_page_preview = $true }
        [void] (Invoke-RestMethod -Uri $uri -Method Post -Body $body -TimeoutSec 30)
        Write-Log '   telegram enviado'
    }
    catch { Write-Log ('telegram falhou: {0}' -f $_.Exception.Message) 'WARN' }
}

function Send-Mail {
    param($Cfg, [string] $Subject, [string] $Body)
    if (-not $Cfg -or -not $Cfg.enabled) { return }
    try {
        $pass = [Environment]::GetEnvironmentVariable($Cfg.passwordEnvVar)
        if (-not $pass) {
            Write-Log ('email: variavel de ambiente {0} vazia' -f $Cfg.passwordEnvVar) 'WARN'
            return
        }
        $sec  = ConvertTo-SecureString $pass -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($Cfg.user, $sec)
        Send-MailMessage -SmtpServer $Cfg.smtpServer -Port $Cfg.port -UseSsl:([bool] $Cfg.useSsl) `
                         -Credential $cred -From $Cfg.from -To ($Cfg.to -split '\s*[;,]\s*') `
                         -Subject $Subject -Body $Body -Encoding UTF8
        Write-Log '   email enviado'
    }
    catch { Write-Log ('email falhou: {0}' -f $_.Exception.Message) 'WARN' }
}

# ================================================================= principal

if (-not (Test-Path $ConfigPath)) { throw "config nao encontrado: $ConfigPath" }

$cfg      = ConvertFrom-Json (Get-Content -Path $ConfigPath -Raw -Encoding UTF8)
$settings = $cfg.settings
$state    = Read-State -Path $StatePath
$now      = Get-Date

$targets = @($cfg.targets)
if ($Only) { $targets = @($targets | Where-Object { $_.id -like "*$Only*" }) }
if ($targets.Count -eq 0) { throw "nenhum alvo corresponde a -Only '$Only'" }

$rows    = @()
$raw     = @()
$alerts  = @()
$health  = @()

# ---------------------------------------------------------------- -Doctor
# um pedido por alvo, sem estado nem alertas: responde a pergunta "este IP
# consegue chegar a estas lojas?". E o que torna a 1a corrida na nuvem util.
if ($Doctor) {
    Write-Log ('--- diagnostico: {0} alvos' -f $targets.Count)
    foreach ($t in $targets) {
        $r = [pscustomobject]@{ Loja = $t.store; Alvo = $t.id; Http = ''; Ofertas = 0; Nota = '' }
        try {
            $html = Get-Page -Url $t.url -MaxAttempts 1 -MinGapSec $settings.minDomainGapSeconds
            $r.Http = '200'
            if ($t.parser -eq 'microdata') { $o = @(Get-OffersFromMicrodata -Html $html) }
            else                           { $o = @(Get-OffersFromJsonLd    -Html $html) }
            $r.Ofertas = $o.Count
            if ($o.Count -eq 0) { $r.Nota = 'pagina veio mas sem precos - parser a rever' }
            else                { $r.Nota = 'ok' }
        }
        catch {
            $m = $_.Exception.Message
            if ($m -match '429')            { $r.Http = '429'; $r.Nota = 'rate-limit: este IP esta a ser travado' }
            elseif ($m -match '403')        { $r.Http = '403'; $r.Nota = 'bloqueado (bot protection ou geo)' }
            elseif ($m -match '(404|410)')  { $r.Http = '404'; $r.Nota = 'url mudou' }
            else                            { $r.Http = 'err'; $r.Nota = $m }
        }
        $health += $r
    }

    Write-Host ''
    $health | Format-Table -AutoSize Loja, Http, Ofertas, Nota
    $okCount = @($health | Where-Object { $_.Http -eq '200' -and $_.Ofertas -gt 0 }).Count
    Write-Log ('--- diagnostico: {0}/{1} lojas alcancaveis deste IP' -f $okCount, $health.Count)

    if ($SummaryPath) {
        $md = @()
        $md += '## whey-watch — diagnostico'
        $md += ''
        $md += ('{0}/{1} lojas alcancaveis deste IP.' -f $okCount, $health.Count)
        $md += ''
        $md += '| Loja | HTTP | Ofertas | Nota |'
        $md += '|---|---|---|---|'
        foreach ($h in $health) { $md += ('| {0} | {1} | {2} | {3} |' -f $h.Loja, $h.Http, $h.Ofertas, $h.Nota) }
        ($md -join [Environment]::NewLine) | Out-File -FilePath $SummaryPath -Encoding utf8 -Append
    }
    return
}

Write-Log ('--- ronda a comecar ({0} alvos)' -f $targets.Count)

foreach ($t in $targets) {

    $tProps = @($t.PSObject.Properties.Name)

    $gap = $settings.minDomainGapSeconds
    if ($tProps -contains 'minGapSeconds' -and $t.minGapSeconds) { $gap = $t.minGapSeconds }

    $attempts = $settings.maxAttempts
    if ($tProps -contains 'maxAttempts' -and $t.maxAttempts) { $attempts = $t.maxAttempts }

    # alguns sites (Prozis) limitam pedidos por IP com agressividade: respeitar
    # um intervalo minimo entre consultas, independente da cadencia do agendador
    $metaKey = 'meta::{0}' -f $t.id
    if ($tProps -contains 'checkEveryHours' -and $t.checkEveryHours -and -not $Force) {
        if ($state.ContainsKey($metaKey) -and $state[$metaKey].lastAttemptAt) {
            $ago = ($now - [datetime] $state[$metaKey].lastAttemptAt).TotalHours
            if ($ago -lt [double] $t.checkEveryHours) {
                Write-Log ('   {0} / {1}: tentado ha {2:N1}h, salto (checkEveryHours={3})' -f `
                            $t.store, $t.name, $ago, $t.checkEveryHours)
                continue
            }
        }
    }

    # a tentativa e marcada ANTES de se saber o resultado. um alvo bloqueado de
    # forma permanente - o Prozis rejeita gamas de datacenter - nao deve ser
    # retentado a cada ronda nem sujar o "N/M lojas responderam" para sempre
    $state[$metaKey] = @{ lastAttemptAt = $now.ToString('s') }

    try {
        $html = Get-Page -Url $t.url -MaxAttempts $attempts -MinGapSec $gap
    }
    catch {
        Write-Log ('{0} / {1}: {2}' -f $t.store, $t.name, $_.Exception.Message) 'ERROR'
        $health += [pscustomobject]@{ Loja = $t.store; Alvo = $t.id; Estado = 'falhou'; Nota = $_.Exception.Message }
        continue
    }

    if ($t.parser -eq 'microdata') { $offers = Get-OffersFromMicrodata -Html $html }
    else                           { $offers = Get-OffersFromJsonLd    -Html $html }

    $offers = @($offers)
    if ($offers.Count -eq 0) {
        Write-Log ('{0} / {1}: nenhum preco extraido - o site pode ter mudado de estrutura' -f $t.store, $t.name) 'WARN'
        $health += [pscustomobject]@{ Loja = $t.store; Alvo = $t.id; Estado = 'sem precos'; Nota = 'parser a rever' }
        continue
    }

    $health += [pscustomobject]@{ Loja = $t.store; Alvo = $t.id; Estado = 'ok'; Nota = ('{0} ofertas' -f $offers.Count) }

    $state[$metaKey] = @{ lastAttemptAt = $now.ToString('s'); lastOkAt = $now.ToString('s') }

    # resolver gramagem antes de colapsar
    foreach ($o in $offers) {
        $o.Grams = Resolve-Grams -Offer $o -Target $t
        $raw += [pscustomobject]@{
            Loja = $t.store; Sku = $o.Sku; Preco = $o.Price
            Gramas = $o.Grams; Stock = $o.Availability; Nome = $o.Name
        }
    }

    $collapsed = @(Group-OffersByGrams -Offers $offers)

    # ultimo recurso: pagina de formato unico com defaultGrams no config
    if ($collapsed.Count -eq 1 -and $null -eq $collapsed[0].Grams) {
        if (@($t.PSObject.Properties.Name) -contains 'defaultGrams' -and $t.defaultGrams) {
            $collapsed[0].Grams = [double] $t.defaultGrams
        }
    }

    if ($offers.Count -ne $collapsed.Count) {
        Write-Log ('   {0}: {1} ofertas colapsadas em {2} formatos' -f $t.store, $offers.Count, $collapsed.Count)
    }

    foreach ($o in $collapsed) {

        $grams = $o.Grams

        # EUR por 100 g de proteina real
        $perProt = $null
        if ($grams -and $t.proteinPer100g) {
            $gProt = $grams * ([double] $t.proteinPer100g) / 100.0
            if ($gProt -gt 0) { $perProt = [math]::Round($o.Price / $gProt * 100.0, 2) }
        }

        if ($grams) {
            $label = '{0} ({1})' -f $t.name, (Format-Size -Grams $grams)
            $key   = '{0}::g{1}' -f $t.id, [int] $grams
        }
        else {
            $label = '{0} [sku {1}]' -f $t.name, $o.Sku
            $key   = '{0}::s{1}' -f $t.id, $o.Sku
        }

        # ---- historico
        $prev = $null
        if ($state.ContainsKey($key)) { $prev = $state[$key] }

        $hist = @()
        if ($prev -and $prev.history) { $hist = @($prev.history) }

        $prices = @()
        foreach ($h in $hist) { $prices += [double] $h.p }

        $min = $null
        if ($prices.Count -gt 0) { $min = ($prices | Measure-Object -Minimum).Minimum }
        $median = Get-Median -Values $prices

        $prevAvail = ''
        if ($hist.Count -gt 0) { $prevAvail = [string] $hist[-1].a }

        # ---- decidir se ha alerta
        $reasons = @()
        $al      = $t.alert
        $inStock = Test-InStock $o.Availability

        if ($al.onNewLow -and $null -ne $min -and $hist.Count -ge 2 -and
            $o.Price -lt ($min - 0.01) -and $inStock) {
            $reasons += ('minimo historico (antes {0:N2} EUR)' -f $min)
        }
        if ($al.maxEurPer100gProtein -and $null -ne $perProt -and
            $perProt -le [double] $al.maxEurPer100gProtein -and $inStock) {
            $reasons += ('{0:N2} EUR/100g proteina, dentro do teu limite de {1:N2}' -f $perProt, [double] $al.maxEurPer100gProtein)
        }
        if ($al.dropPctVsMedian -and $null -ne $median -and $median -gt 0 -and
            $hist.Count -ge 4 -and $inStock) {
            $threshold = $median * (1 - ([double] $al.dropPctVsMedian / 100.0))
            if ($o.Price -le $threshold) {
                $reasons += ('{0:N0}% abaixo da mediana ({1:N2} EUR)' -f ((1 - $o.Price / $median) * 100), $median)
            }
        }
        if ($al.onBackInStock -and $prevAvail -match 'OutOfStock|SoldOut|Discontinued' -and $inStock) {
            $reasons += 'voltou a stock'
        }

        # ---- cooldown: nao repetir o mesmo alerta ao mesmo preco
        $suppressed = $false
        if ($reasons.Count -gt 0 -and $prev -and $prev.lastAlertAt) {
            $since     = ($now - [datetime] $prev.lastAlertAt).TotalHours
            $samePrice = ($null -ne $prev.lastAlertPrice -and
                          [math]::Abs([double] $prev.lastAlertPrice - $o.Price) -lt 0.01)
            if ($samePrice -and $since -lt [double] $settings.alertCooldownHours) { $suppressed = $true }
        }

        $fire = (($reasons.Count -gt 0) -and (-not $suppressed))

        $medianOut = $null
        if ($null -ne $median) { $medianOut = [math]::Round($median, 2) }
        $stockOut = '?'
        if ($o.Availability) { $stockOut = $o.Availability }
        $alertaOut = ''
        if ($fire) { $alertaOut = ($reasons -join ' | ') }

        $rows += [pscustomobject]@{
            Key            = $key
            Loja           = $t.store
            Produto        = $label
            Sku            = $o.Sku
            Preco          = $o.Price
            Tabela         = $o.ListPrice
            EurPor100gProt = $perProt
            Stock          = $stockOut
            MinVisto       = $min
            Mediana        = $medianOut
            Obs            = $hist.Count
            Alerta         = $alertaOut
            Url            = $t.url
        }

        if ($fire -or $Force) {
            $head = ''
            if ($null -ne $perProt) { $head = '{0:N2} EUR/100g proteina. ' -f $perProt }
            $why = 'verificacao forcada'
            if ($reasons.Count -gt 0) { $why = ($reasons -join '; ') }

            $alerts += [pscustomobject]@{
                Titulo  = '{0} - {1:N2} EUR' -f $label, $o.Price
                Corpo   = '{0}{1}. {2}' -f $head, $why, $t.store
                Url     = $t.url
                PerProt = $perProt
                Preco   = $o.Price
                Label   = $label
            }
        }

        # ---- gravar
        $hist += , ([pscustomobject]@{ t = $now.ToString('s'); p = $o.Price; a = $o.Availability })
        $keep = [int] $settings.historyKeep
        if ($hist.Count -gt $keep) { $hist = $hist[($hist.Count - $keep)..($hist.Count - 1)] }

        $entry = @{
            label   = $label
            store   = $t.store
            url     = $t.url
            history = $hist
        }
        if ($fire) {
            $entry.lastAlertAt    = $now.ToString('s')
            $entry.lastAlertPrice = $o.Price
        }
        elseif ($prev) {
            if ($prev.lastAlertAt)              { $entry.lastAlertAt    = $prev.lastAlertAt }
            if ($null -ne $prev.lastAlertPrice) { $entry.lastAlertPrice = $prev.lastAlertPrice }
        }
        $state[$key] = $entry
    }
}

# ================================================================= saida

if ($Discover) {
    Write-Host ''
    Write-Host 'SKUs em bruto - usa-os para preencher skuGrams no config:' -ForegroundColor Cyan
    $raw | Sort-Object Loja, Preco | Format-Table Loja, Sku, Preco, Gramas, Stock, Nome -AutoSize
    return
}

Write-Host ''
$rows |
    Sort-Object @{ Expression = { if ($null -eq $_.EurPor100gProt) { 9999 } else { $_.EurPor100gProt } } } |
    Format-Table -AutoSize `
        Loja,
        Produto,
        @{ Label = 'Preco';     Expression = { '{0,8:N2}' -f $_.Preco } },
        @{ Label = 'EUR/100gP'; Expression = { if ($null -eq $_.EurPor100gProt) { '     -' } else { '{0,6:N2}' -f $_.EurPor100gProt } } },
        Stock,
        @{ Label = 'MinVisto';  Expression = { if ($null -eq $_.MinVisto) { '-' } else { '{0:N2}' -f $_.MinVisto } } },
        Obs,
        Alerta

if ($Report) {
    Write-Log '--- modo -Report: estado nao gravado'
    return
}

Write-State -State $state -Path $StatePath

$sorted = @($rows | Sort-Object @{ Expression = { if ($null -eq $_.EurPor100gProt) { 9999 } else { $_.EurPor100gProt } } })

# ---- status.json: e o que a pagina publicada le
if ($StatusPath) {
    $status = [ordered]@{
        generatedAt = $now.ToString('o')
        rows        = $sorted
        health      = @($health)
        alerts      = @($alerts)
    }
    $dir = Split-Path -Parent $StatusPath
    if ($dir -and -not (Test-Path $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
    ($status | ConvertTo-Json -Depth 8) | Out-File -FilePath $StatusPath -Encoding utf8
    Write-Log ('   status escrito em {0}' -f $StatusPath)
}

# ---- resumo do job (GITHUB_STEP_SUMMARY)
if ($SummaryPath) {
    $okCount = @($health | Where-Object { $_.Estado -eq 'ok' }).Count
    $md  = @()
    $md += '## whey-watch'
    $md += ''
    $md += ('{0}/{1} lojas responderam. {2} preco(s) verificado(s). {3} alerta(s).' -f `
             $okCount, $health.Count, $rows.Count, $alerts.Count)
    $md += ''
    if ($alerts.Count -gt 0) {
        $md += '### Promocoes'
        $md += ''
        foreach ($a in $alerts) { $md += ('- **{0}** — {1}' -f $a.Titulo, $a.Corpo) }
        $md += ''
    }
    $md += '| Loja | Produto | Preco | EUR/100g prot. | Stock | Min visto | Obs |'
    $md += '|---|---|---:|---:|---|---:|---:|'
    foreach ($r in $sorted) {
        $pp = '-'
        if ($null -ne $r.EurPor100gProt) { $pp = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N2}', $r.EurPor100gProt) }
        $mv = '-'
        if ($null -ne $r.MinVisto) { $mv = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N2}', $r.MinVisto) }
        $pr = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N2}', $r.Preco)
        $md += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $r.Loja, $r.Produto, $pr, $pp, $r.Stock, $mv, $r.Obs)
    }
    $md += ''
    $falhas = @($health | Where-Object { $_.Estado -ne 'ok' })
    if ($falhas.Count -gt 0) {
        $md += '### Lojas que nao responderam'
        $md += ''
        foreach ($h in $falhas) { $md += ('- **{0}** ({1}): {2}' -f $h.Loja, $h.Estado, $h.Nota) }
    }
    ($md -join [Environment]::NewLine) | Out-File -FilePath $SummaryPath -Encoding utf8 -Append
}

if ($alerts.Count -eq 0) {
    Write-Log ('--- ronda concluida, nada a assinalar ({0} precos verificados)' -f $rows.Count)
    return
}

foreach ($a in $alerts) { Write-Log ('PROMOCAO: {0} - {1}' -f $a.Titulo, $a.Corpo) 'HIT' }

if ($NoNotify) { return }

$n = $settings.notify

if ($n.toast -and (Test-IsWindows)) {
    foreach ($a in $alerts) { [void] (Send-Toast -Title $a.Titulo -Body $a.Corpo) }
}

$nl     = [Environment]::NewLine
$linhas = @()
foreach ($a in $alerts) {
    $pp = ''
    if ($null -ne $a.PerProt) { $pp = ' - {0:N2} EUR/100g prot.' -f $a.PerProt }
    $linhas += ('{0} - {1:N2} EUR{2}{3}{4}' -f $a.Label, $a.Preco, $pp, $nl, $a.Url)
}
$texto = 'Promocao de whey detectada:' + $nl + $nl + ($linhas -join ($nl + $nl))

Send-Telegram -Cfg $n.telegram -Text $texto
Send-Mail -Cfg $n.email -Subject ('whey-watch: {0} promocao(oes)' -f $alerts.Count) -Body $texto
