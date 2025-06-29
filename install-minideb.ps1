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
        
        # Download master.zip using wget with detailed progress
        if (-not (Test-Path $Config.MasterZipPath)) {
            Show-Progress -Activity "Downloading Components" -Status "Downloading master.zip with wget..." -PercentComplete 0
            
            Write-Log "Using wget for fast master.zip download with progress..."
            
            # Wget command with detailed progress
            $wgetArgs = @(
                "--progress=bar:force:noscroll",  # Detailed progress bar
                "--show-progress",                # Show progress info
                "--tries=3",                      # Retry 3 times
                "--timeout=60",                   # 60s timeout per chunk
                "--connect-timeout=30",           # 30s connection timeout
                "--read-timeout=60",              # 60s read timeout
                "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "-O", "`"$($Config.MasterZipPath)`"",  # Output file
                "`"$($Config.MasterUrl)`""             # URL
            )
            
            Write-Log "Executing: wget $($wgetArgs -join ' ')"
            
            # Run wget and capture output for progress monitoring
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = $Config.WgetPath
            $processInfo.Arguments = $wgetArgs -join " "
            $processInfo.UseShellExecute = $false
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.CreateNoWindow = $true
            
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            $process.Start() | Out-Null
            
            # Monitor wget progress
            while (-not $process.HasExited) {
                $output = $process.StandardOutput.ReadLine()
                $error = $process.StandardError.ReadLine()
                
                if ($output) {
                    Write-Host $output -ForegroundColor Cyan
                    # Parse progress if possible
                    if ($output -match "(\d+)%") {
                        $percent = [int]$matches[1]
                        Show-Progress -Activity "Downloading Components" -Status "Downloaded $percent%" -PercentComplete $percent
                    }
                }
                
                if ($error) {
                    Write-Host $error -ForegroundColor Yellow
                    # Also parse error stream for progress (wget outputs progress to stderr)
                    if ($error -match "(\d+)%") {
                        $percent = [int]$matches[1]
                        Show-Progress -Activity "Downloading Components" -Status "Downloaded $percent%" -PercentComplete $percent
                    }
                }
                
                Start-Sleep -Milliseconds 100
            }
            
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            $process.Dispose()
            
            if ($exitCode -eq 0 -and (Test-Path $Config.MasterZipPath)) {
                $fileSize = [math]::Round((Get-Item $Config.MasterZipPath).Length / 1MB, 2)
                Write-Log "Master.zip downloaded successfully with wget: $($Config.MasterZipPath) ($fileSize MB)" "SUCCESS"
            } else {
                Write-Log "Wget download failed with exit code $exitCode" "ERROR"
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
        Show-Pr