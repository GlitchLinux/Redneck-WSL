# MiniDeb Self-Contained PowerShell Installer - Redneck WSL Edition
# Zero-dependency installer for fresh Windows 10/11 systems
# Author: GlitchLinux
# Version: 3.0

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Quiet,
    [string]$InstallPath = "C:\Program Files\Hidden-Linux",
    [int]$SSHPort = 2222,
    [string]$VMName = "minideb",
    [int]$VMMemory = 1024,
    [int]$VMCPUs = 2,
    [switch]$SkipSSHInstall
)

# Force execution policy for this session
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Requires Administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script requires Administrator privileges. Restarting as Administrator..." -ForegroundColor Yellow
    $arguments = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Uninstall) { $arguments += " -Uninstall" }
    if ($Quiet) { $arguments += " -Quiet" }
    if ($InstallPath -ne "C:\Program Files\Hidden-Linux") { $arguments += " -InstallPath `"$InstallPath`"" }
    if ($SSHPort -ne 2222) { $arguments += " -SSHPort $SSHPort" }
    if ($VMName -ne "minideb") { $arguments += " -VMName `"$VMName`"" }
    if ($SkipSSHInstall) { $arguments += " -SkipSSHInstall" }
    
    Start-Process PowerShell -Verb RunAs -ArgumentList $arguments
    exit
}

# Configuration - Single master.zip approach
$Config = @{
    InstallPath = $InstallPath
    # Single master download URL
    MasterUrl = "https://glitchlinux.wtf/master.zip"
    
    # Paths
    MasterZipPath = Join-Path $InstallPath "master.zip"
    MasterExtractPath = Join-Path $InstallPath "master"
    ISOPath = Join-Path $InstallPath "gLiTcH-Linux-KDE-v19.iso"
    QEMUPath = Join-Path $InstallPath "qemu"
    NSSMPath = Join-Path $InstallPath "nssm"
    ToolsPath = Join-Path $InstallPath "tools"
    SSHPath = Join-Path $InstallPath "tools\openssh"
    WgetDir = "C:\Program Files\wget"
    WgetPath = "C:\Program Files\wget\wget.exe"
    IconPath = Join-Path $InstallPath "minideb.ico"
    
    # Service config
    ServiceName = "MiniDebVM"
    SSHPort = $SSHPort
    VMName = $VMName
    VMMemory = $VMMemory
    VMCPUs = $VMCPUs
    
    # Logging
    LogFile = Join-Path $InstallPath "minideb.log"
    QEMULogFile = Join-Path $InstallPath "qemu.log"
    ErrorLogFile = Join-Path $InstallPath "error.log"
}

# Logging functions
function Write-Log {
    param(
        [string]$Message, 
        [string]$Level = "INFO",
        [switch]$NoConsole
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    if (-not $NoConsole -or $Level -eq "ERROR") {
        switch ($Level) {
            "ERROR" { Write-Host $logMessage -ForegroundColor Red }
            "WARN"  { Write-Host $logMessage -ForegroundColor Yellow }
            "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
            default { Write-Host $logMessage }
        }
    }
    
    # Ensure log directory exists
    $logDir = Split-Path $Config.LogFile -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { }
    }
    
    try { Add-Content -Path $Config.LogFile -Value $logMessage -ErrorAction SilentlyContinue } catch { }
}

function Show-Progress {
    param([string]$Activity, [string]$Status, [int]$PercentComplete)
    if (-not $Quiet) {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
    }
}

# Network connectivity test
function Test-InternetConnection {
    $testUrls = @(
        "https://www.google.com",
        "https://github.com",
        "https://www.microsoft.com"
    )
    
    foreach ($url in $testUrls) {
        try {
            $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 5 -UseBasicParsing
            if ($response.StatusCode -eq 200) {
                return $true
            }
        }
        catch {
            continue
        }
    }
    return $false
}

# Robust wget download with multiple fallbacks
function Install-Wget {
    if (Test-Path $Config.WgetPath) {
        Write-Log "Wget already available at $($Config.WgetPath)" "SUCCESS"
        return $true
    }
    
    try {
        Write-Log "Installing wget for fast downloads..."
        Show-Progress -Activity "Installing Wget" -Status "Creating directory..." -PercentComplete 10
        
        # Create wget directory
        if (-not (Test-Path $Config.WgetDir)) {
            New-Item -ItemType Directory -Path $Config.WgetDir -Force | Out-Null
        }
        
        $wgetUrl = "https://eternallybored.org/misc/wget/1.21.4/64/wget.exe"
        
        # Method 1: Try curl first (fastest)
        Show-Progress -Activity "Installing Wget" -Status "Downloading with curl..." -PercentComplete 25
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            Write-Log "Attempting wget download with curl..."
            $curlArgs = @(
                "-L", "-o", "`"$($Config.WgetPath)`"", 
                "--connect-timeout", "30", 
                "--max-time", "300",
                "`"$wgetUrl`""
            )
            
            $process = Start-Process -FilePath "curl.exe" -ArgumentList $curlArgs -NoNewWindow -Wait -PassThru
            
            if ($process.ExitCode -eq 0 -and (Test-Path $Config.WgetPath)) {
                $fileSize = [math]::Round((Get-Item $Config.WgetPath).Length / 1KB, 2)
                Write-Log "Wget downloaded successfully with curl: $($Config.WgetPath) ($fileSize KB)" "SUCCESS"
                Show-Progress -Activity "Installing Wget" -Status "Complete" -PercentComplete 100
                return $true
            } else {
                Write-Log "Curl download failed, trying PowerShell..." "WARN"
            }
        }
        
        # Method 2: Invoke-WebRequest
        Show-Progress -Activity "Installing Wget" -Status "Downloading with PowerShell..." -PercentComplete 50
        try {
            Write-Log "Attempting wget download with Invoke-WebRequest..."
            Invoke-WebRequest -Uri $wgetUrl -OutFile $Config.WgetPath -UseBasicParsing -TimeoutSec 300
            
            if (Test-Path $Config.WgetPath) {
                $fileSize = [math]::Round((Get-Item $Config.WgetPath).Length / 1KB, 2)
                Write-Log "Wget downloaded successfully with PowerShell: $($Config.WgetPath) ($fileSize KB)" "SUCCESS"
                Show-Progress -Activity "Installing Wget" -Status "Complete" -PercentComplete 100
                return $true
            }
        }
        catch {
            Write-Log "PowerShell download failed: $($_.Exception.Message)" "WARN"
        }
        
        # Method 3: Browser emulated download with WebClient
        Show-Progress -Activity "Installing Wget" -Status "Downloading with browser emulation..." -PercentComplete 75
        try {
            Write-Log "Attempting wget download with browser emulation..."
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36")
            $webClient.Headers.Add("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8")
            $webClient.Headers.Add("Accept-Language", "en-US,en;q=0.5")
            $webClient.Headers.Add("Accept-Encoding", "gzip, deflate")
            $webClient.Headers.Add("Connection", "keep-alive")
            $webClient.Headers.Add("Upgrade-Insecure-Requests", "1")
            
            $webClient.DownloadFile($wgetUrl, $Config.WgetPath)
            $webClient.Dispose()
            
            if (Test-Path $Config.WgetPath) {
                $fileSize = [math]::Round((Get-Item $Config.WgetPath).Length / 1KB, 2)
                Write-Log "Wget downloaded successfully with browser emulation: $($Config.WgetPath) ($fileSize KB)" "SUCCESS"
                Show-Progress -Activity "Installing Wget" -Status "Complete" -PercentComplete 100
                return $true
            }
        }
        catch {
            Write-Log "Browser emulation download failed: $($_.Exception.Message)" "ERROR"
        }
        
        Write-Log "All wget download methods failed" "ERROR"
        return $false
        
    }
    catch {
        Write-Log "Failed to install wget: $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        if (-not $Quiet) {
            Write-Progress -Activity "Installing Wget" -Completed
        }
    }
}

