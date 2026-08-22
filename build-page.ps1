<#
.SYNOPSIS
    Gera a pagina HTML partilhavel a partir do status.json e do state.json.

.DESCRIPTION
    Pagina auto-contida, sem dependencias externas, pensada para telefone
    primeiro. A tabela e o produto: barra de magnitude embutida na coluna do
    EUR/100 g de proteina e sparkline do historico por linha.

    Uma nota sobre cor: o stock NAO e codificado por matiz. Um verde
    "em stock" ao lado de um laranja "esgotado" da uma separacao de apenas
    5,6 de delta-E em protanopia - indistinguiveis para quem tem daltonismo
    vermelho-verde. Esgotado fica em tinta apagada com a palavra escrita e o
    preco riscado; a unica cor de status na pagina e o selo de promocao.

.EXAMPLE
    .\build-page.ps1
    .\build-page.ps1 -OutPath docs\index.html
#>
[CmdletBinding()]
param(
    [string] $StatusPath = (Join-Path $PSScriptRoot 'docs/status.json'),
    [string] $StatePath  = (Join-Path $PSScriptRoot 'whey-watch.state.json'),
    [string] $OutPath    = (Join-Path $PSScriptRoot 'docs/index.html')
)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path $StatusPath)) { throw "status.json nao encontrado em $StatusPath - corre primeiro o whey-watch.ps1 -StatusPath" }

$status = ConvertFrom-Json (Get-Content -Path $StatusPath -Raw -Encoding UTF8)
$rows   = @($status.rows)

$hist = @{}
if (Test-Path $StatePath) {
    $st = ConvertFrom-Json (Get-Content -Path $StatePath -Raw -Encoding UTF8)
    foreach ($p in $st.PSObject.Properties) {
        if ($p.Name -like 'meta::*') { continue }
        $hist[$p.Name] = @($p.Value.history)
    }
}

