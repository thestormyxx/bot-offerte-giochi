<#
    GIVEAWAY CDKEYIT SU DISCORD - versione per GitHub (gira anche a PC spento)
    -------------------------------------------------------------------------
    Pubblica giveaway-messaggio.txt nel canale Discord agli orari scritti in giveaway-config.json
    (ora italiana). GitHub avvia questo script piu' volte attorno a ogni orario: lo script pubblica
    solo se l'orario e' passato e non e' ancora stato pubblicato. Cosi' i ritardi di GitHub non
    fanno ne' saltare ne' doppiare i messaggi. Ora legale e solare sono gestite da sole.
    Il link del webhook arriva dal segreto GIVEAWAY_WEBHOOK_URL e non sta mai nei file.

    Prova (mostra cosa farebbe, non invia niente):
        powershell -NoProfile -ExecutionPolicy Bypass -File giveaway.ps1 -Prova
#>
param([switch]$Prova)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Utf8          = New-Object System.Text.UTF8Encoding($false)
$fileConfig    = Join-Path $PSScriptRoot 'giveaway-config.json'
$fileMessaggio = Join-Path $PSScriptRoot 'giveaway-messaggio.txt'
$fileStato     = Join-Path $PSScriptRoot 'giveaway-stato.json'

$config = ConvertFrom-Json ([IO.File]::ReadAllText($fileConfig, $Utf8))
$testo  = ([IO.File]::ReadAllText($fileMessaggio, $Utf8)).Trim()
if (-not $testo) { Write-Output 'giveaway-messaggio.txt e'' vuoto.'; exit 1 }

$url = ([string]$env:GIVEAWAY_WEBHOOK_URL).Trim()
if (-not $Prova -and $url -notmatch '^https://(ptb\.|canary\.)?discord(app)?\.com/api/webhooks/\d+/[\w-]+') {
    Write-Output 'Manca il segreto GIVEAWAY_WEBHOOK_URL (o non contiene un link di webhook valido): aggiungilo in Settings > Secrets and variables > Actions.'
    exit 1
}

# Ora italiana
$fuso   = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
$adesso = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $fuso)

# L'ultimo orario gia' passato (di oggi o di ieri)
$ultimo = $null
foreach ($giorno in @($adesso.Date, $adesso.Date.AddDays(-1))) {
    foreach ($o in @($config.orari)) {
        $t = $giorno.Add([TimeSpan]::Parse([string]$o))
        if ($t -le $adesso -and ($null -eq $ultimo -or $t -gt $ultimo)) { $ultimo = $t }
    }
}
if ($null -eq $ultimo) { Write-Output 'Nessun orario in giveaway-config.json.'; exit 1 }
$chiave = $ultimo.ToString('yyyy-MM-dd HH:mm')

$giaFatto = ''
if (Test-Path $fileStato) {
    try { $giaFatto = [string](ConvertFrom-Json ([IO.File]::ReadAllText($fileStato, $Utf8))).ultimo } catch { }
}
$ritardo = ($adesso - $ultimo).TotalMinutes
$massimo = 150
if ($config.ritardo_massimo_minuti) { $massimo = [int]$config.ritardo_massimo_minuti }

Write-Output ("Ora italiana {0:dd/MM HH:mm}. Ultimo orario: {1}. Gia' pubblicato: {2}" -f $adesso, $chiave, $(if ($giaFatto) { $giaFatto } else { 'niente' }))

function Salva([string]$Chiave) {
    [IO.File]::WriteAllText($fileStato, ([pscustomobject]@{ ultimo = $Chiave } | ConvertTo-Json), $Utf8)
}

if (-not $Prova) {
    if ($giaFatto -eq $chiave) { Write-Output 'Questo orario e'' gia'' stato pubblicato: niente da fare.'; exit 0 }
    if ($ritardo -gt $massimo) {
        Write-Output ("L'orario {0} e' passato da {1} minuti: troppo tardi, lo salto." -f $chiave, [int]$ritardo)
        Salva $chiave
        exit 0
    }
}

# Messaggio (di base non tagga nessuno; se c'e' un ruolo in config, tagga solo quello)
$contenuto = $testo
$menzioni  = @{ parse = @() }
$ruolo = ([string]$config.idRuoloDaMenzionare).Trim()
if ($ruolo -match '^\d+$') {
    $contenuto = '<@&' + $ruolo + '>' + "`n" + $testo
    $menzioni  = @{ parse = @(); roles = @($ruolo) }
}
$dati = @{ content = $contenuto; allowed_mentions = $menzioni }
if (([string]$config.nomeBot).Trim())   { $dati.username   = ([string]$config.nomeBot).Trim() }
if (([string]$config.avatarUrl).Trim()) { $dati.avatar_url = ([string]$config.avatarUrl).Trim() }
$json = $dati | ConvertTo-Json -Depth 5

if ($Prova) {
    Write-Output "PROVA: pubblicherei questo per l'orario $chiave (ritardo $([int]$ritardo) minuti):"
    Write-Output $json
    exit 0
}

for ($tentativo = 1; $tentativo -le 3; $tentativo++) {
    try {
        Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body $Utf8.GetBytes($json) -TimeoutSec 30 | Out-Null
        Salva $chiave
        Write-Output "Giveaway pubblicato per l'orario $chiave."
        exit 0
    } catch {
        $codice = 0
        if ($_.Exception.Response) { $codice = [int]$_.Exception.Response.StatusCode }
        if ($codice -eq 401 -or $codice -eq 403 -or $codice -eq 404) {
            Write-Output "Il link del webhook del giveaway non funziona (errore $codice): forse e' stato eliminato. Aggiorna il segreto GIVEAWAY_WEBHOOK_URL."
            exit 1
        }
        if ($codice -eq 400) { Write-Output 'Discord ha rifiutato il messaggio: controlla giveaway-messaggio.txt e nomeBot.'; exit 1 }
        Write-Output "Invio non riuscito (tentativo $tentativo di 3): $($_.Exception.Message)"
        Start-Sleep -Seconds (10 * $tentativo)
    }
}
exit 1
