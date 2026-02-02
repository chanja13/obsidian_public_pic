param(
  [Parameter(Mandatory = $true)]
  [string]$ImagePath,

  [string]$RepoRoot = "D:\chanja13\d_drive\repo\obsidian_public_pic"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-FileReady([string]$Path, [int]$TimeoutMs = 15000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    try {
      $fs = [System.IO.File]::Open($Path, "Open", "Read", "None")
      $fs.Close()
      return
    } catch {
      Start-Sleep -Milliseconds 200
    }
  }
  throw "File still locked after timeout: $Path"
}

function Get-GithubOwnerRepo([string]$RemoteUrl) {
  $u = $RemoteUrl.Trim()

  if ($u -match '^git@github\.com:(.+?)/(.+?)(\.git)?$') {
    return @($Matches[1], $Matches[2])
  }
  if ($u -match '^https://github\.com/(.+?)/(.+?)(\.git)?$') {
    return @($Matches[1], $Matches[2])
  }

  throw "Unsupported GitHub remote URL format: $u"
}

function Get-OriginDefaultBranchName {
  try {
    # Ensure origin/HEAD exists locally (best effort).
    & git remote set-head origin -a 2>$null | Out-Null

    $originHead = (& git symbolic-ref --quiet --short refs/remotes/origin/HEAD).Trim() # origin/main
    if ($originHead -match '^origin/(.+)$') {
      return $Matches[1]
    }
  } catch {
  }
  return $null
}

function Get-RelativePath([string]$BaseDir, [string]$TargetPath) {
  $baseFull = [System.IO.Path]::GetFullPath($BaseDir)
  if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $baseFull += [System.IO.Path]::DirectorySeparatorChar
  }

  $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

  $baseUri = New-Object System.Uri($baseFull)
  $targetUri = New-Object System.Uri($targetFull)

  $relUri = $baseUri.MakeRelativeUri($targetUri)
  $rel = [System.Uri]::UnescapeDataString($relUri.ToString())

  # Force forward slashes for git/URLs.
  $rel = $rel.Replace('\', '/')

  if ($rel.StartsWith("../") -or $rel.StartsWith("..\\")) {
    throw "TargetPath is outside RepoRoot: $TargetPath"
  }

  return $rel
}

$full = (Resolve-Path -LiteralPath $ImagePath).Path
Wait-FileReady -Path $full

if (-not (Test-Path -LiteralPath $RepoRoot)) {
  throw "RepoRoot not found: $RepoRoot"
}

Set-Location -LiteralPath $RepoRoot

$repoTop = (& git rev-parse --show-toplevel) 2>$null
if (-not $repoTop) {
  throw "Not a git repo: $RepoRoot"
}

$repoTop = $repoTop.Trim()
$rel = Get-RelativePath -BaseDir $repoTop -TargetPath $full

& git add -- "$rel" | Out-Null

# Exit if nothing staged (e.g. duplicate watcher event)
& git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
  exit 0
}

$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$leaf = Split-Path -Leaf $full
& git commit -m "add screenshot: $leaf ($ts)" | Out-Null
& git push | Out-Null

$branch = Get-OriginDefaultBranchName
if (-not $branch) {
  # Last-resort fallback; URL may not match default branch if origin/HEAD is unavailable.
  $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
}

$remote = (& git remote get-url origin).Trim()
$parts = Get-GithubOwnerRepo -RemoteUrl $remote
$owner = $parts[0]
$repo = $parts[1]

$rawUrl = "https://raw.githubusercontent.com/$owner/$repo/$branch/$rel"
$md = "![]($rawUrl)"

Set-Clipboard -Value $md
Write-Output $md
