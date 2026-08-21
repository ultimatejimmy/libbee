param (
    [switch]$Watch
)

$PluginDir = "libbee.koplugin"
$WSLDest = "~/.config/koreader/plugins/libbee.koplugin"
$SyntaxScript = "tools/check_syntax.py"

# Probe for the squashfs-root location in WSL
$SquashPath = ""
$UserNameLower = $env:USERNAME.ToLower()
$ProbedPaths = @(
    "/home/jimmy/squashfs-root",
    "/home/$env:USERNAME/squashfs-root",
    "/home/$UserNameLower/squashfs-root",
    "/mnt/c/Users/$env:USERNAME/squashfs-root",
    "/mnt/c/Users/$UserNameLower/squashfs-root"
)
foreach ($path in $ProbedPaths) {
    $null = wsl test -d $path
    if ($LASTEXITCODE -eq 0) {
        $SquashPath = $path
        break
    }
}
if (-not $SquashPath) {
    $SquashPath = "/home/jimmy/squashfs-root"
}
Write-Host "Using KOReader installation path: $SquashPath" -ForegroundColor Yellow

function Run-Workflow {
    Write-Host "`n--- Starting Verification Workflow ---" -ForegroundColor Cyan
    
    # 1. Syntax Check
    Write-Host "Checking Lua syntax..." -NoNewline
    $syntaxResult = python $SyntaxScript $PluginDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host $syntaxResult
        return $false
    }
    Write-Host " PASSED" -ForegroundColor Green

    # 1.5 Translation Sync Check
    Write-Host "Checking translation sync..." -NoNewline
    $transResult = python tools/check_translations.py
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host $transResult
        return $false
    }
    Write-Host " PASSED" -ForegroundColor Green

    # 2. Unit Tests
    Write-Host "Running unit tests (WSL LuaJIT)..."
    wsl test -f "$SquashPath/usr/lib/koreader/luajit"
    if ($LASTEXITCODE -eq 0) {
        wsl env SQUASHFS_ROOT=$SquashPath "$SquashPath/usr/lib/koreader/luajit" tools/spec_runner.lua
    } else {
        wsl env SQUASHFS_ROOT=$SquashPath luajit tools/spec_runner.lua
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Tests FAILED. Aborting sync." -ForegroundColor Red
        return $false
    }
    Write-Host "Tests PASSED" -ForegroundColor Green

    # 3. Sync
    Write-Host "Syncing to WSL..." -NoNewline
    wsl mkdir -p (Split-Path $WSLDest -Parent)
    wsl rsync -rv --delete --exclude="libbee.log" --exclude="*.sdr/" "./$PluginDir/" "$WSLDest/"

    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }
    Write-Host " SUCCESS" -ForegroundColor Green

    # 4. Restart KOReader
    Write-Host "Restarting KOReader..." -ForegroundColor Cyan
    wsl pkill -9 -f koreader 2>$null
    wsl pkill -9 -f AppRun 2>$null
    Start-Sleep -Seconds 1

    # Define start command
    $DefaultCmd = "C:\Windows\System32\wsl.exe --exec dbus-launch --exit-with-session bash -c `"cd $SquashPath && ./AppRun`""
    $StartCmd = if ($env:KOREADER_START_CMD) { $env:KOREADER_START_CMD } else { $DefaultCmd }
    
    Write-Host "Starting KOReader: $StartCmd"
    # Use cmd /c start to ensure it's fully detached and quotes are preserved
    $cmdLine = "/c start `"`" $StartCmd"
    Start-Process cmd.exe -ArgumentList $cmdLine -WindowStyle Hidden

    Write-Host "`nReady!" -ForegroundColor Green
    return $true
}

if ($Watch) {
    Write-Host "Watching for changes in $PluginDir..." -ForegroundColor Magenta
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = (Get-Item "./$PluginDir").FullName
    $watcher.Filter = "*.lua"
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true

    $action = {
        Run-Workflow
    }

    Register-ObjectEvent $watcher "Changed" -Action $action
    Register-ObjectEvent $watcher "Created" -Action $action
    Register-ObjectEvent $watcher "Deleted" -Action $action
    Register-ObjectEvent $watcher "Renamed" -Action $action

    while ($true) { Start-Sleep -Seconds 1 }
} else {
    Run-Workflow
}