# Download and extract master.zip with all components
function Install-MasterComponents {
    try {
        Write-Log "Downloading master.zip with all components..."
        
        # Ensure wget is available first
        if (-not (Install-Wget)) {
            Write-Log "Cannot proceed without wget. Installation failed." "ERROR"
            return $false
        }
        
        # Download master.zip using wget with the classic reliable command
        if (-not (Test-Path $Config.MasterZipPath)) {
            Show-Progress -Activity "Downloading Components" -Status "Downloading master.zip with wget..." -PercentComplete 0
            
            Write-Log "Using classic wget command for master.zip download..."
            Write-Log "Executing: .\wget.exe $($Config.MasterUrl)"
            
            # Change to wget directory and run the classic command
            $currentDir = Get-Location
            Set-Location (Split-Path $Config.WgetPath -Parent)
            
            try {
                # Classic wget command - simple and reliable
                $process = Start-Process -FilePath ".\wget.exe" -ArgumentList $Config.MasterUrl -NoNewWindow -Wait -PassThru
                
                # Return to original directory
                Set-Location $currentDir
                
                if ($process.ExitCode -eq 0) {
                    # wget downloaded to current directory, move it to target location
                    $downloadedFile = Join-Path (Split-Path $Config.WgetPath -Parent) "master.zip"
                    if (Test-Path $downloadedFile) {
                        Move-Item $downloadedFile $Config.MasterZipPath -Force
                        $fileSize = [math]::Round((Get-Item $Config.MasterZipPath).Length / 1MB, 2)
                        Write-Log "Master.zip downloaded successfully with wget: $($Config.MasterZipPath) ($fileSize MB)" "SUCCESS"
                    } else {
                        Write-Log "Wget completed but file not found at expected location" "ERROR"
                        return $false
                    }
                } else {
                    Set-Location $currentDir
                    Write-Log "Wget download failed with exit code $($process.ExitCode)" "ERROR"
                    return $false
                }
            }
            catch {
                Set-Location $currentDir
                Write-Log "Wget execution failed: $($_.Exception.Message)" "ERROR"
                return $false
            }
        } else {
            Write-Log "Master.zip already exists, skipping download" "INFO"
        }
        
        # Extract master.zip (note: files are in master/ subdirectory)
        Show-Progress -Activity "Extracting Components" -Status "Extracting master.zip..." -PercentComplete 50
        
        # Remove existing extraction directory
        if (Test-Path $Config.MasterExtractPath) {
            Remove-Item $Config.MasterExtractPath -Recurse -Force
        }
        
        # Extract to a temporary location first
        $tempExtractPath = Join-Path $Config.InstallPath "temp_extract"
        if (Test-Path $tempExtractPath) {
            Remove-Item $tempExtractPath -Recurse -Force
        }
        
        # Use built-in PowerShell extraction
        Expand-Archive -Path $Config.MasterZipPath -DestinationPath $tempExtractPath -Force
        
        # The zip contains a "master" directory - move its contents up one level
        $masterSubDir = Join-Path $tempExtractPath "master"
        if (Test-Path $masterSubDir) {
            # Move the master subdirectory to our target location
            Move-Item $masterSubDir $Config.MasterExtractPath
            # Clean up temp directory
            Remove-Item $tempExtractPath -Recurse -Force
        } else {
            # Fallback: if no master subdirectory, use temp extract as is
            Move-Item $tempExtractPath $Config.MasterExtractPath
        }
        
        if (-not (Test-Path $Config.MasterExtractPath)) {
            Write-Log "Master extraction failed - directory not found" "ERROR"
            return $false
        }
        
        Write-Log "Master.zip extracted successfully (files extracted from master/ subdirectory)" "SUCCESS"
        
        # Copy components to their target locations
        Show-Progress -Activity "Installing Components" -Status "Installing components..." -PercentComplete 75
        
        # Copy files from extracted master/ to their proper locations
        $sourceFiles = @{
            "gLiTcH-Linux-KDE-v19.iso" = $Config.ISOPath
            "qemu" = $Config.QEMUPath
            "nssm-2.24" = $Config.NSSMPath
            "OpenSSH-Win64" = $Config.SSHPath
            "minideb.ico" = $Config.IconPath
            "wget.exe" = $Config.WgetPath
        }
        
        foreach ($source in $sourceFiles.Keys) {
            $sourcePath = Join-Path $Config.MasterExtractPath $source
            $targetPath = $sourceFiles[$source]
            
            if (Test-Path $sourcePath) {
                # Ensure target directory exists
                $targetDir = Split-Path $targetPath -Parent
                if (-not (Test-Path $targetDir)) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }
                
                # Copy file or directory
                if (Test-Path $sourcePath -PathType Container) {
                    Copy-Item $sourcePath $targetPath -Recurse -Force
                } else {
                    Copy-Item $sourcePath $targetPath -Force
                }
                
                Write-Log "Copied $source to $targetPath" "SUCCESS"
            } else {
                Write-Log "Source file not found: $sourcePath" "WARN"
            }
        }
        
        # Cleanup
        Remove-Item $Config.MasterZipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $Config.MasterExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        
        Show-Progress -Activity "Installing Components" -Status "Complete" -PercentComplete 100
        Write-Log "All components installed successfully from master.zip" "SUCCESS"
        return $true
        
    }
    catch {
        Write-Log "Failed to install master components: $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        if (-not $Quiet) {
            Write-Progress -Activity "Installing Components" -Completed
            Write-Progress -Activity "Extracting Components" -Completed
        }
    }
}