function HtmlEncode {
    param([string] $S)
    if ($null -eq $S) { return '' }
    return ($S -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Fmt {
    param($V, [int] $Dec = 2)
    if ($null -eq $V) { return '&mdash;' }
    return [string]::Format($inv, ('{0:N' + $Dec + '}'), [double] $V) -replace '\.', ','
}

function Test-InStockRow {
    param($Row)
    $a = [string] $Row.Stock
    if (-not $a -or $a -eq '?') { return $true }
    return ($a -match 'InStock|LimitedAvailability|PreOrder|BackOrder')
}

# ---------------------------------------------------------------- sparkline

function New-Sparkline {
    param($History)

    $pts = @($History)
    if ($pts.Count -lt 2) { return '<span class="nil">&mdash;</span>' }

    $vals = @()
    foreach ($h in $pts) { $vals += [double] $h.p }
    # so os ultimos 40 pontos, senao a linha fica ilegivel
    if ($vals.Count -gt 40) { $vals = $vals[($vals.Count - 40)..($vals.Count - 1)] }

    $min = ($vals | Measure-Object -Minimum).Minimum
    $max = ($vals | Measure-Object -Maximum).Maximum
    $w = 64.0; $h = 20.0; $pad = 2.0
    $span = $max - $min

    $coords = @()
    for ($i = 0; $i -lt $vals.Count; $i++) {
        $x = $pad + ($w - 2 * $pad) * ($i / [Math]::Max(1, $vals.Count - 1))
        if ($span -le 0) { $y = $h / 2 }
        else { $y = $pad + ($h - 2 * $pad) * (1 - (($vals[$i] - $min) / $span)) }
        $coords += ('{0},{1}' -f [string]::Format($inv, '{0:N1}', $x), [string]::Format($inv, '{0:N1}', $y))
    }

    $last  = $vals[-1]
    $lastX = ($coords[-1] -split ',')[0]
    $lastY = ($coords[-1] -split ',')[1]

    $tip = 'min {0} EUR / max {1} EUR / agora {2} EUR ({3} leituras)' -f `
             (Fmt $min), (Fmt $max), (Fmt $last), $vals.Count

    return @"
<svg class="spark" viewBox="0 0 64 20" width="64" height="20" role="img" aria-label="$(HtmlEncode $tip)"><title>$(HtmlEncode $tip)</title><polyline points="$($coords -join ' ')" /><circle cx="$lastX" cy="$lastY" r="2.2" /></svg>
"@
}

# ---------------------------------------------------------------- destaques

$inStock = @($rows | Where-Object { (Test-InStockRow $_) -and $null -ne $_.EurPor100gProt })
$best    = $null
if ($inStock.Count -gt 0) { $best = @($inStock | Sort-Object EurPor100gProt)[0] }

$alerts   = @($status.alerts)
$health   = @($status.health)
$okStores = @($health | Where-Object { $_.Estado -eq 'ok' }).Count
$failed   = @($health | Where-Object { $_.Estado -ne 'ok' })

$maxPer = 0.0
foreach ($r in $rows) { if ($null -ne $r.EurPor100gProt -and [double] $r.EurPor100gProt -gt $maxPer) { $maxPer = [double] $r.EurPor100gProt } }
if ($maxPer -le 0) { $maxPer = 1 }

$gen = [datetime] $status.generatedAt
$geraldo = $gen.ToString('dd/MM/yyyy HH:mm')

# ---------------------------------------------------------------- html

$sb = New-Object System.Text.StringBuilder

[void] $sb.AppendLine(@"
<!doctype html>
<html lang="pt-PT">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>whey-watch</title>
<style>
  :root {
    color-scheme: light;
    --surface-1: #fcfcfb;
    --plane: #f9f9f7;
    --ink-1: #0b0b0b;
    --ink-2: #52514e;
    --ink-muted: #898781;
    --grid: #e1e0d9;
    --baseline: #c3c2b7;
    --accent: #2a78d6;
    --accent-wash: rgba(42,120,214,0.14);
    --good: #0ca30c;
    --ring: rgba(11,11,11,0.10);
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      color-scheme: dark;
      --surface-1: #1a1a19;
      --plane: #0d0d0d;
      --ink-1: #ffffff;
      --ink-2: #c3c2b7;
      --ink-muted: #898781;
      --grid: #2c2c2a;
      --baseline: #383835;
      --accent: #3987e5;
      --accent-wash: rgba(57,135,229,0.20);
      --good: #0ca30c;
      --ring: rgba(255,255,255,0.10);
    }
  }
  :root[data-theme="dark"] {
    color-scheme: dark;
    --surface-1: #1a1a19; --plane: #0d0d0d; --ink-1: #ffffff; --ink-2: #c3c2b7;
    --ink-muted: #898781; --grid: #2c2c2a; --baseline: #383835;
    --accent: #3987e5; --accent-wash: rgba(57,135,229,0.20); --good: #0ca30c;
    --ring: rgba(255,255,255,0.10);
  }

  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 20px 16px 56px;
    background: var(--plane); color: var(--ink-1);
    font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
    -webkit-text-size-adjust: 100%;
  }
  .wrap { max-width: 900px; margin: 0 auto; }

  h1 { font-size: 19px; margin: 0 0 2px; letter-spacing: -0.01em; }
  .sub { color: var(--ink-2); font-size: 13px; margin: 0 0 22px; }
  .sub b { color: var(--ink-1); font-weight: 600; }

  .card {
    background: var(--surface-1); border: 1px solid var(--ring);
    border-radius: 12px; padding: 16px 18px; margin-bottom: 18px;
  }
  .card-label {
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.07em;
    color: var(--ink-muted); margin-bottom: 8px;
  }
  .hero-num { font-size: 34px; font-weight: 650; line-height: 1.05; letter-spacing: -0.02em; }
  .hero-num small { font-size: 14px; font-weight: 400; color: var(--ink-2); letter-spacing: 0; }
  .hero-what { margin-top: 6px; font-size: 15px; }
  .hero-what a { color: var(--ink-1); text-decoration: none; border-bottom: 1px solid var(--baseline); }
  .hero-meta { color: var(--ink-2); font-size: 13px; margin-top: 4px; }

  .badge {
    display: inline-block; font-size: 10px; font-weight: 700; letter-spacing: 0.06em;
    text-transform: uppercase; padding: 2px 6px; border-radius: 4px;
    background: var(--good); color: #fff; vertical-align: 2px;
  }
  .promo-list { margin: 8px 0 0; padding-left: 18px; }
  .promo-list li { margin-bottom: 4px; }

  table { width: 100%; border-collapse: collapse; }
  caption { text-align: left; font-size: 11px; text-transform: uppercase;
            letter-spacing: 0.07em; color: var(--ink-muted); padding: 0 0 10px; }
  th {
    text-align: left; font-size: 11px; font-weight: 600; text-transform: uppercase;
    letter-spacing: 0.05em; color: var(--ink-muted);
    border-bottom: 1px solid var(--baseline); padding: 0 8px 7px 0;
  }
  td { padding: 9px 8px 9px 0; border-bottom: 1px solid var(--grid); vertical-align: middle; }
  tbody tr:hover { background: var(--accent-wash); }
  .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .store { color: var(--ink-2); font-size: 13px; white-space: nowrap; }
  .prod a { color: var(--ink-1); text-decoration: none; }
  .prod a:hover { text-decoration: underline; }
  .nil { color: var(--ink-muted); }

  /* barra de magnitude: comprimento = EUR/100g proteina. mais longa = mais caro */
  .bar-cell { position: relative; min-width: 96px; }
  .bar {
    position: absolute; left: 0; top: 50%; transform: translateY(-50%);
    height: 16px; background: var(--accent-wash);
    border-left: 2px solid var(--accent);
    border-radius: 0 4px 4px 0;
  }
  .bar-val { position: relative; padding-left: 6px; font-variant-numeric: tabular-nums; font-weight: 600; }

  .spark { display: block; overflow: visible; }
  .spark polyline { fill: none; stroke: var(--accent); stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
  .spark circle { fill: var(--accent); }

  tr.oos td { color: var(--ink-muted); }
  tr.oos .prod a { color: var(--ink-muted); }
  tr.oos .bar { background: transparent; border-left-color: var(--baseline); }
  tr.oos .spark polyline { stroke: var(--baseline); }
  tr.oos .spark circle { fill: var(--baseline); }
  .stock-oos { color: var(--ink-muted); font-size: 12px; white-space: nowrap; }
  .stock-in  { color: var(--ink-2); font-size: 12px; white-space: nowrap; }
  .struck { text-decoration: line-through; }

  footer { margin-top: 26px; color: var(--ink-2); font-size: 13px; }
  footer h2 { font-size: 13px; margin: 0 0 6px; color: var(--ink-1); }
  footer p { margin: 0 0 10px; }
  footer code { background: var(--surface-1); border: 1px solid var(--ring);
                padding: 1px 4px; border-radius: 3px; font-size: 12px; }

  @media (max-width: 640px) {
    thead { display: none; }
    table, tbody, tr, td { display: block; width: 100%; }
    caption { display: block; width: 100%; }
    /* a barra nao acrescenta nada num cartao: o numero ja esta ali e as linhas
       vem ordenadas, logo o ranking le-se sem ela */
    .bar { display: none; }
    tr { border-bottom: 1px solid var(--baseline); padding: 12px 0 10px; }
    td { border: none; padding: 1px 0; }
    td::before {
      content: attr(data-l); display: inline-block; min-width: 104px;
      font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em;
      color: var(--ink-muted);
    }
    .prod { font-size: 16px; font-weight: 600; padding-bottom: 4px; }
    .prod::before { display: none; }
    .num { text-align: left; }
    .bar-cell { min-width: 0; }
    .bar-val { display: inline-block; padding-left: 0; }
    .spark { display: inline-block; vertical-align: middle; }
  }
</style>
</head>
<body>
<div class="wrap">
  <h1>whey-watch</h1>
  <p class="sub">
    Pre&ccedil;os em Portugal, normalizados a <b>euro por 100&nbsp;g de prote&iacute;na real</b>.
    Atualizado a <b>$geraldo</b> &middot; $okStores de $($health.Count) lojas responderam.
  </p>
"@)

# ---- hero
if ($best) {
    $bLink = HtmlEncode ([string] $best.Url)
    [void] $sb.AppendLine(@"
  <div class="card">
    <div class="card-label">Melhor valor em stock</div>
    <div class="hero-num">$(Fmt $best.EurPor100gProt) <small>EUR / 100&nbsp;g de prote&iacute;na</small></div>
    <div class="hero-what"><a href="$bLink" rel="noopener">$(HtmlEncode ([string] $best.Produto))</a></div>
    <div class="hero-meta">$(HtmlEncode ([string] $best.Loja)) &middot; $(Fmt $best.Preco) EUR a embalagem</div>
  </div>
"@)
}

# ---- promocoes
if ($alerts.Count -gt 0) {
    [void] $sb.AppendLine('  <div class="card"><div class="card-label"><span class="badge">Promo&ccedil;&atilde;o</span></div><ul class="promo-list">')
    foreach ($a in $alerts) {
        [void] $sb.AppendLine(('    <li><b>{0}</b> &mdash; {1}</li>' -f (HtmlEncode ([string] $a.Titulo)), (HtmlEncode ([string] $a.Corpo))))
    }
    [void] $sb.AppendLine('  </ul></div>')
}

# ---- tabela
[void] $sb.AppendLine(@"
  <table>
    <caption>Todos os pre&ccedil;os vigiados, do melhor para o pior valor</caption>
    <thead>
      <tr>
        <th>Produto</th><th>Loja</th><th class="num">Pre&ccedil;o</th>
        <th class="num">EUR/100&nbsp;g prot.</th><th>Hist&oacute;rico</th><th class="num">M&iacute;n. visto</th><th>Stock</th>
      </tr>
    </thead>
    <tbody>
"@)

foreach ($r in $rows) {
    $ok  = Test-InStockRow $r
    $cls = ''
    if (-not $ok) { $cls = ' class="oos"' }

    $barW = 0
    if ($null -ne $r.EurPor100gProt) { $barW = [int](88 * ([double] $r.EurPor100gProt / $maxPer)) }
    if ($barW -lt 3 -and $null -ne $r.EurPor100gProt) { $barW = 3 }

    $perCell = '<span class="nil">&mdash;</span>'
    if ($null -ne $r.EurPor100gProt) {
        $perCell = ('<span class="bar" style="width:{0}px"></span><span class="bar-val">{1}</span>' -f $barW, (Fmt $r.EurPor100gProt))
    }

    $spark = '<span class="nil">&mdash;</span>'
    if ($r.Key -and $hist.ContainsKey([string] $r.Key)) { $spark = New-Sparkline -History $hist[[string] $r.Key] }

    if ($ok) { $stockCell = '<span class="stock-in">Em stock</span>' }
    else     { $stockCell = '<span class="stock-oos">Esgotado</span>' }

    $priceCls = 'num'
    if (-not $ok) { $priceCls = 'num struck' }

    $badge = ''
    if ($r.Alerta) { $badge = ' <span class="badge">Promo&ccedil;&atilde;o</span>' }

    [void] $sb.AppendLine(@"
      <tr$cls>
        <td class="prod" data-l="Produto"><a href="$(HtmlEncode ([string] $r.Url))" rel="noopener">$(HtmlEncode ([string] $r.Produto))</a>$badge</td>
        <td class="store" data-l="Loja">$(HtmlEncode ([string] $r.Loja))</td>
        <td class="$priceCls" data-l="Pre&ccedil;o">$(Fmt $r.Preco) EUR</td>
        <td class="num bar-cell" data-l="Por 100 g prot.">$perCell</td>
        <td data-l="Hist&oacute;rico">$spark</td>
        <td class="num" data-l="M&iacute;n. visto">$(Fmt $r.MinVisto)</td>
        <td data-l="Stock">$stockCell</td>
      </tr>
"@)
}

[void] $sb.AppendLine('    </tbody>')
[void] $sb.AppendLine('  </table>')

# ---- footer
[void] $sb.AppendLine('  <footer>')
if ($failed.Count -gt 0) {
    [void] $sb.AppendLine('    <h2>Lojas que nao responderam nesta ronda</h2>')
    [void] $sb.AppendLine('    <p>')
    $bits = @()
    foreach ($f in $failed) { $bits += ('{0} ({1})' -f (HtmlEncode ([string] $f.Loja)), (HtmlEncode ([string] $f.Estado))) }
    [void] $sb.AppendLine('      ' + ($bits -join ' &middot; '))
    [void] $sb.AppendLine('    </p>')
}
[void] $sb.AppendLine(@"
    <h2>Como ler isto</h2>
    <p>
      A coluna que decide e <code>EUR/100 g proteina</code>: preco a dividir pelos gramas
      de proteina que a embalagem realmente traz. E a unica forma de comparar um
      concentrado a 71&#37; com um isolado a 87&#37;, ou 500 g com 5 kg. A barra desenha
      esse valor &mdash; mais comprida significa mais caro.
    </p>
    <p>
      <b>Min visto</b> e o minimo que este vigilante observou, nao o preco de tabela da
      loja. Varias mantem uma tabela inflacionada de forma permanente, o que faz o
      desconto anunciado ser inutil como sinal.
    </p>
    <p>Precos sem portes. Fitnis e Prozis oferecem; MyProtein e Bulk cobram.</p>
  </footer>
</div>
</body>
</html>
"@)

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
$sb.ToString() | Out-File -FilePath $OutPath -Encoding utf8

Write-Host ('pagina escrita: {0} ({1} linhas, {2} KB)' -f `
    $OutPath, $rows.Count, [math]::Round((Get-Item $OutPath).Length / 1KB, 1)) -ForegroundColor Green

