$ErrorActionPreference = "Stop"
$url = "https://immobilisation-production.up.railway.app/"

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