# Check and install OpenSSH client
function Ensure-SSHClient {
    if ($SkipSSHInstall) {
        Write-Log "Skipping SSH client installation as requested" "INFO"
        return $true
    }
    
    # Check if SSH is already available in PATH
    if (Get-Command ssh.exe -ErrorAction SilentlyContinue) {
        Write-Log "SSH client already available in PATH" "SUCCESS"
        return $true
    }
    
    # Check if our portable SSH is installed
    $portableSSH = Join-Path $Config.SSHPath "ssh.exe"
    if (Test-Path $portableSSH) {
        Write-Log "Portable SSH client found at $portableSSH" "SUCCESS"
        # Add to PATH for this session
        $env:PATH = "$($Config.SSHPath);$env:PATH"
        return $true
    }
    
    Write-Log "SSH client not found. Checking Windows features..." "INFO"
    
    # Try to enable Windows OpenSSH feature (Windows 10 1809+)
    try {
        $sshFeature = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Client*"
        if ($sshFeature -and $sshFeature.State -ne "Installed") {
            Write-Log "Installing Windows OpenSSH client feature..." "INFO"
            Add-WindowsCapability -Online -Name $sshFeature.Name
            
            # Check if it worked
            if (Get-Command ssh.exe -ErrorAction SilentlyContinue) {
                Write-Log "Windows OpenSSH client installed successfully" "SUCCESS"
                return $true
            }
        }
    }
    catch {
        Write-Log "Failed to install Windows OpenSSH feature: $($_.Exception.Message)" "WARN"
    }
    
    # If we have portable SSH from master.zip, add it to PATH
    if (Test-Path $portableSSH) {
        # Create permanent PATH entry
        $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
        if (-not $currentPath.Contains($Config.SSHPath)) {
            [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$($Config.SSHPath)", "Machine")
        }
        
        Write-Log "Portable OpenSSH configured successfully" "SUCCESS"
        return $true
    }
    
    Write-Log "SSH client not available. CLI commands will have limited functionality." "WARN"
    return $false
}

# Enhanced SSH connectivity testing
function Test-SSHConnection {
    param([int]$Port = $Config.SSHPort, [int]$TimeoutSeconds = 30)
    
    Write-Log "Testing SSH connection on port $Port"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $result = $tcpClient.BeginConnect("127.0.0.1", $Port, $null, $null)
            $success = $result.AsyncWaitHandle.WaitOne(1000)
            $tcpClient.Close()
            
            if ($success) {
                Write-Log "SSH port is responsive" "SUCCESS"
                return $true
            }
        }
        catch {
            # Connection failed, continue trying
        }
        
        Start-Sleep -Seconds 2
    }
    
    Write-Log "SSH connection test timed out after $TimeoutSeconds seconds" "WARN"
    return $false
}

