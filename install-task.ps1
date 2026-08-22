<#
.SYNOPSIS
    Registra (ou remove) a tarefa agendada que corre o whey-watch.

.DESCRIPTION
    A tarefa corre como o utilizador actual e SO com sessao iniciada - e uma
    exigencia das notificacoes toast do Windows, que precisam de uma sessao
    interactiva para aparecer. Se preferires receber por Telegram ou email em
    vez de toast, podes trocar o LogonType para S4U e correr sem sessao.

.PARAMETER IntervalHours
    Intervalo entre rondas. 3h e um bom compromisso: as lojas nao mudam precos
    de hora a hora e mantens-te longe dos limites de pedidos.

.PARAMETER Uninstall
    Remove a tarefa.

.EXAMPLE
    .\install-task.ps1
    .\install-task.ps1 -IntervalHours 6
    .\install-task.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [int]    $IntervalHours = 3,
    [string] $TaskName      = 'whey-watch',
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'whey-watch.ps1'
if (-not (Test-Path $script)) { throw "whey-watch.ps1 nao esta em $PSScriptRoot" }

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($Uninstall) {
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "tarefa '$TaskName' removida." -ForegroundColor Green
    }
    else {
        Write-Host "tarefa '$TaskName' nao existe - nada a fazer." -ForegroundColor Yellow
    }
    return
}

if ($existing) {
    Write-Host "tarefa '$TaskName' ja existe; vou substitui-la." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute  'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $script) `
    -WorkingDirectory $PSScriptRoot

# primeira ronda daqui a 2 minutos, depois a cada $IntervalHours
$trigger = New-ScheduledTaskTrigger `
    -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

$principal = New-ScheduledTaskPrincipal `
    -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -Principal   $principal `
    -Description ('Vigia precos de whey protein e notifica promocoes. Corre a cada {0}h.' -f $IntervalHours) | Out-Null

Write-Host ''
Write-Host ("tarefa '{0}' registada - a cada {1}h, primeira ronda daqui a 2 min." -f $TaskName, $IntervalHours) -ForegroundColor Green
Write-Host ''
Write-Host 'para ver o estado:'      -ForegroundColor DarkGray
Write-Host ("  Get-ScheduledTask -TaskName {0} | Get-ScheduledTaskInfo" -f $TaskName)
Write-Host 'para correr agora:'      -ForegroundColor DarkGray
Write-Host ("  Start-ScheduledTask -TaskName {0}" -f $TaskName)
Write-Host 'para remover:'           -ForegroundColor DarkGray
Write-Host ("  .\install-task.ps1 -Uninstall")
