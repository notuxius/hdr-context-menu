# Ketarin runs this as its PowerShell post-download command, with $app provided.
# Extraction only: installing remains a separate Ketarin action.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Path]::GetFullPath($app.PreviousLocation)
$folder = [IO.Path]::GetDirectoryName($archive)
$destination = Join-Path $folder 'Package'
$previous = Join-Path $folder 'Package.previous'
$stage = Join-Path $folder ('extract-' + [Guid]::NewGuid().ToString('N'))

function Assert-PackagePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($full) -ne $folder -or
        [IO.Path]::GetFileName($full) -notmatch '^(Package(\.previous)?|extract-[0-9a-f]{32})$') {
        throw 'Refusing to modify a path outside the package download folder.'
    }
    if (Test-Path -LiteralPath $full) {
        $items = @(Get-Item -LiteralPath $full) + @(Get-ChildItem -LiteralPath $full -Recurse -Force)
        if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
            throw 'The package folder must not contain a symbolic link or junction.'
        }
    }
}

Assert-PackagePath $destination
Assert-PackagePath $previous
Assert-PackagePath $stage
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $expectedCommit = $app.Variables['version'].CachedContent
    if ($expectedCommit -notmatch '^[0-9a-f]{40}$') { throw 'Ketarin did not resolve a valid GitHub commit.' }
    $activeArchive = $archive
    $probe = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $downloadRoot = @($probe.Entries | ForEach-Object { ($_.FullName -split '/')[0] } | Select-Object -Unique)
    } finally { $probe.Dispose() }
    if ($downloadRoot.Count -ne 1 -or $downloadRoot[0] -ne ('hdr-context-menu-' + $expectedCommit)) {
        # Ketarin may resolve the download URL before refreshing its version indicator.
        # Fetch the exact detected commit if main changed between those two requests.
        $activeArchive = Join-Path $stage 'detected-commit.zip'
        $client = New-Object Net.WebClient
        try {
            $client.Headers['User-Agent'] = 'HdrContextMenu-Ketarin'
            $client.DownloadFile(('https://codeload.github.com/notuxius/hdr-context-menu/zip/' + $expectedCommit), $activeArchive)
        } finally { $client.Dispose() }
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($activeArchive)
    try {
        $roots = @($zip.Entries | ForEach-Object { ($_.FullName -split '/')[0] } | Select-Object -Unique)
        if ($roots.Count -ne 1 -or $roots[0] -notmatch '^hdr-context-menu-([0-9a-f]{40})$') {
            throw 'The download is not a commit archive from hdr-context-menu.'
        }
        $commit = $Matches[1]
        if ($commit -ne $expectedCommit) { throw 'The downloaded archive does not match the detected GitHub commit.' }
        $stagePrefix = $stage.TrimEnd('\') + '\'
        foreach ($entry in $zip.Entries) {
            $entryPath = [IO.Path]::GetFullPath((Join-Path $stage $entry.FullName))
            if (-not $entryPath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $entry.FullName.Contains(':') -or $entry.FullName.Contains('\')) {
                throw 'The archive contains an invalid file path.'
            }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($activeArchive, $stage)
    $source = Join-Path $stage $roots[0]
    foreach ($required in @('Setup.ps1','HdrSdrMenu.ps1','Toggle-HdrSdr.vbs','HdrSdrMenu.ico','hdr-context-menu.nss')) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $required) -PathType Leaf)) {
            throw ('The package is incomplete: ' + $required)
        }
    }
    [IO.File]::WriteAllText((Join-Path $source 'package.commit'), $commit)
    if ($activeArchive -ne $archive) { Copy-Item -LiteralPath $activeArchive -Destination $archive -Force }
    if (Test-Path -LiteralPath $previous) {
        Assert-PackagePath $previous
        Remove-Item -LiteralPath $previous -Recurse -Force
    }
    if (Test-Path -LiteralPath $destination) {
        Assert-PackagePath $destination
        Move-Item -LiteralPath $destination -Destination $previous
    }
    try { Move-Item -LiteralPath $source -Destination $destination }
    catch {
        if ((Test-Path -LiteralPath $previous) -and -not (Test-Path -LiteralPath $destination)) {
            Assert-PackagePath $previous
            Move-Item -LiteralPath $previous -Destination $destination
        }
        throw
    }
    Write-Output ('Downloaded package ' + $commit + '. Choose Install in Ketarin to apply it.')
} finally {
    if (Test-Path -LiteralPath $stage) {
        Assert-PackagePath $stage
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