# Install NSSM service with better error handling
function Install-NSSMService {
    try {
        Write-Log "Installing NSSM service for MiniDeb VM"
        Show-Progress -Activity "Installing Service" -Status "Configuring NSSM..." -PercentComplete 0
        
        $nssmExe = Join-Path $Config.NSSMPath "win64\nssm.exe"
        if (-not (Test-Path $nssmExe)) {
            $nssmExe = Join-Path $Config.NSSMPath "win32\nssm.exe"
        }
        
        if (-not (Test-Path $nssmExe)) {
            Write-Log "NSSM executable not found at expected locations" "ERROR"
            return $false
        }
        
        # Remove existing service if it exists
        & $nssmExe stop $Config.ServiceName 2>$null
        & $nssmExe remove $Config.ServiceName confirm 2>$null
        
        Show-Progress -Activity "Installing Service" -Status "Installing service..." -PercentComplete 25
        
        # Build QEMU command
        $qemuExe = Join-Path $Config.QEMUPath "qemu-system-x86_64.exe"
        $qemuArgs = @(
            "-m", $Config.VMMemory,
            "-smp", $Config.VMCPUs,
            "-cdrom", "`"$($Config.ISOPath)`"",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:$($Config.SSHPort)-:22,restrict=on",
            "-device", "e1000,netdev=net0",
            "-nographic",
            "-serial", "file:`"$($Config.QEMULogFile)`"",
            "-machine", "type=pc,accel=tcg"  # Use TCG (software) acceleration for maximum compatibility
        ) -join " "
        
        # Install and configure service
        $result = & $nssmExe install $Config.ServiceName "`"$qemuExe`""
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to install NSSM service" "ERROR"
            return $false
        }
        
        & $nssmExe set $Config.ServiceName Parameters $qemuArgs
        & $nssmExe set $Config.ServiceName DisplayName "MiniDeb Virtual Machine"
        & $nssmExe set $Config.ServiceName Description "Redneck WSL - Seamless Linux Integration"
        & $nssmExe set $Config.ServiceName Start SERVICE_AUTO_START
        & $nssmExe set $Config.ServiceName AppStdout "`"$($Config.QEMULogFile)`""
        & $nssmExe set $Config.ServiceName AppStderr "`"$($Config.ErrorLogFile)`""
        & $nssmExe set $Config.ServiceName AppRotateFiles 1
        & $nssmExe set $Config.ServiceName AppRotateOnline 1
        & $nssmExe set $Config.ServiceName AppRotateBytes 1048576  # 1MB
        
        Show-Progress -Activity "Installing Service" -Status "Complete" -PercentComplete 100
        Write-Log "NSSM service installed successfully" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to install NSSM service: $($_.Exception.Message)" "ERROR"
        return $false
    }
    finally {
        if (-not $Quiet) {
            Write-Progress -Activity "Installing Service" -Completed
        }
    }
}

# Enhanced CLI tools with SSH fallback
function Install-CLITools {
    Write-Log "Installing CLI tools"
    
    $sshAvailable = (Get-Command ssh.exe -ErrorAction SilentlyContinue) -ne $null
    $sshCommand = if ($sshAvailable) { "ssh x@localhost -p $($Config.SSHPort)" } else { "echo SSH not available - use QEMU monitor or install SSH client" }
    
    $cliScript = @"
@echo off
setlocal enabledelayedexpansion

rem MiniDeb CLI Tool - Redneck WSL Edition
rem Usage: minideb [command]

if "%1"=="" goto connect
if /i "%1"=="connect" goto connect
if /i "%1"=="start" goto start
if /i "%1"=="stop" goto stop
if /i "%1"=="restart" goto restart
if /i "%1"=="status" goto status
if /i "%1"=="logs" goto logs
if /i "%1"=="help" goto help

echo Unknown command: %1
echo Use 'minideb help' for available commands.
goto :eof

:connect
echo Connecting to MiniDeb Linux...
$(if ($sshAvailable) { @"
echo Use Ctrl+C to disconnect
$sshCommand
"@ } else { @"
echo SSH client not available. Please install OpenSSH client or use direct VM access.
echo You can install OpenSSH with: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
echo Or run the installer again without -SkipSSHInstall
"@ })
goto :eof

:start
echo Starting MiniDeb VM...
net start "$($Config.ServiceName)" >nul 2>&1
if !errorlevel! equ 0 (
    echo MiniDeb VM started successfully.
    echo Waiting for VM to boot...$(if ($sshAvailable) { " and SSH to become available..." } else { "" })
    
    $(if ($sshAvailable) { @"
    rem Wait for SSH to be ready
    set /a attempts=0
    :wait_ssh
    ssh -o ConnectTimeout=1 -o BatchMode=yes -o StrictHostKeyChecking=no x@localhost -p $($Config.SSHPort) exit 2>nul
    if !errorlevel! equ 0 (
        echo MiniDeb is ready! Use 'minideb' to connect.
        goto :eof
    )
    
    set /a attempts+=1
    if !attempts! lss 30 (
        timeout /t 2 /nobreak >nul
        goto :wait_ssh
    )
    
    echo Warning: SSH not responding after 60 seconds. VM may still be booting.
    echo Try 'minideb status' to check or wait a bit longer.
"@ } else { @"
    timeout /t 10 /nobreak >nul
    echo MiniDeb VM should be booting. Check logs with 'minideb logs'
"@ })
) else (
    echo Failed to start MiniDeb VM. Check 'minideb status' for details.
)
goto :eof

:stop
echo Stopping MiniDeb VM...
net stop "$($Config.ServiceName)" >nul 2>&1
if !errorlevel! equ 0 (
    echo MiniDeb VM stopped successfully.
) else (
    echo Failed to stop MiniDeb VM or it was already stopped.
)
goto :eof

:restart
echo Restarting MiniDeb VM...
net stop "$($Config.ServiceName)" >nul 2>&1
timeout /t 3 /nobreak >nul
net start "$($Config.ServiceName)" >nul 2>&1
if !errorlevel! equ 0 (
    echo MiniDeb VM restarted successfully.
    $(if ($sshAvailable) { @"
    echo Waiting for SSH to become available...
    
    rem Wait for SSH to be ready
    set /a attempts=0
    :wait_ssh_restart
    ssh -o ConnectTimeout=1 -o BatchMode=yes -o StrictHostKeyChecking=no x@localhost -p $($Config.SSHPort) exit 2>nul
    if !errorlevel! equ 0 (
        echo MiniDeb is ready! Use 'minideb' to connect.
        goto :eof
    )
    
    set /a attempts+=1
    if !attempts! lss 30 (
        timeout /t 2 /nobreak >nul
        goto :wait_ssh_restart
    )
    
    echo Warning: SSH not responding after 60 seconds. VM may still be booting.
"@ } else { @"
    echo VM restarted. Check status with 'minideb status' or logs with 'minideb logs'
"@ })
) else (
    echo Failed to restart MiniDeb VM.
)
goto :eof

:status
echo MiniDeb VM Status:
echo ==================
sc query "$($Config.ServiceName)" | find "STATE" 2>nul
if !errorlevel! equ 0 (
    sc query "$($Config.ServiceName)" | find "RUNNING" >nul 2>&1
    if !errorlevel! equ 0 (
        echo Service Status: RUNNING
        
        $(if ($sshAvailable) { @"
        rem Test SSH connectivity
        ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no x@localhost -p $($Config.SSHPort) exit 2>nul
        if !errorlevel! equ 0 (
            echo SSH Status: ACCESSIBLE
            echo Ready to use! Run 'minideb' to connect.
        ) else (
            echo SSH Status: NOT READY ^(VM may still be booting^)
        )
"@ } else { @"
        echo SSH Status: NOT AVAILABLE ^(SSH client not installed^)
        echo Note: Install OpenSSH client for full functionality
"@ })
    ) else (
        echo Service Status: STOPPED
        echo SSH Status: NOT AVAILABLE
    )
) else (
    echo Service Status: NOT INSTALLED
    echo Run the installer to set up MiniDeb.
)
echo.
echo Installation Path: $($Config.InstallPath)
echo SSH Port: $($Config.SSHPort)$(if (-not $sshAvailable) { " (SSH client not available)" } else { "" })
goto :eof

:logs
echo Opening MiniDeb logs...
if exist "$($Config.QEMULogFile)" (
    echo QEMU Log:
    echo =========
    type "$($Config.QEMULogFile)"
) else (
    echo No QEMU log file found.
)
echo.
if exist "$($Config.ErrorLogFile)" (
    echo Error Log:
    echo ==========
    type "$($Config.ErrorLogFile)"
) else (
    echo No error log file found.
)
goto :eof

:help
echo MiniDeb - Redneck WSL Edition
echo =============================
echo Usage: minideb [command]
echo.
echo Commands:
echo   minideb          Connect to Linux$(if (-not $sshAvailable) { " (requires SSH client)" } else { " via SSH (default)" })
echo   minideb connect  Connect to Linux$(if (-not $sshAvailable) { " (requires SSH client)" } else { " via SSH" })
echo   minideb start    Start the MiniDeb VM
echo   minideb stop     Stop the MiniDeb VM
echo   minideb restart  Restart the MiniDeb VM
echo   minideb status   Show VM and SSH status
echo   minideb logs     Show VM logs
echo   minideb help     Show this help
echo.
echo Examples:
echo   minideb                 # Connect to Linux
echo   minideb start           # Start the VM
echo   minideb status          # Check if everything is running
echo.
echo SSH Details:
echo   Host: localhost
echo   Port: $($Config.SSHPort)
echo   User: x
$(if (-not $sshAvailable) { @"
echo.
echo Note: SSH client not detected. To install:
echo   Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
echo   Or re-run installer without -SkipSSHInstall
"@ })
echo.
goto :eof
"@

    $cliPath = Join-Path $env:SystemRoot "System32\minideb.bat"
    try {
        Set-Content -Path $cliPath -Value $cliScript -Encoding ASCII
        Write-Log "CLI tool installed successfully at $cliPath" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to install CLI tool: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# System tray with dependency checking
function Install-TrayApplication {
    Write-Log "Installing system tray application"
    
    # Check if Windows Forms is available
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        Write-Log "Windows Forms not available. Skipping tray application." "WARN"
        return $true  # Don't fail the entire installation
    }
    
    $sshAvailable = (Get-Command ssh.exe -ErrorAction SilentlyContinue) -ne $null
    
    $trayScript = @"
# MiniDeb System Tray Application
# Redneck WSL Edition - Self-Contained

# Check for required assemblies
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}
catch {
    Write-Host "Windows Forms not available. Exiting tray application."
    exit 1
}

# Configuration
`$serviceName = "$($Config.ServiceName)"
`$sshPort = $($Config.SSHPort)
`$sshAvailable = `$(Get-Command ssh.exe -ErrorAction SilentlyContinue) -ne `$null

# Create the form (hidden)
`$form = New-Object System.Windows.Forms.Form
`$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
`$form.ShowInTaskbar = `$false
`$form.Visible = `$false

# Create context menu
`$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Menu items
if (`$sshAvailable) {
    `$connectItem = `$contextMenu.Items.Add("Connect to Linux")
    `$connectItem.Font = New-Object System.Drawing.Font(`$connectItem.Font, [System.Drawing.FontStyle]::Bold)
    `$contextMenu.Items.Add("-")
} else {
    `$noSSHItem = `$contextMenu.Items.Add("SSH Not Available")
    `$noSSHItem.Enabled = `$false
    `$contextMenu.Items.Add("-")
}

