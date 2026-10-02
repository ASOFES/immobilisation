$ErrorActionPreference = "Stop"
$port = 47231
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$prefix = "http://127.0.0.1:$port/"
$script:Minexx = $null

function Send-Json($ctx, $code, $obj) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = "application/json; charset=utf-8"
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Read-Body($ctx) {
    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    $reader.Close()
    if (-not $raw) { return $null }
    return $raw | ConvertFrom-Json
}

function Clean-Cell([string]$html) {
    $text = [regex]::Replace($html, "<[^>]+>", " ")
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    return ([regex]::Replace($text, "\s+", " ")).Trim()
}

function Connect-Minexx([string]$baseUrl, [string]$username, [string]$password) {
    if (-not $baseUrl) { throw "Indiquez l'adresse Railway du charroi." }
    if (-not $username -or -not $password) { throw "Indiquez le nom d'utilisateur et le mot de passe du charroi." }
    $base = $baseUrl.Trim().TrimEnd("/")
    if ($script:Minexx -and $script:Minexx.Base -eq $base -and $script:Minexx.User -eq $username) {
        return $script:Minexx
    }
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    try {
        $loginPage = Invoke-WebRequest -Uri "$base/login/" -WebSession $session -UseBasicParsing -TimeoutSec 25
    } catch {
        throw "Minexx ne répond pas à $base."
    }
    $csrf = [regex]::Match($loginPage.Content, 'name="csrfmiddlewaretoken" value="([^"]+)"').Groups[1].Value
    if (-not $csrf) { throw "La page de connexion Minexx est introuvable." }
    $logged = Invoke-WebRequest -Uri "$base/login/" -Method POST -WebSession $session -Body @{
        username = $username
        password = $password
        csrfmiddlewaretoken = $csrf
        next = "/entretien/planning/"
    } -Headers @{ Referer = "$base/login/" } -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 25
    $finalPath = ""
    if ($logged.BaseResponse.ResponseUri) { $finalPath = $logged.BaseResponse.ResponseUri.AbsolutePath }
    if ($logged.Content -match "ne correspondent pas" -or $finalPath -match "/login") {
        throw "Identifiants refusés par Minexx."
    }
    $script:Minexx = @{ Base = $base; User = $username; Session = $session }
    return $script:Minexx
}

function Get-CharroiVehicules([string]$baseUrl, [string]$username, [string]$password) {
    $link = Connect-Minexx $baseUrl $username $password
    $base = $link.Base
    $session = $link.Session
    $vehicules = New-Object System.Collections.Generic.List[object]
    $page = 1
    while ($page -le 40) {
        $list = Invoke-WebRequest -Uri "$base/vehicules/?page=$page" -WebSession $session -UseBasicParsing -TimeoutSec 25
        $rows = [regex]::Matches($list.Content, "(?s)<tr\b[^>]*>(.*?)</tr>")
        $added = 0
        foreach ($row in $rows) {
            $cells = [regex]::Matches($row.Groups[1].Value, "(?s)<td\b[^>]*>(.*?)</td>")
            if ($cells.Count -lt 4) { continue }
            $immat = Clean-Cell $cells[0].Groups[1].Value
            if (-not $immat -or $immat -match "Aucun véhicule") { continue }
            $idMatch = [regex]::Match($cells[0].Groups[1].Value, "/vehicules/(\d+)/")
            $vehicules.Add([ordered]@{
                id = $(if ($idMatch.Success) { $idMatch.Groups[1].Value } else { $immat })
                immatriculation = $immat
                marque = (Clean-Cell $cells[1].Groups[1].Value)
                modele = (Clean-Cell $cells[2].Groups[1].Value)
                affectation = (Clean-Cell $cells[3].Groups[1].Value)
                kilometrage = $null
            })
            $added++
        }
        $hasNext = $list.Content -match ('page=' + ($page + 1))
        if (-not $hasNext -or $added -eq 0) { break }
        $page++
    }
    return $vehicules
}

