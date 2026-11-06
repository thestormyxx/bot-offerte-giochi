<#
    BOT OFFERTE GIOCHI PER DISCORD
    ------------------------------
    Legge le pagine pubbliche di Allkeyshop (feed RSS di offerte, giochi gratis e giveaway,
    piu' la vetrina "Featured games" della home) e pubblica le novita' in un canale Discord
    tramite webhook. Ogni novita' viene pubblicata una volta sola.

    Avvio normale (resta acceso finche' la finestra e' aperta):
        powershell -NoProfile -ExecutionPolicy Bypass -File bot-offerte.ps1
    Prova (mostra cosa pubblicherebbe, non invia niente e non salva niente):
        powershell -NoProfile -ExecutionPolicy Bypass -File bot-offerte.ps1 -Prova
    Un solo controllo e poi esce:
        powershell -NoProfile -ExecutionPolicy Bypass -File bot-offerte.ps1 -UnaVolta

    Questo file contiene solo caratteri ASCII di proposito: PowerShell 5.1 legge male accenti
    ed emoji nei file .ps1. Testi ed emoji personalizzabili stanno in config-bot.json.
#>
param(
    [switch]$Prova,
    [switch]$UnaVolta
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$FileConfig = Join-Path $PSScriptRoot 'config-bot.json'
$FileStato  = Join-Path $PSScriptRoot 'stato.json'
$FileLog    = Join-Path $PSScriptRoot 'bot.log'
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$Invariante = [Globalization.CultureInfo]::InvariantCulture
$Italiano   = [Globalization.CultureInfo]::GetCultureInfo('it-IT')
$UserAgent  = 'Mozilla/5.0 (compatible; OfferteGiochiDiscordBot/1.0)'
$PausaSito  = 5   # secondi tra due richieste ad Allkeyshop: lo chiede il loro robots.txt
$Euro       = [string][char]0x20AC

# Parole da ignorare quando cerco il gioco giusto dentro un articolo
$ParoleGeneriche = @('buy', 'cd', 'key', 'keys', 'compare', 'prices', 'pc', 'ps4', 'ps5', 'xbox', 'one',
                     'series', 'nintendo', 'switch', 'steam', 'account', 'edition', 'the', 'of', 'and', 'a')

$script:Config          = $null
$script:UltimaRichiesta = [datetime]::MinValue
$script:BottoniOk       = $true
$script:Visti           = New-Object 'System.Collections.Generic.List[string]'
$script:VistiSet        = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Avviate         = New-Object 'System.Collections.Generic.List[string]'
$script:RotUltima       = [DateTimeOffset]::MinValue   # quando e' uscita l'ultima offerta a rotazione
$script:RotIndice       = 0                            # quale elenco del catalogo leggere la prossima volta
$script:RotGiochi       = @{}                          # link del gioco -> quando e' uscito a rotazione


# =============================================================== UTILITA'

function Emoji([int]$Codice) { return [char]::ConvertFromUtf32($Codice) }

function Scrivi-Log([string]$Testo, [string]$Colore = 'Gray') {
    $riga = '{0}  {1}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $Testo
    Write-Host $riga -ForegroundColor $Colore
    if ($Prova) { return }
    try {
        if ((Test-Path $FileLog) -and (Get-Item $FileLog).Length -gt 2MB) {
            Move-Item -LiteralPath $FileLog -Destination ($FileLog + '.vecchio') -Force
        }
        [IO.File]::AppendAllText($FileLog, $riga + [Environment]::NewLine, $Utf8)
    } catch { }
}

function Pulisci-Testo([string]$Testo) {
    if ([string]::IsNullOrEmpty($Testo)) { return '' }
    $t = [regex]::Replace($Testo, '<[^>]+>', ' ')
    $t = [Net.WebUtility]::HtmlDecode($t)
    return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

# Evita che asterischi, trattini bassi ecc. nei titoli rovinino la formattazione di Discord
function Testo-Sicuro([string]$Testo) {
    if ([string]::IsNullOrEmpty($Testo)) { return '' }
    return [regex]::Replace($Testo, '([\\*_~`|>\[\]])', '\$1')
}

function Taglia([string]$Testo, [int]$Max) {
    if ([string]::IsNullOrEmpty($Testo) -or $Testo.Length -le $Max) { return $Testo }
    return $Testo.Substring(0, $Max - 1).TrimEnd() + [char]0x2026
}

function Leggi-Numero($Valore) {
    $n = 0.0
    $t = ([string]$Valore).Trim().Replace(',', '.')
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, $Invariante, [ref]$n)) { return $n }
    return $null
}

function Formatta-Prezzo($Valore) {
    $n = Leggi-Numero $Valore
    if ($null -eq $n) { return [string]$Valore }
    return $n.ToString('0.00', $Italiano) + ' ' + $Euro
}

function Formatta-Sconto($Valore) {
    $n = Leggi-Numero $Valore
    if ($null -eq $n -or $n -le 0) { return $null }
    return '-' + [Math]::Round($n).ToString($Invariante) + '%'
}

function Leggi-Data([string]$Testo) {
    $d = [DateTimeOffset]::MinValue
    if ($Testo) {
        $t = [regex]::Replace($Testo.Trim(), '\s([+-]\d\d)(\d\d)$', ' $1:$2')
        if ([DateTimeOffset]::TryParseExact($t, 'ddd, dd MMM yyyy HH:mm:ss zzz', $Invariante,
                [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
        if ([DateTimeOffset]::TryParse($Testo, $Invariante, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    }
    return [DateTimeOffset]::Now
}


# =============================================================== CONFIGURAZIONE E STATO

function Leggi-Config {
    if (-not (Test-Path $FileConfig)) { throw 'Manca il file config-bot.json nella cartella del bot.' }
    try { $c = ConvertFrom-Json ([IO.File]::ReadAllText($FileConfig, $Utf8)) }
    catch { throw "config-bot.json ha un errore di scrittura (controlla virgole e virgolette): $($_.Exception.Message)" }
    $predefiniti = [ordered]@{
        webhook_url = ''; nome_bot = ''; avatar_url = ''; minuti_tra_controlli = 15
        primi_post_per_fonte = 3; massimo_post_per_giro = 10; ignora_piu_vecchi_di_giorni = 7; fonti = @()
    }
    foreach ($k in $predefiniti.Keys) {
        if ($null -eq $c.$k) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $predefiniti[$k] -Force }
    }
    # Su GitHub il link del webhook arriva dal segreto DISCORD_WEBHOOK_URL e non sta mai nei file
    if ($env:DISCORD_WEBHOOK_URL) { $c.webhook_url = $env:DISCORD_WEBHOOK_URL.Trim() }
    return $c
}

function Webhook-Valido([string]$Url) {
    return ($Url -match '^https://(ptb\.|canary\.)?discord(app)?\.com/api/(v\d+/)?webhooks/\d+/[\w-]+')
}

function Segna-Visto([string]$Id) {
    if ($Id -and $script:VistiSet.Add($Id)) { $script:Visti.Add($Id) }
}

function Carica-Stato {
    if (-not (Test-Path $FileStato)) { return }
    try {
        $s = ConvertFrom-Json ([IO.File]::ReadAllText($FileStato, $Utf8))
        if ($s.visti) { foreach ($v in $s.visti) { Segna-Visto ([string]$v) } }
        if ($s.fonti_avviate) { foreach ($f in $s.fonti_avviate) { $script:Avviate.Add([string]$f) } }
        if ($s.rotazione) {
            if ($s.rotazione.ultima) { $script:RotUltima = [DateTimeOffset]::Parse([string]$s.rotazione.ultima, $Invariante) }
            if ($s.rotazione.indice) { $script:RotIndice = [int]$s.rotazione.indice }
            if ($s.rotazione.giochi) {
                foreach ($p in $s.rotazione.giochi.PSObject.Properties) { $script:RotGiochi[$p.Name] = [string]$p.Value }
            }
        }
    } catch {
        Scrivi-Log 'stato.json non leggibile: riparto da zero (potrei ripubblicare qualche gioco).' 'Yellow'
    }
}

function Salva-Stato {
    if ($Prova) { return }
    while ($script:Visti.Count -gt 3000) {
        [void]$script:VistiSet.Remove($script:Visti[0])
        $script:Visti.RemoveAt(0)
    }
    $ultima = ''
    if ($script:RotUltima -gt [DateTimeOffset]::MinValue) { $ultima = $script:RotUltima.ToString('o', $Invariante) }
    $json = [pscustomobject]@{
        visti         = $script:Visti.ToArray()
        fonti_avviate = $script:Avviate.ToArray()
        rotazione     = [pscustomobject]@{ ultima = $ultima; indice = $script:RotIndice; giochi = $script:RotGiochi }
    } | ConvertTo-Json -Depth 4
    $tmp = $FileStato + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, $Utf8)
    Move-Item -LiteralPath $tmp -Destination $FileStato -Force
}


# =============================================================== LETTURA DI ALLKEYSHOP

function Scarica-Pagina([string]$Url) {
    # Rispetta la pausa chiesta dal sito tra una richiesta e l'altra
    $attesa = $PausaSito - ((Get-Date) - $script:UltimaRichiesta).TotalSeconds
    if ($attesa -gt 0) { Start-Sleep -Milliseconds ([int]($attesa * 1000)) }
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $UserAgent -TimeoutSec 40
    } finally {
        $script:UltimaRichiesta = Get-Date
    }
    # Decodifico io in UTF-8: PowerShell 5.1 a volte sbaglia gli accenti
    return $Utf8.GetString($r.RawContentStream.ToArray())
}

function Testo-Nodo($Nodo, [string]$Nome) {
    $n = $Nodo.SelectSingleNode($Nome)
    if ($n) { return $n.InnerText.Trim() }
    return ''
}

function Leggi-Feed([string]$Url) {
    $testo = (Scarica-Pagina $Url).Trim().TrimStart([char]0xFEFF).Trim()
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.LoadXml($testo)
    $voci = New-Object System.Collections.Generic.List[object]
    foreach ($item in $xml.SelectNodes('/rss/channel/item')) {
        $link = Testo-Nodo $item 'link'
        $id   = Testo-Nodo $item 'guid'
        if (-not $id) { $id = $link }
        $html = Testo-Nodo $item 'description'
        $img  = [regex]::Match($html, '<img[^>]+src="([^"]+)"')
        $par  = [regex]::Match($html, '<p>(.*?)</p>', 'Singleline')
        $voci.Add([pscustomobject]@{
            Id        = $id
            Titolo    = (Pulisci-Testo (Testo-Nodo $item 'title'))
            Link      = $link
            Data      = (Leggi-Data (Testo-Nodo $item 'pubDate'))
            Immagine  = $(if ($img.Success) { $img.Groups[1].Value } else { $null })
            Riassunto = $(if ($par.Success) { Pulisci-Testo $par.Groups[1].Value } else { '' })
        })
    }
    return $voci
}

# La vetrina "Featured games" in cima alla home di Allkeyshop
function Leggi-Vetrina([string]$Url) {
    $html = Scarica-Pagina $Url
    $blocco = [regex]::Match($html, '<aks-slider>(.*?)</aks-slider>', 'Singleline')
    if (-not $blocco.Success) { throw 'non trovo la vetrina "Featured games" nella home: forse il sito e'' cambiato' }
    $voci = New-Object System.Collections.Generic.List[object]
    $adesso = [DateTimeOffset]::Now
    $i = 0
    $schede = [regex]::Matches($blocco.Groups[1].Value, '<a\s+href="([^"]+)"\s+title="([^"]*)"\s*>(.*?)</a>', 'Singleline')
    foreach ($m in $schede) {
        $dentro = $m.Groups[3].Value
        $img    = [regex]::Match($dentro, '<img[^>]+src="([^"]+)"')
        $sconto = [regex]::Match($dentro, '(\d+(?:[.,]\d+)?)\s*(?:%|&#37;)\s*<br\s*/?>\s*Off', 'IgnoreCase')
        $prezzo = [regex]::Match($dentro, 'home-slide-price-tag[^>]*>\s*([\d.,]+)')
        $uscita = [regex]::Match($dentro, '(Released|Release) on\s+(\d{1,2}/\d{1,2}/\d{4})')
        $voci.Add([pscustomobject]@{
            Id       = 'vetrina:' + $m.Groups[1].Value
            Titolo   = (Pulisci-Testo ([regex]::Replace($m.Groups[2].Value, '\s+Price\s*$', '')))
            Link     = $m.Groups[1].Value
            Data     = $adesso.AddSeconds(-$i)
            Immagine = $(if ($img.Success) { [Net.WebUtility]::HtmlDecode($img.Groups[1].Value) } else { $null })
            Sconto   = $(if ($sconto.Success) { $sconto.Groups[1].Value } else { $null })
            Prezzo   = $(if ($prezzo.Success) { $prezzo.Groups[1].Value } else { $null })
            Uscita   = $(if ($uscita.Success) { $uscita.Groups[2].Value } else { $null })
            InArrivo = ($uscita.Success -and $uscita.Groups[1].Value -eq 'Release')
        })
        $i++
    }
    if ($voci.Count -eq 0) { throw 'la vetrina della home e'' vuota: forse il sito e'' cambiato' }
    return $voci
}

# Legge un valore annidato dai dati del catalogo senza errori se manca qualcosa
function Prendi($Oggetto, [string[]]$Chiavi) {
    $x = $Oggetto
    foreach ($k in $Chiavi) {
        if ($null -eq $x -or -not ($x -is [System.Collections.IDictionary]) -or -not $x.ContainsKey($k)) { return $null }
        $x = $x[$k]
    }
    return $x
}

# Un elenco del catalogo Allkeyshop (es. /blog/games/): 24 giochi con miglior prezzo e sconto,
# gia' scritti dentro la pagina. Non uso la loro /api, che il robots.txt chiede di non toccare.
function Leggi-Catalogo([string]$Url) {
    $html = Scarica-Pagina $Url
    $segno = 'var cataloginitjs = '
    $i = $html.IndexOf($segno)
    if ($i -lt 0) { throw 'non trovo i dati del catalogo nella pagina: forse il sito e'' cambiato' }
    $i += $segno.Length
    $f = $html.IndexOf('</script>', $i)
    $testo = [regex]::Replace($html.Substring($i, $f - $i), '//# sourceURL=.*$', '', 'Singleline').Trim().TrimEnd(';').Trim()
    Add-Type -AssemblyName System.Web.Extensions
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue   # i dati sono piu' grandi del limite normale di PowerShell 5.1
    $js.RecursionLimit = 200
    $cache = Prendi ($js.DeserializeObject($testo)) 'appData', 'cachedQueries'
    if (-not $cache) { throw 'dati del catalogo vuoti: forse il sito e'' cambiato' }
    $giochi = New-Object System.Collections.Generic.List[object]
    foreach ($k in @($cache.Keys)) {
        foreach ($p in @(Prendi $cache[$k] 'products')) {
            $o = @(Prendi $p 'offers')[0]
            if (-not $o) { continue }
            $basso = @(Prendi $p 'historical_low_offers')[0]
            $giochi.Add([pscustomobject]@{
                Nome        = (Pulisci-Testo ([string](Prendi $p 'name')))
                Link        = [string](Prendi $p 'link')
                Immagine    = [string](Prendi $p 'assets', 'capsule')
                Piattaforma = [string](Prendi $p 'operating_system', 'name')
                Prezzo      = (Prendi $o 'price')
                Sconto      = (Prendi $o 'official_offer_reduction_percent')
                Negozio     = [string](Prendi $o 'merchant', 'name')
                Edizione    = [string](Prendi $o 'edition', 'name')
                Codice      = [string](Prendi $o 'voucher', 'code')
                Disponibile = ([string](Prendi $o 'stock_status') -eq 'in_stock')
                Minimo      = (Prendi $basso 'price')
            })
        }
    }
    return $giochi
}

# Dentro un articolo di offerta trova il link alla pagina "confronta prezzi" del gioco giusto
function Scegli-LinkGioco([string]$Html, [string]$Titolo) {
    $trovati = @([regex]::Matches($Html, 'href="(https://www\.allkeyshop\.com/blog/buy-[a-z0-9-]+-compare-prices/)"') |
                 ForEach-Object { $_.Groups[1].Value })
    if ($trovati.Count -eq 0) { return $null }
    $parole = ' ' + [regex]::Replace($Titolo.ToLowerInvariant(), '[^a-z0-9]+', ' ') + ' '
    $migliore = $null
    $record = -1
    foreach ($gruppo in ($trovati | Group-Object)) {
        $slug = [regex]::Match($gruppo.Name, '/blog/buy-(.+)-compare-prices/').Groups[1].Value
        $punti = [Math]::Min($gruppo.Count, 9)
        foreach ($p in $slug.Split('-')) {
            if ($p -and ($ParoleGeneriche -notcontains $p) -and $parole.Contains(' ' + $p + ' ')) { $punti += 10 }
        }
        if ($punti -gt $record) { $record = $punti; $migliore = $gruppo.Name }
    }
    return $migliore
}

# Dati strutturati (JSON-LD) della pagina gioco: nome, immagine, prezzi
function Leggi-Prodotto([string]$Html) {
    $blocchi = [regex]::Matches($Html, '<script[^>]*application/ld\+json[^>]*>(.*?)</script>', 'Singleline')
    foreach ($m in $blocchi) {
        $json = $m.Groups[1].Value
        if ($json -notmatch '"@type"\s*:\s*"Product"') { continue }
        try { $dati = ConvertFrom-Json $json } catch { continue }
        foreach ($c in (@($dati) + @($dati.'@graph'))) {
            if ($c -and $c.'@type' -eq 'Product') { return $c }
        }
    }
    return $null
}

function Dettagli-Offerta($Voce) {
    $linkGioco = Scegli-LinkGioco (Scarica-Pagina $Voce.Link) $Voce.Titolo
    if (-not $linkGioco) { return $null }
    $prodotto = Leggi-Prodotto (Scarica-Pagina $linkGioco)
    $info = [ordered]@{
        Link = $linkGioco; Nome = $Voce.Titolo; Copertina = $null; Prezzo = $null
        Negozio = $null; Sconto = $null; DaPrezzo = $null; Offerte = $null
    }
    if ($prodotto) {
        if ($prodotto.name) { $info.Nome = Pulisci-Testo ([string]$prodotto.name) }
        if ($prodotto.image -is [string]) { $info.Copertina = $prodotto.image }
        elseif ($prodotto.image.url) { $info.Copertina = [string]$prodotto.image.url }
        if ($prodotto.offers) {
            $info.DaPrezzo = $prodotto.offers.lowPrice
            $info.Offerte  = $prodotto.offers.offerCount
        }
        # Esempio: "The best price for X PC is 8.48 EUR at GameBoost, with 57.6% off."
        $testo = [Net.WebUtility]::HtmlDecode([string]$prodotto.description)
        $prezzoRe = 'best price for .+? is ([0-9]+(?:[.,][0-9]+)?)\s*' + [regex]::Escape($Euro)
        $m = [regex]::Match($testo, $prezzoRe + ' at (.+?), with ([0-9]+(?:[.,][0-9]+)?)\s*% off', 'IgnoreCase')
        if (-not $m.Success) {
            $m = [regex]::Match($testo, $prezzoRe + ' at ([^,]+?)\.(?:\s|$)', 'IgnoreCase')
        }
        if ($m.Success) {
            $info.Prezzo  = $m.Groups[1].Value
            $info.Negozio = $m.Groups[2].Value.Trim()
            if ($m.Groups.Count -gt 3 -and $m.Groups[3].Success) { $info.Sconto = $m.Groups[3].Value }
        }
    }
    return [pscustomobject]$info
}


# =============================================================== MESSAGGI DISCORD

function Colore-Da([string]$Hex) {
    try { return [Convert]::ToInt32($Hex.Trim().TrimStart('#'), 16) } catch { return 5793266 }
}

function Nuovo-Embed($Fonte, $Voce) {
    $e = [ordered]@{
        title     = (Taglia $Voce.Titolo 256)
        url       = $Voce.Link
        color     = (Colore-Da ([string]$Fonte.colore))
        footer    = @{ text = 'Fonte: Allkeyshop.com  |  I prezzi cambiano spesso: controlla sempre sul sito' }
        timestamp = $Voce.Data.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Invariante)
    }
    if ($Fonte.etichetta) { $e.author = @{ name = (Taglia ([string]$Fonte.etichetta) 256) } }
    return $e
}

function Campo([string]$Nome, [string]$Valore) {
    return [ordered]@{ name = (Taglia $Nome 256); value = (Taglia $Valore 1024); inline = $true }
}

function Bottone([string]$Testo, [string]$Url, [int]$Icona) {
    $b = [ordered]@{ type = 2; style = 5; label = $Testo; url = $Url }
    if ($Icona) { $b.emoji = @{ name = (Emoji $Icona) } }
    return $b
}

function Nuovo-Messaggio($Embed, [object[]]$Bottoni) {
    $m = [ordered]@{
        embeds           = @($Embed)
        allowed_mentions = @{ parse = @() }   # il bot non tagga mai nessuno
    }
    if ($script:Config.nome_bot)   { $m.username   = Taglia ([string]$script:Config.nome_bot) 80 }
    if ($script:Config.avatar_url) { $m.avatar_url = [string]$script:Config.avatar_url }
    if ($Bottoni -and $Bottoni.Count) { $m.components = @([ordered]@{ type = 1; components = $Bottoni }) }
    return $m
}

function Messaggio-Articolo($Fonte, $Voce) {
    $e = Nuovo-Embed $Fonte $Voce
    if ($Voce.Riassunto) { $e.description = Testo-Sicuro (Taglia $Voce.Riassunto 400) }
    if ($Voce.Immagine)  { $e.image = @{ url = $Voce.Immagine } }
    return Nuovo-Messaggio $e @(Bottone 'Apri su Allkeyshop' $Voce.Link 0x1F517)
}

function Messaggio-Offerta($Fonte, $Voce, $Info) {
    $e = Nuovo-Embed $Fonte $Voce
    $e.title = Taglia $Info.Nome 256
    $e.url   = $Info.Link
    $e.description = '*' + (Testo-Sicuro (Taglia $Voce.Titolo 300)) + "*`n[Leggi l'articolo](" + $Voce.Link + ')'
    $campi = New-Object System.Collections.Generic.List[object]
    if ($Info.Prezzo) {
        $v = '**' + (Formatta-Prezzo $Info.Prezzo) + '**'
        if ($Info.Negozio) { $v += ' su ' + (Testo-Sicuro $Info.Negozio) }
        $campi.Add((Campo ((Emoji 0x1F4B0) + ' Miglior prezzo') $v))
    } elseif ($Info.DaPrezzo) {
        $campi.Add((Campo ((Emoji 0x1F4B0) + ' Prezzo') ('da **' + (Formatta-Prezzo $Info.DaPrezzo) + '**')))
    }
    $sconto = Formatta-Sconto $Info.Sconto
    if ($sconto) { $campi.Add((Campo ((Emoji 0x1F525) + ' Sconto') $sconto)) }
    if ($Info.Offerte) { $campi.Add((Campo ((Emoji 0x1F6D2) + ' Offerte a confronto') ([string]$Info.Offerte))) }
    if ($campi.Count) { $e.fields = $campi.ToArray() }
    if ($Voce.Immagine)  { $e.image = @{ url = $Voce.Immagine } }
    if ($Info.Copertina) { $e.thumbnail = @{ url = $Info.Copertina } }
    return Nuovo-Messaggio $e @((Bottone 'Confronta i prezzi' $Info.Link 0x1F6D2), (Bottone "Leggi l'articolo" $Voce.Link 0x1F4F0))
}

function Messaggio-Vetrina($Fonte, $Voce) {
    $e = Nuovo-Embed $Fonte $Voce
    $campi = New-Object System.Collections.Generic.List[object]
    if ($Voce.Prezzo) { $campi.Add((Campo ((Emoji 0x1F4B0) + ' Miglior prezzo') ('**' + (Formatta-Prezzo $Voce.Prezzo) + '**'))) }
    $sconto = Formatta-Sconto $Voce.Sconto
    if ($sconto) { $campi.Add((Campo ((Emoji 0x1F525) + ' Sconto') $sconto)) }
    if ($Voce.Uscita) {
        $quando = $Voce.Uscita
        if ($Voce.InArrivo) { $quando += ' (in arrivo)' }
        $campi.Add((Campo ((Emoji 0x1F4C5) + ' Uscita') $quando))
    }
    if ($campi.Count) { $e.fields = $campi.ToArray() }
    if ($Voce.Immagine) { $e.image = @{ url = $Voce.Immagine } }
    return Nuovo-Messaggio $e @(Bottone 'Confronta i prezzi' $Voce.Link 0x1F6D2)
}

function Messaggio-Rotazione($Fonte, $Gioco) {
    $voce = [pscustomobject]@{ Titolo = $Gioco.Nome; Link = $Gioco.Link; Data = [DateTimeOffset]::Now }
    $e = Nuovo-Embed $Fonte $voce
    $campi = New-Object System.Collections.Generic.List[object]
    $v = '**' + (Formatta-Prezzo $Gioco.Prezzo) + '**'
    if ($Gioco.Negozio) { $v += ' su ' + (Testo-Sicuro $Gioco.Negozio) }
    $campi.Add((Campo ((Emoji 0x1F4B0) + ' Miglior prezzo') $v))
    $sconto = Formatta-Sconto $Gioco.Sconto
    if ($sconto) { $campi.Add((Campo ((Emoji 0x1F525) + ' Sconto') $sconto)) }
    if ($Gioco.Piattaforma) { $campi.Add((Campo ((Emoji 0x1F3AE) + ' Piattaforma') (Testo-Sicuro $Gioco.Piattaforma))) }
    if ($Gioco.Codice) { $campi.Add((Campo ((Emoji 0x1F3F7) + ' Codice sconto') ('`' + $Gioco.Codice + '`'))) }
    if ($null -ne (Leggi-Numero $Gioco.Minimo)) { $campi.Add((Campo ((Emoji 0x1F4C9) + ' Minimo storico') (Formatta-Prezzo $Gioco.Minimo))) }
    $e.fields = $campi.ToArray()
    if ($Gioco.Edizione -and $Gioco.Edizione -ne 'Standard') { $e.description = 'Edizione: ' + (Testo-Sicuro $Gioco.Edizione) }
    if ($Gioco.Immagine) { $e.image = @{ url = $Gioco.Immagine } }
    return Nuovo-Messaggio $e @(Bottone 'Confronta i prezzi' $Gioco.Link 0x1F6D2)
}

function Prepara-Messaggio($Fonte, $Voce) {
    if ($Fonte.tipo -eq 'vetrina') { return Messaggio-Vetrina $Fonte $Voce }
    if ($Fonte.tipo -eq 'offerta') {
        $info = $null
        try { $info = Dettagli-Offerta $Voce }
        catch { Scrivi-Log "   (dettagli del gioco non disponibili: $($_.Exception.Message))" 'Yellow' }
        if ($info) { return Messaggio-Offerta $Fonte $Voce $info }
    }
    return Messaggio-Articolo $Fonte $Voce
}

function Aggiungi-Parametro([string]$Url, [string]$Parametro) {
    if ($Url.Contains('?')) { return $Url + '&' + $Parametro }
    return $Url + '?' + $Parametro
}

# $true = pubblicato, $false = Discord ha scartato quel messaggio (lo salto).
# Se il webhook non funziona o Discord non risponde lancia un errore: riprovo al giro dopo.
function Invia-Discord($Messaggio) {
    if (-not $script:BottoniOk) { $Messaggio.Remove('components') }
    $tolti = $false
    for ($tentativo = 1; $tentativo -le 5; $tentativo++) {
        $url = [string]$script:Config.webhook_url
        if ($Messaggio.Contains('components')) { $url = Aggiungi-Parametro $url 'with_components=true' }
        $corpo = $Utf8.GetBytes(($Messaggio | ConvertTo-Json -Depth 12 -Compress))
        try {
            $null = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json' -Body $corpo `
                                      -UseBasicParsing -UserAgent $UserAgent -TimeoutSec 30
            if ($tolti) {
                $script:BottoniOk = $false
                Scrivi-Log 'Discord non accetta i pulsanti da questo webhook: continuo senza pulsanti.' 'Yellow'
            }
            return $true
        } catch {
            $codice = 0
            if ($_.Exception.Response) { $codice = [int]$_.Exception.Response.StatusCode }
            $dettaglio = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $dettaglio = $_.ErrorDetails.Message }
            if ($codice -eq 429) {
                $secondi = 5
                try { $secondi = [int][Math]::Ceiling([double](ConvertFrom-Json $dettaglio).retry_after) + 1 } catch { }
                Scrivi-Log "Discord chiede di rallentare: aspetto $secondi secondi." 'Yellow'
                Start-Sleep -Seconds $secondi
                continue
            }
            if ($codice -eq 400 -and $Messaggio.Contains('components')) {
                $Messaggio.Remove('components')
                $tolti = $true
                continue
            }
            if ($codice -eq 400) {
                Scrivi-Log "Discord ha scartato il messaggio: $dettaglio" 'Yellow'
                return $false
            }
            if ($codice -eq 401 -or $codice -eq 403 -or $codice -eq 404) {
                throw "il link del webhook non funziona (errore $codice). Forse il webhook e' stato eliminato: creane uno nuovo e aggiorna il link (in config-bot.json sul PC, o nel segreto DISCORD_WEBHOOK_URL su GitHub)."
            }
            Scrivi-Log "Discord non risponde (tentativo $tentativo di 5): $($_.Exception.Message)" 'Yellow'
            Start-Sleep -Seconds (5 * $tentativo)
        }
    }
    throw 'Discord non risponde: riprovo al prossimo controllo.'
}

function Mostra-Anteprima($Messaggio) {
    $e = $Messaggio.embeds[0]
    Write-Host ''
    if ($e.author) { Write-Host ('   ' + $e.author.name) -ForegroundColor Magenta }
    Write-Host ('   ' + $e.title) -ForegroundColor White
    Write-Host ('   ' + $e.url) -ForegroundColor Cyan
    foreach ($f in @($e.fields)) { if ($f) { Write-Host ('     ' + $f.name + ': ' + $f.value) } }
    if ($e.image) { Write-Host ('     immagine: ' + $e.image.url) -ForegroundColor DarkGray }
    if ($Messaggio.components) {
        foreach ($b in $Messaggio.components[0].components) {
            Write-Host ('     [pulsante] ' + $b.label + ' -> ' + $b.url) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

function Imposta-Webhook {
    Write-Host ''
    Write-Host 'Manca il link del webhook di Discord (serve una volta sola).' -ForegroundColor Yellow
    Write-Host 'Su Discord: Modifica canale > Integrazioni > Webhook > Nuovo webhook > Copia URL webhook.'
    $url = $null
    for ($i = 1; $i -le 3; $i++) {
        try { $url = ([string](Read-Host 'Incolla qui il link e premi Invio')).Trim().Trim([char]34).Trim() }
        catch { return $false }
        if (Webhook-Valido $url) { break }
        Write-Host 'Questo non sembra un link di webhook Discord (inizia con https://discord.com/api/webhooks/). Riprova.' -ForegroundColor Red
        $url = $null
    }
    if (-not $url) { return $false }
    $testo = [IO.File]::ReadAllText($FileConfig, $Utf8)
    $testo = [regex]::Replace($testo, '"webhook_url"\s*:\s*"[^"]*"', ('"webhook_url": "' + $url.Replace('$', '$$') + '"'))
    [IO.File]::WriteAllText($FileConfig, $testo, $Utf8)
    $script:Config = Leggi-Config
    $benvenuto = Nuovo-Messaggio ([ordered]@{
        title       = (Emoji 0x2705) + ' Bot collegato!'
        description = 'Da ora in questo canale arrivano in automatico offerte, giochi gratis e giveaway presi da Allkeyshop. Clicca sul titolo o sul pulsante per aprire il gioco.'
        color       = 3066993
    }) $null
    try { [void](Invia-Discord $benvenuto) }
    catch { Scrivi-Log "Non riesco a scrivere su Discord: $($_.Exception.Message)" 'Red'; return $false }
    Scrivi-Log 'Webhook salvato in config-bot.json e messaggio di benvenuto inviato.' 'Green'
    return $true
}

# Chiede a Discord se il webhook esiste e in quale canale scrive. Non pubblica niente.
function Verifica-Webhook {
    try {
        $r = Invoke-WebRequest -Uri ([string]$script:Config.webhook_url) -UseBasicParsing -UserAgent $UserAgent -TimeoutSec 30
        $w = ConvertFrom-Json ($Utf8.GetString($r.RawContentStream.ToArray()))
        Scrivi-Log ('Webhook Discord OK: "{0}" (canale {1})' -f $w.name, $w.channel_id) 'Green'
        return $true
    } catch {
        $codice = 0
        if ($_.Exception.Response) { $codice = [int]$_.Exception.Response.StatusCode }
        if ($codice -eq 401 -or $codice -eq 403 -or $codice -eq 404) {
            Scrivi-Log "Il link del webhook non funziona (errore $codice): forse il webhook e' stato eliminato. Creane uno nuovo su Discord e aggiorna il link." 'Red'
            return $false
        }
        Scrivi-Log "Non riesco a controllare il webhook adesso ($($_.Exception.Message)): vado avanti lo stesso." 'Yellow'
        return $true
    }
}


# =============================================================== GIRO DI CONTROLLO

# Offerte a rotazione: ogni tot minuti pubblica il gioco piu' scontato di un elenco del catalogo,
# girando tra gli elenchi e senza ripetere lo stesso gioco per qualche giorno.
function Giro-Rotazione($Fonte) {
    $ogni = [Math]::Max(5, [int]$Fonte.ogni_minuti)
    $passati = ([DateTimeOffset]::Now - $script:RotUltima).TotalMinutes
    # 3 minuti di tolleranza: i giri su GitHub non partono mai all'orario esatto
    if (-not $Prova -and $passati -lt ($ogni - 3)) {
        Scrivi-Log ("[{0}] prossima offerta a rotazione tra circa {1} minuti" -f $Fonte.id, [int][Math]::Ceiling($ogni - $passati))
        return
    }
    $pagine = @($Fonte.pagine | Where-Object { $_ })
    if ($pagine.Count -eq 0) { return }
    $minimo = 0.0
    if ($null -ne (Leggi-Numero $Fonte.sconto_minimo)) { $minimo = Leggi-Numero $Fonte.sconto_minimo }
    $giorni = [Math]::Max(1, [int]$Fonte.ripeti_dopo_giorni)
    # I giochi usciti piu' di N giorni fa possono tornare
    $limite = [DateTimeOffset]::Now.AddDays(-$giorni)
    foreach ($k in @($script:RotGiochi.Keys)) {
        $d = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$script:RotGiochi[$k], $Invariante, [Globalization.DateTimeStyles]::None, [ref]$d) -or $d -lt $limite) {
            $script:RotGiochi.Remove($k)
        }
    }
    for ($tentativo = 1; $tentativo -le 3; $tentativo++) {
        $url = [string]$pagine[$script:RotIndice % $pagine.Count]
        $script:RotIndice = ($script:RotIndice + 1) % 100000
        try { $giochi = @(Leggi-Catalogo $url) }
        catch { Scrivi-Log "[$($Fonte.id)] non riesco a leggere $url : $($_.Exception.Message)" 'Yellow'; continue }
        $scelto = $giochi | Where-Object {
            $_.Disponibile -and $_.Link -and ((Leggi-Numero $_.Prezzo) -gt 0) -and
            ((Leggi-Numero $_.Sconto) -ge $minimo) -and ($_.Nome -notmatch '\bAccount\b') -and
            (-not $script:RotGiochi.ContainsKey($_.Link))
        } | Sort-Object -Property @{ Expression = { Leggi-Numero $_.Sconto } } -Descending | Select-Object -First 1
        if (-not $scelto) {
            Scrivi-Log "[$($Fonte.id)] in $url nessun gioco nuovo abbastanza scontato, provo il prossimo elenco"
            continue
        }
        Scrivi-Log ("[{0}] offerta a rotazione: {1} ({2}, {3})" -f $Fonte.id, $scelto.Nome, (Formatta-Prezzo $scelto.Prezzo), (Formatta-Sconto $scelto.Sconto)) 'White'
        $messaggio = Messaggio-Rotazione $Fonte $scelto
        if ($Prova) { Mostra-Anteprima $messaggio; return }
        [void](Invia-Discord $messaggio)
        $script:RotUltima = [DateTimeOffset]::Now
        $script:RotGiochi[$scelto.Link] = [DateTimeOffset]::Now.ToString('o', $Invariante)
        Salva-Stato
        return
    }
    Salva-Stato
}

function Esegui-Giro {
    $script:Config = Leggi-Config
    $coda = New-Object System.Collections.Generic.List[object]
    $rotazione = $null

    foreach ($fonte in @($script:Config.fonti)) {
        if (-not $fonte -or -not $fonte.attiva) { continue }
        if ($fonte.tipo -eq 'rotazione') { $rotazione = $fonte; continue }
        $id = [string]$fonte.id
        try {
            if ($fonte.tipo -eq 'vetrina') { $voci = @(Leggi-Vetrina ([string]$fonte.indirizzo)) }
            else { $voci = @(Leggi-Feed ([string]$fonte.indirizzo)) }
        } catch {
            Scrivi-Log "[$id] non riesco a leggere la fonte: $($_.Exception.Message)" 'Yellow'
            continue
        }
        $ordinate = @($voci | Sort-Object -Property Data -Descending)
        # Le notizie troppo vecchie non le pubblico mai (es. giochi gratis gia' scaduti)
        $giorni = [int]$script:Config.ignora_piu_vecchi_di_giorni
        if ($giorni -le 0) { $giorni = 36500 }
        $limite = [DateTimeOffset]::Now.AddDays(-$giorni)
        foreach ($v in @($ordinate | Where-Object { $_.Data -lt $limite })) { Segna-Visto $v.Id }
        if (-not $script:Avviate.Contains($id)) {
            # Prima volta che leggo questa fonte: considero solo le piu' recenti, le altre le segno come gia' viste
            $quante = [Math]::Max(0, [int]$script:Config.primi_post_per_fonte)
            foreach ($v in @($ordinate | Select-Object -Skip $quante)) { Segna-Visto $v.Id }
            $script:Avviate.Add($id)
        }
        $nuove = @($ordinate | Where-Object { -not $script:VistiSet.Contains($_.Id) })
        Scrivi-Log "[$id] letti $($voci.Count), nuovi da pubblicare $($nuove.Count)"
        foreach ($v in $nuove) { $coda.Add([pscustomobject]@{ Fonte = $fonte; Voce = $v }) }
    }
    Salva-Stato

    if ($coda.Count -eq 0) {
        Scrivi-Log 'Nessuna novita.'
        if ($rotazione) { Giro-Rotazione $rotazione }
        return
    }
    $massimo = [Math]::Max(1, [int]$script:Config.massimo_post_per_giro)
    $lista = @($coda | Sort-Object -Property { $_.Voce.Data } | Select-Object -First $massimo)
    if ($coda.Count -gt $lista.Count) {
        Scrivi-Log "Ne pubblico $($lista.Count) adesso, le altre $($coda.Count - $lista.Count) al prossimo controllo."
    }

    $anteprime = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($x in $lista) {
        $n++
        Scrivi-Log "($n/$($lista.Count)) [$($x.Fonte.id)] $($x.Voce.Titolo)" 'White'
        $messaggio = Prepara-Messaggio $x.Fonte $x.Voce
        if ($Prova) {
            Mostra-Anteprima $messaggio
            $anteprime.Add($messaggio)
            continue
        }
        if (-not (Invia-Discord $messaggio)) { Scrivi-Log '   saltato.' 'Yellow' }
        Segna-Visto $x.Voce.Id
        Salva-Stato
        Start-Sleep -Seconds 2
    }

    if ($Prova -and $anteprime.Count) {
        $file = Join-Path $env:TEMP 'bot-offerte-anteprima.json'
        [IO.File]::WriteAllText($file, ($anteprime.ToArray() | ConvertTo-Json -Depth 12), $Utf8)
        Scrivi-Log "Messaggi completi (formato Discord) salvati in: $file" 'DarkGray'
    }
    if ($rotazione) { Giro-Rotazione $rotazione }
}


# =============================================================== AVVIO

Scrivi-Log '=== Bot Offerte Giochi avviato ===' 'Cyan'
if ($Prova) { Scrivi-Log 'MODALITA PROVA: mostro cosa pubblicherei, senza inviare niente a Discord.' 'Cyan' }

# Un solo bot alla volta: se e' gia' acceso in un'altra finestra, questa si chiude da sola
if (-not $Prova) {
    $primo = $false
    $script:Mutex = [System.Threading.Mutex]::new($true, 'Local\BotOfferteGiochiDiscord', [ref]$primo)
    if (-not $primo) {
        Scrivi-Log 'Il bot e'' gia'' acceso in un''altra finestra (guarda nella barra delle applicazioni). Chiudo questa.' 'Yellow'
        exit 0
    }
}

try { $script:Config = Leggi-Config } catch { Scrivi-Log $_.Exception.Message 'Red'; exit 1 }
Carica-Stato

if (-not $Prova -and -not (Webhook-Valido ([string]$script:Config.webhook_url))) {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Scrivi-Log 'Manca il segreto DISCORD_WEBHOOK_URL (o non contiene un link di webhook valido): aggiungilo in Settings > Secrets and variables > Actions.' 'Red'
        exit 1
    }
    if (-not (Imposta-Webhook)) {
        Scrivi-Log 'Senza il link del webhook non posso pubblicare. Chiudo.' 'Red'
        exit 1
    }
}
if (-not $Prova -and -not (Verifica-Webhook)) { exit 1 }

$attive = @($script:Config.fonti | Where-Object { $_.attiva } | ForEach-Object { $_.id }) -join ', '
Scrivi-Log "Fonti attive: $attive" 'Cyan'

$erroreGiro = $false
while ($true) {
    try { Esegui-Giro } catch { Scrivi-Log "Errore: $($_.Exception.Message)" 'Red'; $erroreGiro = $true }
    if ($Prova -or $UnaVolta) { break }
    $minuti = [Math]::Max(5, [int]$script:Config.minuti_tra_controlli)
    Scrivi-Log "Prossimo controllo tra $minuti minuti. Per fermare il bot chiudi questa finestra." 'DarkGray'
    Start-Sleep -Seconds ($minuti * 60)
}
# Su GitHub un errore rende il giro "rosso": cosi' GitHub ti avvisa per email
if ($UnaVolta -and $erroreGiro) { exit 1 }