`$startItem = `$contextMenu.Items.Add("Start MiniDeb")
`$stopItem = `$contextMenu.Items.Add("Stop MiniDeb")
`$restartItem = `$contextMenu.Items.Add("Restart MiniDeb")
`$contextMenu.Items.Add("-")
`$statusItem = `$contextMenu.Items.Add("Status")
`$logsItem = `$contextMenu.Items.Add("View Logs")
`$contextMenu.Items.Add("-")
`$exitItem = `$contextMenu.Items.Add("Exit")

# Create tray icon
`$trayIcon = New-Object System.Windows.Forms.NotifyIcon
`$trayIcon.ContextMenuStrip = `$contextMenu
`$trayIcon.Visible = `$true

# Load custom icon if available
`$iconPath = "$($Config.IconPath)"
if (Test-Path `$iconPath) {
    try {
        `$trayIcon.Icon = New-Object System.Drawing.Icon(`$iconPath)
    }
    catch {
        `$trayIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
} else {
    `$trayIcon.Icon = [System.Drawing.SystemIcons]::Application
}

# Function to update tray icon status
function Update-TrayIcon {
    try {
        `$service = Get-Service -Name `$serviceName -ErrorAction SilentlyContinue
        if (`$service -and `$service.Status -eq "Running") {
            if (`$sshAvailable) {
                # Test SSH connectivity
                `$tcpClient = New-Object System.Net.Sockets.TcpClient
                try {
                    `$result = `$tcpClient.BeginConnect("127.0.0.1", `$sshPort, `$null, `$null)
                    `$success = `$result.AsyncWaitHandle.WaitOne(1000)
                    `$tcpClient.Close()
                    
                    if (`$success) {
                        `$trayIcon.Text = "MiniDeb - Running (SSH Ready)"
                        `$startItem.Enabled = `$false
                        `$stopItem.Enabled = `$true
                        `$restartItem.Enabled = `$true
                        if (`$connectItem) { `$connectItem.Enabled = `$true }
                    } else {
                        `$trayIcon.Text = "MiniDeb - Starting (SSH Not Ready)"
                        `$startItem.Enabled = `$false
                        `$stopItem.Enabled = `$true
                        `$restartItem.Enabled = `$true
                        if (`$connectItem) { `$connectItem.Enabled = `$false }
                    }
                }
                catch {
                    `$trayIcon.Text = "MiniDeb - Running (SSH Unknown)"
                    `$startItem.Enabled = `$false
                    `$stopItem.Enabled = `$true
                    `$restartItem.Enabled = `$true
                    if (`$connectItem) { `$connectItem.Enabled = `$false }
                }
            } else {
                `$trayIcon.Text = "MiniDeb - Running (No SSH)"
                `$startItem.Enabled = `$false
                `$stopItem.Enabled = `$true
                `$restartItem.Enabled = `$true
            }
        } else {
            `$trayIcon.Text = "MiniDeb - Stopped"
            `$startItem.Enabled = `$true
            `$stopItem.Enabled = `$false
            `$restartItem.Enabled = `$false
            if (`$connectItem) { `$connectItem.Enabled = `$false }
        }
    }
    catch {
        `$trayIcon.Text = "MiniDeb - Error"
        `$startItem.Enabled = `$true
        `$stopItem.Enabled = `$true
        `$restartItem.Enabled = `$true
        if (`$connectItem) { `$connectItem.Enabled = `$false }
    }
}

# Event handlers
if (`$connectItem) {
    `$connectItem.Add_Click({
        if (`$sshAvailable) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c minideb connect"
        }
    })
}

`$startItem.Add_Click({
    try {
        Start-Service -Name `$serviceName
        `$trayIcon.ShowBalloonTip(3000, "MiniDeb", "Starting VM...", [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep 2
        Update-TrayIcon
    }
    catch {
        `$trayIcon.ShowBalloonTip(5000, "MiniDeb Error", "Failed to start VM: `$(`$_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Error)
    }
})

`$stopItem.Add_Click({
    try {
        Stop-Service -Name `$serviceName
        `$trayIcon.ShowBalloonTip(3000, "MiniDeb", "VM stopped", [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep 2
        Update-TrayIcon
    }
    catch {
        `$trayIcon.ShowBalloonTip(5000, "MiniDeb Error", "Failed to stop VM: `$(`$_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Error)
    }
})

