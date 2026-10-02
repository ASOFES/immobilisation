$ErrorActionPreference = "Stop"
$port = 47231
$url = "http://127.0.0.1:$port/"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-AppUp {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $wait = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        $ok = $wait.AsyncWaitHandle.WaitOne(500, $false)
        if (-not $ok) {
            $client.Close()
            return $false
        }
        $client.EndConnect($wait)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

if (-not (Test-AppUp)) {
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-File", (Join-Path $root "demarrer.ps1")
    )
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not (Test-AppUp)) {
        Start-Sleep -Milliseconds 300
    }
}

if (-not (Test-AppUp)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "L'application d'immobilisation n'a pas pu démarrer.",
        "Immobilisation véhicules"
    ) | Out-Null
    exit 1
}

$edgeCandidates = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
)
$edge = $edgeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($edge) {
    Start-Process -FilePath $edge -ArgumentList @("--app=$url", "--window-size=1280,900")
} else {
    Start-Process $url
}
