<#
Project Singularity installer for Windows.

Sets up a FiveM server with Project Singularity as the monitor resource:
FXServer artifact, panel release, framework database, optional Apache
reverse proxy and a Windows service. The rest happens in the browser wizard.

Usage (elevated PowerShell):
    irm https://raw.githubusercontent.com/Sp3arHead/Project-Singularity-Dist/main/setup.ps1 | iex

With options:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Sp3arHead/Project-Singularity-Dist/main/setup.ps1))) --dir D:\FiveM --yes

Options: --dir <path>, --build <n>, --tag <tag>, --no-apache, --no-mariadb, --yes, --help

Everything this script creates is removed again if a step fails.
Passwords, keys and tokens are never written to the log file.
Compatible with Windows PowerShell 5.1.
#>

function Invoke-SingularityInstaller {
    param([string[]]$CliArgs)

    #Version 1 only flags unset variables; API responses may lack optional fields
    Set-StrictMode -Version 1
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    #MARK: Constants
    $DistRepo = 'Sp3arHead/Project-Singularity-Dist'
    $ReleaseAsset = 'monitor.zip'
    #GitHub API base of the release repository, overridable for mirrors and tests
    $DistApi = if ($env:SINGULARITY_DIST_API) { $env:SINGULARITY_DIST_API } else { "https://api.github.com/repos/$DistRepo" }
    $ArtifactListUrl = if ($env:SINGULARITY_ARTIFACT_LIST_URL) { $env:SINGULARITY_ARTIFACT_LIST_URL } else { 'https://artifacts.jgscripts.com/json' }
    $CfxListingUrl = 'https://runtime.fivem.net/artifacts/fivem/build_server_windows/master/'
    $CfxChangelogUrl = 'https://changelogs-live.fivem.net/api/changelog/versions/win32/server'
    $DefaultDir = 'C:\FiveM'
    $PanelPort = 40120
    $GamePort = 30120
    $DbName = 'singularity_framework'
    $DbUser = 'sg_framework'
    $DbUserHosts = @('localhost', '127.0.0.1')
    $ServiceName = 'singularity'
    $ServiceDisplayName = 'Project Singularity'
    $ApacheSiteFile = 'singularity.conf'
    $ArtifactListSize = 10
    $MaxMonitorBackups = 3
    $NetTimeout = 30
    $NetRetries = 3
    $NetRetryDelay = 5

    #MARK: Options
    $opt = @{ Dir = ''; Build = ''; Tag = ''; NoApache = $false; NoMariaDb = $false; Yes = $false }
    $i = 0
    while ($i -lt $CliArgs.Count) {
        $a = $CliArgs[$i]
        switch -Regex ($a) {
            '^(--dir|-Dir)$' { $opt.Dir = $CliArgs[$i + 1]; $i += 2; continue }
            '^(--build|-Build)$' { $opt.Build = $CliArgs[$i + 1]; $i += 2; continue }
            '^(--tag|-Tag)$' { $opt.Tag = $CliArgs[$i + 1]; $i += 2; continue }
            '^(--no-apache|-NoApache)$' { $opt.NoApache = $true; $i++; continue }
            '^(--no-mariadb|-NoMariaDb)$' { $opt.NoMariaDb = $true; $i++; continue }
            '^(--yes|-Yes|-y)$' { $opt.Yes = $true; $i++; continue }
            '^(--help|-Help|-h)$' {
                Write-Host @'
Project Singularity installer for Windows

Options:
  --dir <path>     Installation folder (default: C:\FiveM)
  --build <n>      FXServer artifact build number (default: recommended build)
  --tag <tag>      Panel release tag (default: newest release, pre-releases included)
  --no-apache      Do not install or configure Apache, the panel is reached via its port
  --no-mariadb     Do not install MariaDB; an existing MariaDB/MySQL server is required
  --yes            Accept all defaults without asking
  --help           Show this help

Supported systems: Windows 10, Windows 11, Windows Server 2019, Windows Server 2022.
'@
                return
            }
            default { throw "Unknown option: $a (use --help)" }
        }
    }
    if ($opt.Build -and $opt.Build -notmatch '^\d+$') { throw '--build must be a build number, for example 35945.' }

    #MARK: Rollback state
    $state = @{
        Ok = $false
        CreatedPaths = New-Object System.Collections.ArrayList
        CreatedDb = $false
        CreatedDbUser = $false
        CreatedService = $false
        ServiceWasRunning = $false
        CreatedApacheSite = ''
        ApacheConf = ''
        ApacheService = ''
        MonitorPath = ''
        MonitorBackup = ''
        MonitorInstalled = $false
        LogFile = ''
        Csc = ''
        MySqlExe = $null
        DbRootPassword = $null
    }

    #MARK: Logging
    #The log starts in a temp file and moves next to the install folder once it is known.
    $state.LogFile = Join-Path $env:TEMP ("singularity-install-{0}.log" -f [guid]::NewGuid().ToString('N'))
    $WorkDir = Join-Path $env:TEMP ("singularity-work-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    function Write-Log([string]$msg) {
        Add-Content -LiteralPath $state.LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    }
    function Info([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan; Write-Log "INFO  $msg" }
    function Ok([string]$msg) { Write-Host "  + $msg" -ForegroundColor Green; Write-Log "OK    $msg" }
    function Warn([string]$msg) { Write-Host "  ! $msg" -ForegroundColor Yellow; Write-Log "WARN  $msg" }
    function Fail([string]$msg) { Write-Log "ERROR $msg"; throw $msg }

    #Runs an external program with its output in the log only. Never pass secrets as arguments.
    function Invoke-Logged([string]$file, [string[]]$arguments) {
        Write-Log ("RUN   {0} {1}" -f $file, ($arguments -join ' '))
        #PS 5.1 turns native stderr lines into terminating errors under 'Stop'
        $ErrorActionPreference = 'Continue'
        $out = & $file @arguments 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($out) { Add-Content -LiteralPath $state.LogFile -Value ($out | Out-String) -Encoding UTF8 }
        if ($code -ne 0) { throw "$file exited with code $code" }
    }

    #MARK: Prompts
    function Ask([string]$prompt, [string]$default) {
        if ($opt.Yes) { return $default }
        $answer = Read-Host "$prompt [$default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
        return $answer.Trim()
    }
    function Confirm-Choice([string]$prompt, [bool]$default = $true) {
        if ($opt.Yes) { return $default }
        $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
        $answer = Read-Host "$prompt $hint"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
        return $answer.Trim().ToLower() -in @('y', 'yes')
    }
    function New-Secret([int]$length) {
        #alphanumeric only, so it never needs quoting in SQL, JSON or a command line
        $chars = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
        $bytes = New-Object byte[] ($length * 2)
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $sb = New-Object Text.StringBuilder
        while ($sb.Length -lt $length) {
            $rng.GetBytes($bytes)
            foreach ($b in $bytes) {
                #rejection sampling keeps the distribution even
                if ($b -lt 248 -and $sb.Length -lt $length) { [void]$sb.Append($chars[$b % 62]) }
            }
        }
        return $sb.ToString()
    }

    #MARK: Network
    #Small requests: whole request limited to NetTimeout seconds, retried.
    function Invoke-Fetch([string]$url) {
        for ($attempt = 0; $attempt -le $NetRetries; $attempt++) {
            try {
                Write-Log "GET   $url"
                return Invoke-RestMethod -Uri $url -TimeoutSec $NetTimeout -UseBasicParsing -Headers @{ 'User-Agent' = 'project-singularity-installer' }
            } catch {
                Write-Log "request failed: $($_.Exception.Message)"
                if ($attempt -lt $NetRetries) { Start-Sleep -Seconds $NetRetryDelay }
            }
        }
        return $null
    }
    #Large downloads: connection limited to NetTimeout seconds, aborted if the
    #transfer stalls for NetTimeout seconds, retried.
    function Invoke-Download([string]$url, [string]$dest) {
        for ($attempt = 0; $attempt -le $NetRetries; $attempt++) {
            Write-Log "GET   $url"
            & curl.exe -fSL --connect-timeout $NetTimeout --speed-limit 1 --speed-time $NetTimeout `
                -A 'project-singularity-installer' --progress-bar -o $dest $url
            if ($LASTEXITCODE -eq 0) { return }
            Write-Log "download failed with curl exit code $LASTEXITCODE"
            if ($attempt -lt $NetRetries) { Start-Sleep -Seconds $NetRetryDelay }
        }
        Fail "Download failed: $url"
    }

    function New-TrackedDir([string]$path) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            [void]$state.CreatedPaths.Add($path)
            Write-Log "created $path"
        }
    }

    #SQL goes through stdin and the root password through MYSQL_PWD, so neither
    #shows up in the process list or the log.
    function Invoke-MySql([string]$sql, [switch]$Scalar) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $state.MySqlExe
        $psi.Arguments = '-uroot -h127.0.0.1 -N -B'
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        if ($state.DbRootPassword) { $psi.EnvironmentVariables['MYSQL_PWD'] = $state.DbRootPassword }
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Write($sql)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "mysql failed: $err" }
        if ($Scalar) { return $out.Trim() }
        return $out
    }

    function Invoke-Rollback {
        Warn 'Installation failed, rolling back the changes of this run.'
        $ErrorActionPreference = 'Continue'

        if ($state.CreatedService) {
            & sc.exe stop $ServiceName *>> $state.LogFile
            Start-Sleep -Seconds 3
            & sc.exe delete $ServiceName *>> $state.LogFile
            Write-Log "removed service $ServiceName"
        } elseif ($state.ServiceWasRunning) {
            & sc.exe start $ServiceName *>> $state.LogFile
        }

        if ($state.CreatedApacheSite) {
            Remove-Item -LiteralPath $state.CreatedApacheSite -Force -ErrorAction SilentlyContinue
            if ($state.ApacheConf) {
                $conf = Get-Content -LiteralPath $state.ApacheConf -Raw
                $conf = $conf -replace "(?m)^# Project Singularity \(setup\.ps1\)\r?\nInclude .*\r?\n", ''
                Set-Content -LiteralPath $state.ApacheConf -Value $conf -Encoding ASCII -NoNewline
            }
            if ($state.ApacheService) { Restart-Service -Name $state.ApacheService -ErrorAction SilentlyContinue }
            Write-Log 'removed the Apache site'
        }

        if ($state.MySqlExe) {
            if ($state.CreatedDbUser) {
                foreach ($h in $DbUserHosts) {
                    try { Invoke-MySql ("DROP USER IF EXISTS '{0}'@'{1}';" -f $DbUser, $h) | Out-Null } catch { Write-Log $_.Exception.Message }
                }
                Write-Log "dropped database user $DbUser"
            }
            if ($state.CreatedDb) {
                try { Invoke-MySql ("DROP DATABASE IF EXISTS ``{0}``;" -f $DbName) | Out-Null } catch { Write-Log $_.Exception.Message }
                Write-Log "dropped database $DbName"
            }
        }

        if ($state.MonitorInstalled -and $state.MonitorPath) {
            Remove-Item -LiteralPath $state.MonitorPath -Recurse -Force -ErrorAction SilentlyContinue
            if ($state.MonitorBackup -and (Test-Path -LiteralPath $state.MonitorBackup)) {
                Move-Item -LiteralPath $state.MonitorBackup -Destination $state.MonitorPath
                Write-Log 'restored the previous monitor folder'
            }
        }

        for ($j = $state.CreatedPaths.Count - 1; $j -ge 0; $j--) {
            Remove-Item -LiteralPath $state.CreatedPaths[$j] -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "removed $($state.CreatedPaths[$j])"
        }
        Warn "Rollback finished. Details: $($state.LogFile)"
    }

    #MARK: Checks
    function Test-Os {
        $os = Get-CimInstance Win32_OperatingSystem
        $build = [int]$os.BuildNumber
        $isServer = $os.ProductType -ne 1
        Write-Log ("OS: {0} build {1}, {2}" -f $os.Caption, $build, $env:PROCESSOR_ARCHITECTURE)
        if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Fail 'FXServer for Windows only runs on 64-bit x86 systems.' }
        $supported = if ($isServer) { $build -in @(17763, 20348) } else { $build -ge 10240 }
        if ($supported) {
            Ok "System: $($os.Caption)"
        } else {
            Warn "This system ($($os.Caption)) is not supported. Supported: Windows 10/11, Windows Server 2019/2022."
            if (-not (Confirm-Choice 'Continue anyway?' $true)) { Fail 'Aborted by user.' }
        }
    }

    function Test-Admin {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Fail 'Run PowerShell as Administrator (right click > Run as administrator) and start the installer again.'
        }
        Ok 'Running as Administrator'
    }

    function Test-Tools {
        foreach ($tool in @('curl.exe', 'tar.exe', 'sc.exe', 'icacls.exe')) {
            if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "$tool was not found. It is part of Windows 10 1803 and newer." }
        }
        $state.Csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $state.Csc)) { Fail '.NET Framework 4 was not found, it is needed to build the service host.' }
        Ok 'Tools present'
    }

    function Test-PortInUse([int]$port) {
        $tcp = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        $udp = Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue
        return [bool]($tcp -or $udp)
    }

    function Test-Ports {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Info "Stopping the running $ServiceName service for the update."
            $state.ServiceWasRunning = $true
            Stop-Service -Name $ServiceName -Force
            Start-Sleep -Seconds 3
        }
        foreach ($port in @($PanelPort, $GamePort)) {
            if (Test-PortInUse $port) { Fail "Port $port is already in use. Stop the program using it and run the installer again." }
        }
        Ok "Ports $PanelPort and $GamePort are free"
    }

    function Test-InstallDir([string]$dir) {
        $full = [IO.Path]::GetFullPath($dir)
        if ($full -notmatch '^[A-Za-z]:\\[A-Za-z0-9._\\ -]*$' -or $full.Length -le 3) {
            Fail 'The installation folder may only contain letters, numbers, spaces, dots, dashes and underscores, and cannot be a drive root.'
        }
        $parent = Split-Path -Parent $full
        while ($parent -and -not (Test-Path -LiteralPath $parent)) { $parent = Split-Path -Parent $parent }
        try {
            $probe = Join-Path $parent ('.singularity-write-test-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType File -Path $probe -Force | Out-Null
            Remove-Item -LiteralPath $probe -Force
        } catch {
            Fail "No write permission in $parent."
        }
        if ((Test-Path -LiteralPath $full) -and (Get-ChildItem -LiteralPath $full -Force | Select-Object -First 1)) {
            Warn "$full is not empty, existing files are kept and the artifact is updated in place."
        }
        return $full
    }

    function Test-Winget { return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) }

    #Offers a winget install, or waits for a manual install. Never rolls back
    #what the user installed by hand.
    function Install-Package([string]$name, [string]$wingetId, [scriptblock]$detect, [string]$manualUrl) {
        if (Test-Winget) {
            Info "Installing $name with winget"
            Invoke-Logged 'winget.exe' @('install', '--id', $wingetId, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--scope', 'machine')
            if (& $detect) { Ok "$name installed"; return $true }
            Warn "$name was installed but could not be found yet."
        } else {
            Warn "winget is not available on this system, $name has to be installed manually: $manualUrl"
        }
        while ($true) {
            if ($opt.Yes) { return $false }
            $answer = Read-Host "Install $name manually, then press Enter to check again (or type 'skip')"
            if ($answer.Trim().ToLower() -eq 'skip') { return $false }
            if (& $detect) { Ok "$name found"; return $true }
            Warn "$name was still not found."
        }
    }

    #MARK: MariaDB
    function Find-MySql {
        $cmd = Get-Command mysql.exe -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        $found = Get-ChildItem -Path "$env:ProgramFiles\MariaDB*\bin\mysql.exe", "$env:ProgramFiles\MySQL\MySQL Server*\bin\mysql.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
        return $null
    }

    function Initialize-MariaDb {
        $state.MySqlExe = Find-MySql
        if (-not $state.MySqlExe) {
            if ($opt.NoMariaDb) { Fail 'No MariaDB/MySQL server found and --no-mariadb was given. The framework needs a database, install one first.' }
            if (-not (Confirm-Choice 'MariaDB is not installed. Install it now?' $true)) {
                Fail 'A database server is required because the framework needs a database later. Install MariaDB and run the installer again.'
            }
            $installed = Install-Package 'MariaDB' 'MariaDB.Server' { [bool](Find-MySql) } 'https://mariadb.org/download/'
            if (-not $installed) { Fail 'A database server is required because the framework needs a database later.' }
            $state.MySqlExe = Find-MySql
        } else {
            Ok 'MariaDB/MySQL client found'
        }
        $dbService = Get-Service | Where-Object { $_.Name -match '^(MariaDB|MySQL)' } | Select-Object -First 1
        if ($dbService -and $dbService.Status -ne 'Running') { Start-Service -Name $dbService.Name }

        #root without a password first (fresh MariaDB install), then ask
        try {
            Invoke-MySql 'SELECT 1;' | Out-Null
        } catch {
            $secure = Read-Host 'MariaDB root password' -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $state.DbRootPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            try { Invoke-MySql 'SELECT 1;' | Out-Null } catch { Fail 'Cannot connect to the database server as root.' }
        }
        Ok 'Connected to the database server'
    }

    function New-FrameworkDatabase([string]$hbStoreFile) {
        $dbExists = Invoke-MySql ("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='{0}';" -f $DbName) -Scalar
        $userExists = Invoke-MySql ("SELECT COUNT(*) FROM mysql.user WHERE User='{0}';" -f $DbUser) -Scalar
        if ($dbExists -ne '0' -or $userExists -ne '0') {
            if ((Test-Path -LiteralPath $hbStoreFile) -and (Select-String -LiteralPath $hbStoreFile -Pattern '"frameworkPassword"' -Quiet)) {
                Ok "Database $DbName already exists, keeping it"
                return $null
            }
            Fail "Database $DbName or user $DbUser already exists, but no panel configuration was found for it. Remove them or use the existing installation folder."
        }
        $password = New-Secret 32
        Invoke-MySql ("CREATE DATABASE ``{0}`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" -f $DbName) | Out-Null
        $state.CreatedDb = $true
        Write-Log "created database $DbName"
        $state.CreatedDbUser = $true
        $sql = ''
        foreach ($h in $DbUserHosts) {
            $sql += "CREATE USER '$DbUser'@'$h' IDENTIFIED BY '$password';`n"
            $sql += "GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'$h';`n"
        }
        $sql += "FLUSH PRIVILEGES;`n"
        Invoke-MySql $sql | Out-Null
        Write-Log "created database user $DbUser with privileges on $DbName only"
        Ok "Database $DbName with user $DbUser"
        return $password
    }

    #MARK: Apache
    function Find-Apache {
        $svc = Get-Service | Where-Object { $_.Name -match '^Apache' } | Select-Object -First 1
        $candidates = @()
        if ($svc) {
            $path = (Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $svc.Name)).PathName
            if ($path -match '"?([^"]+httpd\.exe)') { $candidates += $Matches[1] }
        }
        $candidates += @('C:\Apache24\bin\httpd.exe')
        $candidates += (Get-ChildItem -Path "$env:ProgramFiles\WinGet\Packages\ApacheLounge.httpd*\Apache24\bin\httpd.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        foreach ($c in $candidates) {
            if ($c -and (Test-Path -LiteralPath $c)) {
                return @{ Exe = $c; Service = $(if ($svc) { $svc.Name } else { '' }) }
            }
        }
        return $null
    }

    function Select-Apache {
        if ($opt.NoApache) { Write-Log 'Apache skipped (--no-apache)'; return $null }
        $apache = Find-Apache
        if (-not $apache) {
            if (-not (Confirm-Choice 'Apache is not installed. Install it as a reverse proxy for the panel?' $true)) {
                Write-Log "Apache declined, the panel is reached via port $PanelPort"
                return $null
            }
            if (-not (Install-Package 'Apache' 'ApacheLounge.httpd' { [bool](Find-Apache) } 'https://www.apachelounge.com/download/')) {
                Warn "Continuing without Apache, the panel is reached via port $PanelPort."
                return $null
            }
            $apache = Find-Apache
        }
        $domain = (Ask 'Domain for the panel (leave empty for none)' '').ToLower()
        if (-not $domain) { Write-Log 'no domain given, no virtual host is created'; return $null }
        if ($domain -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') { Fail "Invalid domain: $domain" }
        $apache.Domain = $domain
        return $apache
    }

    function Install-ApacheSite($apache) {
        if (-not $apache) { return }
        $root = Split-Path -Parent (Split-Path -Parent $apache.Exe)
        $conf = Join-Path $root 'conf\httpd.conf'
        $siteDir = Join-Path $root 'conf\extra'
        $site = Join-Path $siteDir $ApacheSiteFile
        if (Test-Path -LiteralPath $site) { Fail "$site already exists. Remove it or run with --no-apache." }

        #the ApacheLounge build expects its own folder as SRVROOT
        $confText = Get-Content -LiteralPath $conf -Raw
        $srvRoot = $root -replace '\\', '/'
        $confText = $confText -replace '(?m)^Define SRVROOT .*$', ('Define SRVROOT "{0}"' -f $srvRoot)
        foreach ($mod in @('proxy_module', 'proxy_http_module', 'proxy_wstunnel_module', 'rewrite_module', 'headers_module')) {
            $confText = $confText -replace ("(?m)^#\s*(LoadModule {0} )" -f $mod), '$1'
        }
        Set-Content -LiteralPath $site -Encoding ASCII -Value @"
# Project Singularity panel, created by setup.ps1
<VirtualHost *:80>
    ServerName $($apache.Domain)
    ProxyPreserveHost On
    ProxyRequests Off
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule ^/?(.*) ws://127.0.0.1:$PanelPort/`$1 [P,L]
    ProxyPass / http://127.0.0.1:$PanelPort/
    ProxyPassReverse / http://127.0.0.1:$PanelPort/
</VirtualHost>
"@
        $state.CreatedApacheSite = $site
        $state.ApacheConf = $conf
        $confText = $confText.TrimEnd() + "`r`n# Project Singularity (setup.ps1)`r`nInclude conf/extra/$ApacheSiteFile`r`n"
        Set-Content -LiteralPath $conf -Value $confText -Encoding ASCII -NoNewline
        Invoke-Logged $apache.Exe @('-t')

        if (-not $apache.Service) {
            Invoke-Logged $apache.Exe @('-k', 'install', '-n', 'Apache2.4')
            $apache.Service = 'Apache2.4'
        }
        $state.ApacheService = $apache.Service
        Set-Service -Name $apache.Service -StartupType Automatic
        Restart-Service -Name $apache.Service
        Ok "Apache virtual host for $($apache.Domain)"
        Warn 'Windows has no maintained certbot, so no HTTPS certificate was requested. Add one to the Apache site to use passkeys.'
    }

    #MARK: Artifact
    function Select-Artifact {
        Info 'Loading the list of FXServer builds'
        $recommended = ''
        $broken = @{}
        $jg = Invoke-Fetch $ArtifactListUrl
        if ($jg) {
            $recommended = [string]$jg.recommendedArtifact
            if ($jg.brokenArtifacts) { $jg.brokenArtifacts.PSObject.Properties | ForEach-Object { $broken[$_.Name] = $true } }
            Write-Log "artifact list: recommended $recommended from $ArtifactListUrl"
        } else {
            Warn "$ArtifactListUrl is not reachable, falling back to the official Cfx source."
            $cfx = Invoke-Fetch $CfxChangelogUrl
            if ($cfx) { $recommended = [string]$cfx.recommended }
        }

        $entries = @()
        $listing = $null
        try {
            Write-Log "GET   $CfxListingUrl"
            $listing = (Invoke-WebRequest -Uri $CfxListingUrl -TimeoutSec $NetTimeout -UseBasicParsing).Content
        } catch { Write-Log "listing failed: $($_.Exception.Message)" }
        if ($listing) {
            $seen = @{}
            foreach ($m in [regex]::Matches($listing, '\./((\d+)-[0-9a-f]+)/server\.7z')) {
                $num = $m.Groups[2].Value
                if ($seen[$num]) { continue }
                $seen[$num] = $true
                #every build folder also has a server.zip, which Windows can extract natively
                $entries += [pscustomobject]@{ Build = [int]$num; Url = "$CfxListingUrl$($m.Groups[1].Value)/server.zip" }
            }
            $entries = $entries | Sort-Object Build -Descending
        }
        if (-not $entries) {
            if ($jg -and $jg.windowsDownloadLink -and $recommended) {
                $entries = @([pscustomobject]@{ Build = [int]$recommended; Url = [string]$jg.windowsDownloadLink })
            } else {
                Fail "No artifact source is reachable ($ArtifactListUrl, $CfxListingUrl)."
            }
        }

        $list = @()
        foreach ($e in $entries) {
            if ($broken[[string]$e.Build]) { continue }
            if ($list.Count -lt $ArtifactListSize -or [string]$e.Build -eq $recommended -or [string]$e.Build -eq $opt.Build) { $list += $e }
        }
        if (-not $list) { Fail 'The artifact list is empty.' }

        if ($opt.Build) {
            $pick = $list | Where-Object { [string]$_.Build -eq $opt.Build } | Select-Object -First 1
            if (-not $pick) { Fail "Build $($opt.Build) was not found or is known to be broken." }
            Ok "Artifact build $($pick.Build) (--build)"
            return $pick
        }
        $default = 1
        Write-Host 'Available FXServer builds:'
        for ($k = 0; $k -lt $list.Count; $k++) {
            $label = ''
            if ([string]$list[$k].Build -eq $recommended) { $label = ' (recommended)'; $default = $k + 1 }
            Write-Host ("  {0,2}) {1}{2}" -f ($k + 1), $list[$k].Build, $label)
        }
        $choice = Ask 'Choose a build' ([string]$default)
        if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $list.Count) { Fail "Invalid choice: $choice" }
        $pick = $list[[int]$choice - 1]
        Ok "Artifact build $($pick.Build)"
        return $pick
    }

    function Install-Artifact($artifact, [string]$dir) {
        Info "Downloading FXServer build $($artifact.Build)"
        $zip = Join-Path $WorkDir 'server.zip'
        Invoke-Download $artifact.Url $zip
        #neither source publishes checksums, so the archive is only checked for integrity
        Write-Log 'no checksum published by the artifact source, verifying the archive instead'
        Invoke-Logged 'tar.exe' @('-tf', $zip)
        Invoke-Logged 'tar.exe' @('-xf', $zip, '-C', $dir)
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'FXServer.exe'))) { Fail 'The artifact does not contain FXServer.exe.' }
        Ok "FXServer extracted to $dir"
    }

    #MARK: Panel release
    function Resolve-Release {
        if ($opt.Tag) {
            $release = Invoke-Fetch "$DistApi/releases/tags/$($opt.Tag)"
            if (-not $release) { Fail "Release $($opt.Tag) was not found in $DistRepo." }
        } else {
            $all = Invoke-Fetch "$DistApi/releases?per_page=20"
            if ($null -eq $all) { Fail "Could not load the releases of $DistRepo, or it has no release yet." }
            #newest first, pre-releases included, drafts are not visible without a token
            $release = @($all) | Where-Object { -not $_.draft } | Sort-Object { [datetime]$_.published_at } -Descending | Select-Object -First 1
            if (-not $release) { Fail "No release of Project Singularity was found in $DistRepo." }
        }
        $asset = @($release.assets) | Where-Object { $_.name -eq $ReleaseAsset } | Select-Object -First 1
        if (-not $asset) { Fail "Release $($release.tag_name) has no $ReleaseAsset asset." }
        Ok "Panel release $($release.tag_name)"
        return @{ Tag = [string]$release.tag_name; Url = [string]$asset.browser_download_url }
    }

    function Install-Panel($release, [string]$dir) {
        $state.MonitorPath = Join-Path $dir 'citizen\system_resources\monitor'
        Info "Downloading Project Singularity $($release.Tag)"
        $zip = Join-Path $WorkDir $ReleaseAsset
        Invoke-Download $release.Url $zip
        Invoke-Logged 'tar.exe' @('-tf', $zip)

        #backups live outside system_resources so FXServer never sees them as resources
        if (Test-Path -LiteralPath $state.MonitorPath) {
            $backupDir = Join-Path $dir 'backups'
            New-TrackedDir $backupDir
            $state.MonitorBackup = Join-Path $backupDir ('monitor.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $state.MonitorPath -Destination $state.MonitorBackup
            Write-Log "moved the existing monitor folder to $($state.MonitorBackup)"
        }
        $state.MonitorInstalled = $true
        New-Item -ItemType Directory -Path $state.MonitorPath -Force | Out-Null
        Invoke-Logged 'tar.exe' @('-xf', $zip, '-C', $state.MonitorPath)
        if (-not (Test-Path -LiteralPath (Join-Path $state.MonitorPath 'fxmanifest.lua'))) { Fail "$ReleaseAsset does not contain fxmanifest.lua." }
        Ok 'Panel installed as the monitor resource'
    }

    #Keeps the newest backups. Runs only after a successful install, so a
    #rollback can always restore the latest one.
    function Remove-OldBackups([string]$dir) {
        $backupDir = Join-Path $dir 'backups'
        if (-not (Test-Path -LiteralPath $backupDir)) { return }
        Get-ChildItem -LiteralPath $backupDir -Directory -Filter 'monitor.bak.*' |
            Sort-Object Name -Descending | Select-Object -Skip $MaxMonitorBackups |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force
                Write-Log "deleted old backup $($_.FullName)"
            }
    }

    #MARK: Files & permissions
    function Write-Utf8File([string]$path, [string]$content) {
        [IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding($false)))
    }

    #Owner, SYSTEM and Administrators only, the Windows equivalent of 750/600.
    function Set-RestrictedAcl([string]$path, [string]$user) {
        Invoke-Logged 'icacls.exe' @($path, '/inheritance:r', '/grant:r', "${user}:(OI)(CI)F", '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '/T', '/C', '/Q')
    }
    function Set-RestrictedFileAcl([string]$path, [string]$user) {
        Invoke-Logged 'icacls.exe' @($path, '/inheritance:r', '/grant:r', "${user}:F", '*S-1-5-18:F', '*S-1-5-32-544:F', '/Q')
    }

    function JsonString([string]$s) { return ($s | ConvertTo-Json) }

    #MARK: Service
    #FXServer.exe is a console program, not a Windows service. This small host
    #is compiled with the csc.exe that ships with .NET Framework 4, so no third
    #party tool is needed. It starts FXServer, stops it with the process tree,
    #and exits with an error if FXServer dies so the service recovery restarts it.
    $ServiceHostSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;

public class SingularityServiceHost : ServiceBase {
    private Process proc;
    private StreamWriter stdin;
    private bool stopping;
    private readonly string baseDir = AppDomain.CurrentDomain.BaseDirectory;

    public SingularityServiceHost() { ServiceName = "singularity"; CanStop = true; CanShutdown = true; }

    private string Setting(string key) {
        foreach (var line in File.ReadAllLines(Path.Combine(baseDir, "singularity-service.ini"))) {
            var idx = line.IndexOf('=');
            if (idx > 0 && line.Substring(0, idx).Trim() == key) return line.Substring(idx + 1).Trim();
        }
        throw new Exception("Missing setting " + key);
    }

    protected override void OnStart(string[] args) {
        var psi = new ProcessStartInfo(Setting("fxserver"));
        psi.WorkingDirectory = Setting("workdir");
        psi.UseShellExecute = false;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.EnvironmentVariables["SINGULARITY_DATA_PATH"] = Setting("datapath");
        var url = Setting("panelurl");
        if (url.Length > 0) psi.EnvironmentVariables["SINGULARITY_PANEL_URL"] = url;
        var log = new StreamWriter(Path.Combine(Setting("datapath"), "service-console.log"), false);
        log.AutoFlush = true;
        proc = new Process();
        proc.StartInfo = psi;
        proc.EnableRaisingEvents = true;
        proc.OutputDataReceived += (s, e) => { if (e.Data != null) lock (log) log.WriteLine(e.Data); };
        proc.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (log) log.WriteLine(e.Data); };
        proc.Exited += (s, e) => { if (!stopping) Environment.Exit(1); };
        proc.Start();
        stdin = proc.StandardInput;
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
    }

    private void StopServer() {
        stopping = true;
        if (proc == null || proc.HasExited) return;
        try { stdin.WriteLine("quit"); stdin.Flush(); } catch { }
        if (!proc.WaitForExit(30000)) {
            var kill = Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + proc.Id + " /T /F") { UseShellExecute = false, CreateNoWindow = true });
            kill.WaitForExit(15000);
        }
    }

    protected override void OnStop() { StopServer(); }
    protected override void OnShutdown() { StopServer(); }

    public static void Main() { ServiceBase.Run(new SingularityServiceHost()); }
}
'@

    #Services running as a user account need the "Log on as a service" right.
    function Grant-ServiceLogonRight([string]$account) {
        $sid = (New-Object Security.Principal.NTAccount($account)).Translate([Security.Principal.SecurityIdentifier]).Value
        $cfg = Join-Path $WorkDir 'secpol.inf'
        $db = Join-Path $WorkDir 'secpol.sdb'
        Invoke-Logged 'secedit.exe' @('/export', '/cfg', $cfg, '/areas', 'USER_RIGHTS', '/quiet')
        $lines = Get-Content -LiteralPath $cfg
        $line = $lines | Where-Object { $_ -match '^SeServiceLogonRight' } | Select-Object -First 1
        if ($line -and $line -match [regex]::Escape("*$sid")) { return }
        if ($line) {
            $lines = $lines -replace '^SeServiceLogonRight = (.*)$', ('SeServiceLogonRight = $1,*' + $sid)
        } else {
            $lines = $lines -replace '^\[Privilege Rights\]$', ("[Privilege Rights]`r`nSeServiceLogonRight = *" + $sid)
        }
        Set-Content -LiteralPath $cfg -Value $lines -Encoding Unicode
        Invoke-Logged 'secedit.exe' @('/configure', '/db', $db, '/cfg', $cfg, '/areas', 'USER_RIGHTS', '/quiet')
        Write-Log "granted the service logon right to $account"
    }

    function Install-Service([string]$dir, [string]$serverData, [string]$txData, [string]$panelUrl, [string]$account) {
        $hostDir = Join-Path $dir 'service'
        New-TrackedDir $hostDir
        $hostExe = Join-Path $hostDir 'singularity-service.exe'
        $src = Join-Path $WorkDir 'SingularityServiceHost.cs'
        Set-Content -LiteralPath $src -Value $ServiceHostSource -Encoding UTF8
        Invoke-Logged $state.Csc @('/nologo', '/target:exe', "/out:$hostExe", '/reference:System.ServiceProcess.dll', $src)
        Write-Utf8File (Join-Path $hostDir 'singularity-service.ini') (@(
                "fxserver=$(Join-Path $dir 'FXServer.exe')",
                "workdir=$serverData",
                "datapath=$txData",
                "panelurl=$panelUrl"
            ) -join "`r`n")

        #reinstall: the existing service already points to this host, only its files were updated
        $existing = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName)
        if ($existing) {
            if ($existing.PathName -notlike "*$hostExe*") {
                Fail "A service named $ServiceName already exists for another folder ($($existing.PathName)). Remove it first (sc.exe delete $ServiceName)."
            }
            Ok "Service $ServiceName updated"
            return
        }

        #the service runs as the user who started the installer, which needs their password.
        #New-Service keeps the password out of the command line and the log.
        Write-Host "The service runs as $account. Windows needs this account's password to start it."
        $secure = Read-Host "Password for $account" -AsSecureString
        $cred = New-Object Management.Automation.PSCredential($account, $secure)
        New-Service -Name $ServiceName -DisplayName $ServiceDisplayName -BinaryPathName ('"{0}"' -f $hostExe) `
            -StartupType Automatic -Credential $cred -Description 'FiveM server with the Project Singularity panel' | Out-Null
        $state.CreatedService = $true
        Grant-ServiceLogonRight $account
        #restart after 10 seconds on each failure, reset the failure count after a day
        Invoke-Logged 'sc.exe' @('failure', $ServiceName, 'reset=', '86400', 'actions=', 'restart/10000/restart/10000/restart/10000')
        Invoke-Logged 'sc.exe' @('failureflag', $ServiceName, '1')
        Ok "Service $ServiceName created"
    }

    function Start-AndVerify([string]$txData) {
        Info 'Starting the service'
        Start-Service -Name $ServiceName
        for ($k = 0; $k -lt 90; $k++) {
            try {
                Invoke-WebRequest -Uri "http://127.0.0.1:$PanelPort/" -TimeoutSec 2 -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop | Out-Null
                Ok "The panel answers on port $PanelPort"
                return
            } catch {
                if ($_.Exception.Response) { Ok "The panel answers on port $PanelPort"; return }
            }
            if ((Get-Service -Name $ServiceName).Status -eq 'Stopped') { break }
            Start-Sleep -Seconds 2
        }
        $consoleLog = Join-Path $txData 'service-console.log'
        if (Test-Path -LiteralPath $consoleLog) { Add-Content -LiteralPath $state.LogFile -Value (Get-Content -LiteralPath $consoleLog -Tail 50 | Out-String) }
        Fail "The panel did not start. The last console lines are in $($state.LogFile)."
    }

    #MARK: Main
    try {
        Write-Host ''
        Write-Host '  Project Singularity installer'
        Write-Host ''
        Write-Log ("Project Singularity installer started, options: dir='{0}' build='{1}' tag='{2}' no-apache={3} no-mariadb={4} yes={5}" -f $opt.Dir, $opt.Build, $opt.Tag, $opt.NoApache, $opt.NoMariaDb, $opt.Yes)

        Test-Os
        Test-Admin
        Test-Tools

        $dirInput = if ($opt.Dir) { $opt.Dir } else { Ask 'Installation folder' $DefaultDir }
        $installDir = Test-InstallDir $dirInput
        $finalLog = Join-Path (Split-Path -Parent $installDir) 'singularity-install.log'
        Copy-Item -LiteralPath $state.LogFile -Destination $finalLog -Force
        Remove-Item -LiteralPath $state.LogFile -Force
        $state.LogFile = $finalLog
        Ok "Installation folder $installDir"
        $txData = Join-Path $installDir 'txData'
        $hbStoreFile = Join-Path $txData 'hb_store.json'
        $serverData = Join-Path $installDir 'server-data'
        $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name

        Test-Ports
        Initialize-MariaDb
        $apache = Select-Apache
        $artifact = Select-Artifact
        $release = Resolve-Release

        New-TrackedDir $installDir
        Install-Artifact $artifact $installDir
        Install-Panel $release $installDir

        New-TrackedDir $serverData
        New-TrackedDir (Join-Path $serverData 'resources')
        $cfgFile = Join-Path $serverData 'server.cfg'
        if (-not (Test-Path -LiteralPath $cfgFile)) {
            Write-Utf8File $cfgFile (@(
                    '# Minimal server.cfg created by the Project Singularity installer.',
                    '# The rest of the configuration is added by the setup wizard in the browser.',
                    "endpoint_add_tcp `"0.0.0.0:$GamePort`"",
                    "endpoint_add_udp `"0.0.0.0:$GamePort`"",
                    'sv_licenseKey "changeme"',
                    'set resources_path "resources"',
                    ''
                ) -join "`r`n")
            Write-Log "created $cfgFile"
        }
        Ok "Server data folder $serverData"

        New-TrackedDir $txData
        New-TrackedDir (Join-Path $txData 'default')
        $dbPassword = New-FrameworkDatabase $hbStoreFile

        $setupToken = ''
        $configFile = Join-Path $txData 'default\config.json'
        if (-not (Test-Path -LiteralPath $configFile)) {
            $setupToken = New-Secret 48
            #autoStart stays off until the setup wizard is completed
            Write-Utf8File $configFile @"
{
  "version": 3,
  "server": {
    "dataPath": $(JsonString $serverData),
    "artifactsPath": $(JsonString $installDir),
    "autoStart": false
  },
  "panel": {
    "port": $PanelPort
  },
  "setup": {
    "token": "$setupToken"
  }
}
"@
            Write-Log 'wrote the panel configuration (setup token not logged)'
        } else {
            Write-Log "kept the existing panel configuration $configFile"
        }
        if ($dbPassword) {
            Write-Utf8File $hbStoreFile @"
{
  "framework": {
    "kind": "none",
    "enabled": false,
    "connection": {
      "host": "127.0.0.1",
      "port": 3306,
      "user": "$DbUser",
      "database": "$DbName"
    }
  },
  "frameworkPassword": "$dbPassword"
}
"@
            $dbPassword = $null
            Write-Log 'wrote the framework database access (password not logged)'
        }
        Ok 'Panel configuration written'

        Install-ApacheSite $apache
        $panelUrl = ''
        if ($apache) { $panelUrl = "http://$($apache.Domain)" }

        Set-RestrictedAcl $installDir $account
        if (Test-Path -LiteralPath $configFile) { Set-RestrictedFileAcl $configFile $account }
        if (Test-Path -LiteralPath $hbStoreFile) { Set-RestrictedFileAcl $hbStoreFile $account }
        Ok "Folder permissions restricted to $account, SYSTEM and Administrators"

        Install-Service $installDir $serverData $txData $panelUrl $account
        Start-AndVerify $txData
        Remove-OldBackups $installDir

        $state.Ok = $true
        Write-Log 'installation finished'

        $hostUrl = if ($apache) { "http://$($apache.Domain)" } else {
            $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -First 1).IPAddress
            if (-not $ip) { $ip = 'localhost' }
            "http://${ip}:$PanelPort"
        }
        $wizard = "$hostUrl/setup"
        if ($setupToken) { $wizard = "$wizard`?token=$setupToken" }

        Write-Host ''
        Write-Host '  Project Singularity is installed.' -ForegroundColor Green
        Write-Host ''
        Write-Host "  Installation folder : $installDir"
        Write-Host "  Setup wizard        : $wizard"
        Write-Host "  Panel port          : $PanelPort"
        Write-Host "  Game server port    : $GamePort"
        Write-Host "  Database            : $DbName (user $DbUser)"
        Write-Host "  Service             : $ServiceName (Get-Service $ServiceName)"
        Write-Host "  Log file            : $($state.LogFile)"
        Write-Host ''
        if ($setupToken) { Write-Host '  The wizard link contains a one-time token, keep it private.' }
        Write-Host '  Passkeys need HTTPS or localhost. Over plain http the wizard uses a password instead.'
        Write-Host ''
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "ERROR $($_.Exception.Message)"
        Write-Log ($_.ScriptStackTrace | Out-String)
    } finally {
        if (-not $state.Ok) { Invoke-Rollback }
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-SingularityInstaller -CliArgs $args