`$restartItem.Add_Click({
    try {
        Stop-Service -Name `$serviceName
        Start-Sleep 3
        Start-Service -Name `$serviceName
        `$trayIcon.ShowBalloonTip(3000, "MiniDeb", "VM restarted", [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep 2
        Update-TrayIcon
    }
    catch {
        `$trayIcon.ShowBalloonTip(5000, "MiniDeb Error", "Failed to restart VM: `$(`$_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Error)
    }
})

`$statusItem.Add_Click({
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c minideb status & pause"
})

`$logsItem.Add_Click({
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c minideb logs & pause"
})

`$exitItem.Add_Click({
    `$trayIcon.Visible = `$false
    `$form.Close()
    [System.Windows.Forms.Application]::Exit()
})

# Double-click behavior
`$trayIcon.Add_DoubleClick({
    if (`$sshAvailable -and `$connectItem -and `$connectItem.Enabled) {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c minideb connect"
    } else {
        if (`$sshAvailable) {
            `$trayIcon.ShowBalloonTip(3000, "MiniDeb", "VM is not ready. Please wait or start it manually.", [System.Windows.Forms.ToolTipIcon]::Warning)
        } else {
            `$trayIcon.ShowBalloonTip(3000, "MiniDeb", "SSH client not available. Install OpenSSH for full functionality.", [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
})

# Update timer
`$timer = New-Object System.Windows.Forms.Timer
`$timer.Interval = 5000  # 5 seconds
`$timer.Add_Tick({ Update-TrayIcon })
`$timer.Start()

# Initial update
Update-TrayIcon

# Show startup notification
if (`$sshAvailable) {
    `$trayIcon.ShowBalloonTip(3000, "MiniDeb", "Redneck WSL tray application started", [System.Windows.Forms.ToolTipIcon]::Info)
} else {
    `$trayIcon.ShowBalloonTip(5000, "MiniDeb", "Tray application started (SSH not available)", [System.Windows.Forms.ToolTipIcon]::Warning)
}

# Keep the application running
`$form.Add_Load({ `$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
[System.Windows.Forms.Application]::Run(`$form)
"@

    $trayPath = Join-Path $Config.InstallPath "minideb-tray.ps1"
    try {
        Set-Content -Path $trayPath -Value $trayScript -Encoding UTF8
        
        # Create startup shortcut
        $startupPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
        if (-not (Test-Path $startupPath)) {
            New-Item -ItemType Directory -Path $startupPath -Force | Out-Null
        }
        
        $startupScript = Join-Path $startupPath "MiniDeb-Tray.bat"
        $startupContent = @"
@echo off
cd /d "$($Config.InstallPath)"
powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "$trayPath"
"@
        Set-Content -Path $startupScript -Value $startupContent -Encoding ASCII
        
        Write-Log "Tray application installed successfully" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to install tray application: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# System requirements checking with dependency installation
function Test-SystemRequirements {
    Write-Log "Checking system requirements and dependencies"
    
    $issues = @()
    
    # Check PowerShell version
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -lt 3) {
        $issues += "PowerShell version too old: $($psVersion.ToString()). Minimum: 3.0"
    }
    
    # Check .NET Framework version
    try {
        $netVersion = [System.Environment]::Version
        if ($netVersion.Major -lt 4) {
            $issues += ".NET Framework version too old. Minimum: 4.0"
        }
    }
    catch {
        $issues += "Unable to determine .NET Framework version"
    }
    
    # Check available RAM
    $totalRAM = (Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1GB
    if ($totalRAM -lt 3) {
        $issues += "Low system RAM: $([math]::Round($totalRAM, 2))GB. Minimum: 3GB, Recommended: 4GB+"
    }
    
    # Check available disk space
    $installDrive = Split-Path $Config.InstallPath -Qualifier
    $freeSpace = (Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $installDrive }).FreeSpace / 1GB
    if ($freeSpace -lt 3) {
        $issues += "Low disk space on $installDrive $([math]::Round($freeSpace, 2))GB free. Minimum: 3GB, Recommended: 5GB+"
    }
    
    # Check Windows version
    $winVersion = [System.Environment]::OSVersion.Version
    if ($winVersion.Major -lt 6 -or ($winVersion.Major -eq 6 -and $winVersion.Minor -lt 1)) {
        $issues += "Windows version too old: $($winVersion.ToString()). Minimum: Windows 7/2008 R2"
    }
    
    # Check virtualization support
    try {
        $cpu = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
        if (-not $cpu.VirtualizationFirmwareEnabled) {
            Write-Log "Hardware virtualization not enabled in BIOS. Performance will be slower." "WARN"
        }
    }
    catch {
        Write-Log "Unable to check virtualization support" "WARN"
    }
    
    # Check Windows services
    $requiredServices = @("BITS", "Winmgmt", "EventLog")
    foreach ($service in $requiredServices) {
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne "Running") {
            Write-Log "Required service '$service' not running" "WARN"
        }
    }
    
    if ($issues.Count -gt 0) {
        Write-Log "System requirement issues found:" "WARN"
        foreach ($issue in $issues) {
            Write-Log "  - $issue" "WARN"
        }
        
        # Check if issues are fatal
        $fatalIssues = $issues | Where-Object { $_ -like "*too old*" -or $_ -like "*Minimum*" }
        if ($fatalIssues.Count -gt 0) {
            Write-Log "Fatal compatibility issues detected. Installation may fail." "ERROR"
            return $false
        } else {
            Write-Log "Issues found but installation can continue with reduced functionality." "WARN"
        }
    } else {
        Write-Log "System requirements check passed" "SUCCESS"
    }
    
    return $true
}

# Enhanced uninstallation with better cleanup
function Uninstall-MiniDeb {
    Write-Log "Starting MiniDeb uninstallation" "INFO"
    
    $uninstallErrors = @()
    
    try {
        # Stop and remove service
        $nssmExe = $null
        if (Test-Path (Join-Path $Config.NSSMPath "win64\nssm.exe")) {
            $nssmExe = Join-Path $Config.NSSMPath "win64\nssm.exe"
        } elseif (Test-Path (Join-Path $Config.NSSMPath "win32\nssm.exe")) {
            $nssmExe = Join-Path $Config.NSSMPath "win32\nssm.exe"
        }
        
        if ($nssmExe -and (Test-Path $nssmExe)) {
            Write-Log "Stopping and removing NSSM service"
            & $nssmExe stop $Config.ServiceName 2>$null
            & $nssmExe remove $Config.ServiceName confirm 2>$null
        } else {
            # Fallback to sc.exe and net.exe
            Write-Log "Using system tools to remove service"
            net stop $Config.ServiceName 2>$null
            sc.exe delete $Config.ServiceName 2>$null
        }
        
        # Kill any remaining QEMU processes
        Get-Process -Name "qemu-system-x86_64" -ErrorAction SilentlyContinue | Stop-Process -Force
        
        Write-Log "Service removed successfully" "SUCCESS"
    }
    catch {
        $uninstallErrors += "Service removal: $($_.Exception.Message)"
        Write-Log "Error removing service: $($_.Exception.Message)" "WARN"
    }
    
    try {
        # Remove CLI tools
        $cliPath = Join-Path $env:SystemRoot "System32\minideb.bat"
        if (Test-Path $cliPath) {
            Remove-Item $cliPath -Force
            Write-Log "CLI tool removed" "SUCCESS"
        }
    }
    catch {
        $uninstallErrors += "CLI tool removal: $($_.Exception.Message)"
        Write-Log "Error removing CLI tool: $($_.Exception.Message)" "WARN"
    }
    
    try {
        # Remove startup entries
        $startupPaths = @(
            (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\MiniDeb-Tray.bat"),
            (Join-Path $env:ALLUSERSPROFILE "Microsoft\Windows\Start Menu\Programs\Startup\MiniDeb-Tray.bat")
        )
        
        foreach ($startupPath in $startupPaths) {
            if (Test-Path $startupPath) {
                Remove-Item $startupPath -Force
                Write-Log "Startup entry removed: $startupPath" "SUCCESS"
            }
        }
    }
    catch {
        $uninstallErrors += "Startup entries removal: $($_.Exception.Message)"
        Write-Log "Error removing startup entries: $($_.Exception.Message)" "WARN"
    }
    
    try {
        # Stop tray application processes
        Get-Process -Name "powershell" | Where-Object { 
            $_.CommandLine -and $_.CommandLine.Contains("minideb-tray.ps1") 
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Error stopping tray application: $($_.Exception.Message)" "WARN"
    }
    
    try {
        # Clean up PATH if we added OpenSSH
        if (Test-Path $Config.SSHPath) {
            $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
            if ($currentPath.Contains($Config.SSHPath)) {
                $newPath = $currentPath.Replace(";$($Config.SSHPath)", "").Replace("$($Config.SSHPath);", "")
                [Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")
                Write-Log "Removed OpenSSH from PATH" "SUCCESS"
            }
        }
    }
    catch {
        $uninstallErrors += "PATH cleanup: $($_.Exception.Message)"
        Write-Log "Error cleaning PATH: $($_.Exception.Message)" "WARN"
    }
    
    try {
        # Remove installation directory (with retry)
        if (Test-Path $Config.InstallPath) {
            Write-Log "Removing installation directory: $($Config.InstallPath)"
            
            # First attempt
            try {
                Remove-Item $Config.InstallPath -Recurse -Force
                Write-Log "Installation directory removed" "SUCCESS"
            }
            catch {
                # Second attempt after a delay
                Start-Sleep 2
                Remove-Item $Config.InstallPath -Recurse -Force
                Write-Log "Installation directory removed (second attempt)" "SUCCESS"
            }
        }
    }
    catch {
        $uninstallErrors += "Directory removal: $($_.Exception.Message)"
        Write-Log "Error removing installation directory: $($_.Exception.Message)" "WARN"
        Write-Log "You may need to manually delete: $($Config.InstallPath)" "WARN"
    }
    
    # Final status
    if ($uninstallErrors.Count -eq 0) {
        Write-Log "MiniDeb uninstallation completed successfully" "SUCCESS"
        Write-Host "`nMiniDeb has been uninstalled successfully!" -ForegroundColor Green
    } else {
        Write-Log "MiniDeb uninstallation completed with errors" "WARN"
        Write-Host "`nMiniDeb uninstallation completed with some errors:" -ForegroundColor Yellow
        foreach ($error in $uninstallErrors) {
            Write-Host "  - $error" -ForegroundColor Yellow
        }
    }
    
    Write-Host "You may need to reboot to complete the removal." -ForegroundColor Gray
}

# Main installation function with master.zip approach
function Install-MiniDeb {
    Write-Log "Starting MiniDeb installation - Redneck WSL Edition" "INFO"
    
    # Check system requirements first
    if (-not (Test-SystemRequirements)) {
        Write-Log "System requirements not met. Installation aborted." "ERROR"
        return $false
    }
    
    # Check internet connection
    if (-not (Test-InternetConnection)) {
        Write-Log "No internet connection detected. Cannot download required files." "ERROR"
        Write-Host "Please check your internet connection and try again." -ForegroundColor Red
        return $false
    }
    
    # Create installation directory structure
    try {
        $directories = @($Config.InstallPath, $Config.ToolsPath)
        foreach ($dir in $directories) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-Log "Created directory: $dir" "SUCCESS"
            }
        }
    }
    catch {
        Write-Log "Failed to create installation directories: $($_.Exception.Message)" "ERROR"
        return $false
    }
    
    # Install wget first for fast downloads
    Write-Log "Installing wget for fast downloads..."
    if (-not (Install-Wget)) {
        Write-Log "Failed to install wget - falling back to slower methods" "WARN"
    }
    
    # Download and install all components from master.zip
    if (-not (Install-MasterComponents)) {
        Write-Log "Failed to install components from master.zip" "ERROR"
        return $false
    }
    
    # Setup SSH client
    Ensure-SSHClient | Out-Null
    
    # Verify critical files exist
    $qemuExe = Join-Path $Config.QEMUPath "qemu-system-x86_64.exe"
    if (-not (Test-Path $qemuExe)) {
        Write-Log "QEMU executable not found at: $qemuExe" "ERROR"
        return $false
    }
    
    if (-not (Test-Path $Config.ISOPath)) {
        Write-Log "ISO file not found at: $($Config.ISOPath)" "ERROR"
        return $false
    }
    
    # Install components
    $installSteps = @(
        @{ Name = "NSSM Service"; Function = { Install-NSSMService } },
        @{ Name = "CLI Tools"; Function = { Install-CLITools } },
        @{ Name = "Tray Application"; Function = { Install-TrayApplication } }
    )
    
    foreach ($step in $installSteps) {
        Write-Log "Installing $($step.Name)..."
        if (-not (& $step.Function)) {
            Write-Log "Failed to install $($step.Name)" "ERROR"
            return $false
        }
    }
    
    Write-Log "MiniDeb installation completed successfully!" "SUCCESS"
    return $true
}

# Main execution with comprehensive error handling
try {
    Write-Host "MiniDeb Self-Contained Installer - Redneck WSL Edition" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Log "Installer started with parameters:" "INFO"
    Write-Log "  Install Path: $($Config.InstallPath)" "INFO"
    Write-Log "  SSH Port: $($Config.SSHPort)" "INFO"
    Write-Log "  VM Name: $($Config.VMName)" "INFO"
    Write-Log "  VM Memory: $($Config.VMMemory)MB" "INFO"
    Write-Log "  VM CPUs: $($Config.VMCPUs)" "INFO"
    Write-Log "  Skip SSH Install: $SkipSSHInstall" "INFO"
    Write-Log "  PowerShell Version: $($PSVersionTable.PSVersion)" "INFO"
    Write-Log "  Windows Version: $([System.Environment]::OSVersion.VersionString)" "INFO"
    
    if ($Uninstall) {
        Write-Host "Starting uninstallation..." -ForegroundColor Yellow
        Uninstall-MiniDeb
    } else {
        Write-Host "Starting installation..." -ForegroundColor Green
        Write-Host "This installer is completely self-contained and will handle all dependencies." -ForegroundColor Gray
        Write-Host ""
        
        if (Install-MiniDeb) {
            Write-Host "`n" -NoNewline
            Write-Host "Installation completed successfully!" -ForegroundColor Green
            Write-Host ""
            Write-Host "Quick Start Guide:" -ForegroundColor Cyan
            Write-Host "=================" -ForegroundColor Cyan
            Write-Host "1. Starting the VM: " -NoNewline; Write-Host "minideb start" -ForegroundColor Yellow
            Write-Host "2. Connecting: " -NoNewline; Write-Host "minideb" -ForegroundColor Yellow
            Write-Host "3. Check status: " -NoNewline; Write-Host "minideb status" -ForegroundColor Yellow
            Write-Host "4. Stop VM: " -NoNewline; Write-Host "minideb stop" -ForegroundColor Yellow
            Write-Host "5. Help: " -NoNewline; Write-Host "minideb help" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Features:" -ForegroundColor Cyan
            Write-Host "- System tray icon shows VM status" -ForegroundColor White
            Write-Host "- VM auto-starts with Windows" -ForegroundColor White
            Write-Host "- SSH access on localhost:$($Config.SSHPort)" -ForegroundColor White
            
            $sshAvailable = (Get-Command ssh.exe -ErrorAction SilentlyContinue) -ne $null
            if (-not $sshAvailable) {
                Write-Host "- SSH client not available (limited functionality)" -ForegroundColor Yellow
                Write-Host "  Run: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" -ForegroundColor Gray
            }
            Write-Host ""
            
            # Start the service and tray app
            Write-Host "Starting MiniDeb VM..." -ForegroundColor Yellow
            try {
                Start-Service -Name $Config.ServiceName
                Write-Host "VM service started" -ForegroundColor Green
                
                # Start tray application
                $trayPath = Join-Path $Config.InstallPath "minideb-tray.ps1"
                Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$trayPath`"" -ErrorAction SilentlyContinue
                Write-Host "Tray application started" -ForegroundColor Green
                
                Write-Host ""
                if ($sshAvailable) {
                    Write-Host "Waiting for SSH to become available..." -ForegroundColor Yellow
                    if (Test-SSHConnection -TimeoutSeconds 60) {
                        Write-Host "SSH is ready!" -ForegroundColor Green
                        Write-Host ""
                        Write-Host "You can now use " -NoNewline; Write-Host "minideb" -ForegroundColor Yellow -NoNewline; Write-Host " to connect to your Linux environment!"
                    } else {
                        Write-Host "SSH not ready yet. The VM may still be booting." -ForegroundColor Yellow
                        Write-Host "Try " -NoNewline; Write-Host "minideb status" -ForegroundColor Yellow -NoNewline; Write-Host " in a few minutes."
                    }
                } else {
                    Write-Host "VM started. Since SSH is not available, use " -NoNewline; Write-Host "minideb logs" -ForegroundColor Yellow -NoNewline; Write-Host " to monitor."
                }
            }
            catch {
                Write-Host "VM started but there may be issues. Check " -NoNewline -ForegroundColor Yellow
                Write-Host "minideb status" -ForegroundColor Yellow -NoNewline
                Write-Host " for details." -ForegroundColor Yellow
            }
            
            Write-Host ""
            Write-Host "Check the system tray for the MiniDeb icon!" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Dependencies Installed:" -ForegroundColor Gray
            Write-Host "- NSSM (Service Manager): Success" -ForegroundColor Gray
            Write-Host "- QEMU Portable: Success" -ForegroundColor Gray
            Write-Host "- gLiTcH Linux ISO: Success" -ForegroundColor Gray
            if ($sshAvailable) {
                Write-Host "- SSH Client: Success" -ForegroundColor Gray
            } else {
                Write-Host "- SSH Client: Optional (not available)" -ForegroundColor Gray
            }
            
        } else {
            Write-Host "`nInstallation failed!" -ForegroundColor Red
            Write-Host "Check the log file for details: $($Config.LogFile)" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Common issues on fresh Windows installs:" -ForegroundColor Yellow
            Write-Host "- Execution policy restrictions (handled automatically)" -ForegroundColor Gray
            Write-Host "- Missing .NET Framework (install from Microsoft)" -ForegroundColor Gray
            Write-Host "- Network/firewall blocking downloads" -ForegroundColor Gray
            Write-Host "- Insufficient disk space or permissions" -ForegroundColor Gray
            exit 1
        }
    }
}
catch {
    Write-Log "Unexpected error in main execution: $($_.Exception.Message)" "ERROR"
    Write-Host "`nAn unexpected error occurred!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Check the log file: $($Config.LogFile)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "If this is a fresh Windows install, you may need:" -ForegroundColor Yellow
    Write-Host "- .NET Framework 4.0+ (usually included in Windows 10/11)" -ForegroundColor Gray
    Write-Host "- PowerShell 3.0+ (included in Windows 8+)" -ForegroundColor Gray
    Write-Host "- Administrator privileges (script should auto-elevate)" -ForegroundColor Gray
    exit 1
}

Write-Log "MiniDeb installer finished" "INFO"
Write-Host ""
Write-Host "Installation log saved to: $($Config.LogFile)" -ForegroundColor Gray

# Display final system information
Write-Host ""
Write-Host "System Information:" -ForegroundColor Gray
Write-Host "==================" -ForegroundColor Gray
Write-Host "Windows Version: $([System.Environment]::OSVersion.VersionString)" -ForegroundColor Gray
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host ".NET Framework: $([System.Environment]::Version)" -ForegroundColor Gray
Write-Host "Architecture: $($env:PROCESSOR_ARCHITECTURE)" -ForegroundColor Gray
Write-Host "Install Path: $($Config.InstallPath)" -ForegroundColor Gray

if (-not $Uninstall) {
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "1. Wait 30-60 seconds for the VM to fully boot" -ForegroundColor White
    Write-Host "2. Check the system tray for the MiniDeb icon" -ForegroundColor White  
    Write-Host "3. Run 'minideb status' to verify everything is working" -ForegroundColor White
    Write-Host "4. Run 'minideb' to connect to your Linux environment" -ForegroundColor White
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "- If SSH fails: Run 'minideb logs' to see boot messages" -ForegroundColor White
    Write-Host "- If VM won't start: Check Windows Event Viewer" -ForegroundColor White
    Write-Host "- For help: Run 'minideb help'" -ForegroundColor White
}

Write-Host ""
Write-Host "Installation complete! Success!" -ForegroundColor Green