function Get-PlanningKm($payload) {
    $link = Connect-Minexx $payload.baseUrl $payload.username $payload.password
    $base = $link.Base
    $session = $link.Session
    $id = [string]$payload.vehiculeId
    $immat = [string]$payload.immatriculation
    if (-not $id) { throw "Véhicule Minexx introuvable." }

    $kilometrage = $null
    $kilometrageApres = $null
    $intervalleServeur = 4500

    try {
        $api = Invoke-WebRequest -Uri "$base/entretien/get-vehicule-kilometrage/?vehicule_id=$id" -WebSession $session -UseBasicParsing -TimeoutSec 25
        $data = $api.Content | ConvertFrom-Json
        if ($null -ne $data.kilometrage) { $kilometrage = [int]$data.kilometrage }
        if ($null -ne $data.prochain_entretien_km) {
            $kilometrageApres = [int]$data.prochain_entretien_km - $intervalleServeur
            if ($kilometrageApres -lt 0) { $kilometrageApres = 0 }
        }
    } catch {
        if (-not $kilometrage) { throw "Le planning entretien n'a pas renvoyé le kilométrage de ce véhicule." }
    }

    try {
        $page = Invoke-WebRequest -Uri "$base/entretien/planning/" -WebSession $session -UseBasicParsing -TimeoutSec 25
        if ($page.Content -notmatch 'name="csrfmiddlewaretoken"' -or $page.Content -match [regex]::Escape($immat)) {
            $rows = [regex]::Matches($page.Content, "(?s)<tr\b[^>]*>.*?</tr>")
            foreach ($row in $rows) {
                $text = Clean-Cell $row.Value
                if ($immat -and $text.Contains($immat)) {
                    $nums = [regex]::Matches($text, "\d{3,7}") | ForEach-Object { [int]$_.Value }
                    if ($nums.Count -ge 1 -and $null -eq $kilometrage) { $kilometrage = $nums[0] }
                    if ($nums.Count -ge 2) { $kilometrageApres = $nums[$nums.Count - 2] }
                    break
                }
            }
        }
    } catch {}

    if ($null -eq $kilometrage -and $null -eq $kilometrageApres) {
        throw "Aucun kilométrage d'entretien pour ce véhicule dans le planning Minexx."
    }
    return @{
        ok = $true
        kilometrage = $kilometrage
        kilometrageApres = $kilometrageApres
        prochain = $(if ($null -ne $kilometrageApres) { $kilometrageApres + 5000 } else { $null })
    }
}

function Update-Planning($payload) {
    $link = Connect-Minexx $payload.baseUrl $payload.username $payload.password
    $base = $link.Base
    $session = $link.Session
    $formPage = Invoke-WebRequest -Uri "$base/entretien/ajouter/" -WebSession $session -UseBasicParsing -TimeoutSec 25
    $csrf = [regex]::Match($formPage.Content, 'name="csrfmiddlewaretoken" value="([^"]+)"').Groups[1].Value
    if (-not $csrf) { throw "Formulaire d'entretien Minexx introuvable. Vérifiez que ce compte peut enregistrer un entretien." }
    $date = [string]$payload.date
    if (-not $date) { $date = (Get-Date).ToString("yyyy-MM-dd") }
    $body = @{
        csrfmiddlewaretoken = $csrf
        vehicule = [string]$payload.vehiculeId
        type_entretien = "ordinaire"
        garage = [string]$payload.garage
        date_entretien = $date
        statut = "termine"
        motif = [string]$payload.motif
        cout = "0"
        kilometrage = [string]$payload.kilometrage
        kilometrage_apres = [string]$payload.kilometrageApres
        commentaires = "Mis à jour depuis la note d'immobilisation. Prochain entretien à +5000 km."
        "pieces-TOTAL_FORMS" = "0"
        "pieces-INITIAL_FORMS" = "0"
        "pieces-MIN_NUM_FORMS" = "0"
        "pieces-MAX_NUM_FORMS" = "1000"
    }
    $saved = Invoke-WebRequest -Uri "$base/entretien/ajouter/" -Method POST -WebSession $session -Body $body -Headers @{ Referer = "$base/entretien/ajouter/" } -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 30
    $final = ""
    if ($saved.BaseResponse.ResponseUri) { $final = $saved.BaseResponse.ResponseUri.AbsoluteUri }
    if ($saved.Content -match "ne peut pas être inférieur[^<]{0,180}") {
        throw ([regex]::Match($saved.Content, "ne peut pas être inférieur[^<]{0,180}").Value)
    }
    if ($saved.Content -match "Le kilométrage après[^<]{0,120}") {
        throw ([regex]::Match($saved.Content, "Le kilométrage après[^<]{0,120}").Value)
    }
    if ($final -notmatch "/entretien/detail/" -and $saved.Content -match "alert-danger|errorlist|invalid-feedback") {
        throw "Minexx n'a pas enregistré l'entretien. Ouvrez le planning et vérifiez les champs obligatoires."
    }
    return @{ ok = $true; url = $final }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Output "IMMOBILISATION http://127.0.0.1:$port/"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        try {
            if ($ctx.Request.HttpMethod -eq "POST" -and $path -eq "/api/vehicules") {
                $payload = Read-Body $ctx
                $list = Get-CharroiVehicules $payload.baseUrl $payload.username $payload.password
                Send-Json $ctx 200 @{ ok = $true; vehicules = $list }
                continue
            }
            if ($ctx.Request.HttpMethod -eq "POST" -and $path -eq "/api/planning") {
                $payload = Read-Body $ctx
                $plan = Get-PlanningKm $payload
                Send-Json $ctx 200 $plan
                continue
            }
            if ($ctx.Request.HttpMethod -eq "POST" -and $path -eq "/api/planning/actualiser") {
                $payload = Read-Body $ctx
                $done = Update-Planning $payload
                Send-Json $ctx 200 $done
                continue
            }
            if ($path -ne "/" -and $path -ne "/index.html") {
                $ctx.Response.StatusCode = 404
                $ctx.Response.Close()
                continue
            }
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root "index.html"))
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = "text/html; charset=utf-8"
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Close()
        } catch {
            try { Send-Json $ctx 400 @{ ok = $false; error = $_.Exception.Message } } catch {}
        }
    }
} finally {
    $listener.Stop()
}
