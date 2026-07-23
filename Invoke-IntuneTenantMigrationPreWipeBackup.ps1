<#
.SYNOPSIS
    Pre-wipe tenant migration backup and readiness script.

.DESCRIPTION
    Creates a serial-number folder in the signed-in user's OneDrive Documents
    folder and performs the following:

      - Copies Edge bookmarks
      - Copies Chrome bookmarks
      - Copies the user's Downloads folder
      - Checks for manually exported Edge and Chrome password CSV files
      - Exports the BitLocker recovery password
      - Creates a detailed activity log
      - Creates a JSON readiness report
      - Creates Ready.tag only when all required items succeed

.RECOMMENDED INTUNE SETTINGS
    Run this script using the logged-on credentials: No
    Enforce script signature check: No
    Run script in 64-bit PowerShell: Yes

.NOTES
    Browser password export cannot be completed silently through the supported
    browser interface. The user must export each browser's passwords into the
    Browser Passwords folder created by this script.
#>

[CmdletBinding()]
param (
    [bool]$RequireEdgePasswordExport = $true,
    [bool]$RequireChromePasswordExport = $true
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Functions
# ============================================================

function Get-InteractiveUserProfile {
    try {
        $LoggedOnUser = (Get-CimInstance Win32_ComputerSystem).UserName

        if ([string]::IsNullOrWhiteSpace($LoggedOnUser)) {
            throw 'No interactive user is currently signed in.'
        }

        $AccountName = $LoggedOnUser.Split('\')[-1]

        $Profile = Get-CimInstance Win32_UserProfile |
            Where-Object {
                -not $_.Special -and
                $_.Loaded -and
                (Split-Path $_.LocalPath -Leaf) -eq $AccountName
            } |
            Sort-Object LastUseTime -Descending |
            Select-Object -First 1

        if (-not $Profile) {
            $Profile = Get-CimInstance Win32_UserProfile |
                Where-Object {
                    -not $_.Special -and
                    (Split-Path $_.LocalPath -Leaf) -eq $AccountName
                } |
                Sort-Object LastUseTime -Descending |
                Select-Object -First 1
        }

        if (-not $Profile) {
            throw "Could not locate a Windows profile for $LoggedOnUser."
        }

        [PSCustomObject]@{
            UserName    = $LoggedOnUser
            AccountName = $AccountName
            SID         = $Profile.SID
            ProfilePath = $Profile.LocalPath
        }
    }
    catch {
        throw "Interactive-user detection failed: $($_.Exception.Message)"
    }
}

function Get-UserShellFolder {
    param (
        [Parameter(Mandatory)]
        [string]$SID,

        [Parameter(Mandatory)]
        [string]$ValueName
    )

    $Path = "Registry::HKEY_USERS\$SID\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

    try {
        $Value = Get-ItemPropertyValue `
            -Path $Path `
            -Name $ValueName `
            -ErrorAction Stop

        return [Environment]::ExpandEnvironmentVariables($Value)
    }
    catch {
        return $null
    }
}

function Get-OneDriveDocumentsPath {
    param (
        [Parameter(Mandatory)]
        [pscustomobject]$UserProfile
    )

    $DocumentsPath = Get-UserShellFolder `
        -SID $UserProfile.SID `
        -ValueName 'Personal'

    if (
        $DocumentsPath -and
        $DocumentsPath -match '\\OneDrive(?:\s*-\s*[^\\]+)?\\Documents(?:\\|$)' -and
        (Test-Path -LiteralPath $DocumentsPath)
    ) {
        return $DocumentsPath
    }

    # Fallback: locate a business OneDrive folder containing Documents.
    $PossibleOneDriveFolders = @(
        Get-ChildItem `
            -Path $UserProfile.ProfilePath `
            -Directory `
            -Force `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq 'OneDrive' -or
            $_.Name -like 'OneDrive - *'
        }
    )

    foreach ($Folder in $PossibleOneDriveFolders) {
        $PossibleDocuments = Join-Path $Folder.FullName 'Documents'

        if (Test-Path -LiteralPath $PossibleDocuments) {
            return $PossibleDocuments
        }
    }

    return $null
}

function Copy-FolderContents {
    param (
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return [PSCustomObject]@{
            Success   = $true
            FileCount = 0
            Message   = "Source folder does not exist: $Source"
        }
    }

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    $Files = @(
        Get-ChildItem `
            -LiteralPath $Source `
            -File `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    )

    try {
        # Robocopy is more reliable than Copy-Item for large Downloads folders.
        $Arguments = @(
            "`"$Source`""
            "`"$Destination`""
            '/E'
            '/COPY:DAT'
            '/DCOPY:DAT'
            '/R:2'
            '/W:2'
            '/XJ'
            '/FFT'
            '/NP'
            '/NFL'
            '/NDL'
        )

        $Process = Start-Process `
            -FilePath "$env:SystemRoot\System32\robocopy.exe" `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru `
            -WindowStyle Hidden

        # Robocopy codes 0 through 7 are successful or nonfatal.
        $Succeeded = $Process.ExitCode -le 7

        [PSCustomObject]@{
            Success   = $Succeeded
            FileCount = $Files.Count
            ExitCode  = $Process.ExitCode
            Message   = "Robocopy exit code: $($Process.ExitCode)"
        }
    }
    catch {
        [PSCustomObject]@{
            Success   = $false
            FileCount = $Files.Count
            ExitCode  = $null
            Message   = $_.Exception.Message
        }
    }
}

function Copy-BrowserBookmarks {
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Edge', 'Chrome')]
        [string]$Browser,

        [Parameter(Mandatory)]
        [string]$ProfilePath,

        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    $BrowserDataRoot = switch ($Browser) {
        'Edge' {
            Join-Path $ProfilePath 'AppData\Local\Microsoft\Edge\User Data'
        }

        'Chrome' {
            Join-Path $ProfilePath 'AppData\Local\Google\Chrome\User Data'
        }
    }

    $Destination = Join-Path $DestinationRoot $Browser
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    if (-not (Test-Path -LiteralPath $BrowserDataRoot)) {
        return [PSCustomObject]@{
            Success      = $true
            ProfilesFound = 0
            FilesCopied  = 0
            Message      = "$Browser user-data folder was not found."
        }
    }

    $BrowserProfiles = @(
        Get-ChildItem `
            -LiteralPath $BrowserDataRoot `
            -Directory `
            -Force `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq 'Default' -or
            $_.Name -like 'Profile *'
        }
    )

    $CopiedFiles = 0
    $Failures = @()

    foreach ($BrowserProfile in $BrowserProfiles) {
        $ProfileDestination = Join-Path $Destination $BrowserProfile.Name
        New-Item -Path $ProfileDestination -ItemType Directory -Force | Out-Null

        foreach ($FileName in 'Bookmarks', 'Bookmarks.bak') {
            $SourceFile = Join-Path $BrowserProfile.FullName $FileName

            if (Test-Path -LiteralPath $SourceFile) {
                try {
                    Copy-Item `
                        -LiteralPath $SourceFile `
                        -Destination (Join-Path $ProfileDestination $FileName) `
                        -Force `
                        -ErrorAction Stop

                    $CopiedFiles++
                }
                catch {
                    $Failures += "$($BrowserProfile.Name)\$FileName`: $($_.Exception.Message)"
                }
            }
        }
    }

    [PSCustomObject]@{
        Success       = $Failures.Count -eq 0
        ProfilesFound = $BrowserProfiles.Count
        FilesCopied   = $CopiedFiles
        Message       = if ($Failures.Count -eq 0) {
            "$CopiedFiles bookmark file(s) copied from $($BrowserProfiles.Count) profile(s)."
        }
        else {
            $Failures -join '; '
        }
    }
}

function Get-BitLockerRecoveryPassword {
    try {
        $Volume = Get-BitLockerVolume -MountPoint $env:SystemDrive

        $Protectors = @(
            $Volume.KeyProtector |
            Where-Object {
                $_.KeyProtectorType -eq 'RecoveryPassword' -and
                -not [string]::IsNullOrWhiteSpace($_.RecoveryPassword)
            }
        )

        if ($Protectors.Count -eq 0) {
            return [PSCustomObject]@{
                Success           = $false
                ProtectionStatus  = $Volume.ProtectionStatus.ToString()
                RecoveryPasswords = @()
                Message           = 'No BitLocker recovery-password protector was found.'
            }
        }

        [PSCustomObject]@{
            Success           = $true
            ProtectionStatus  = $Volume.ProtectionStatus.ToString()
            RecoveryPasswords = @($Protectors.RecoveryPassword)
            Message           = "$($Protectors.Count) recovery-password protector(s) found."
        }
    }
    catch {
        [PSCustomObject]@{
            Success           = $false
            ProtectionStatus  = 'Unknown'
            RecoveryPasswords = @()
            Message           = $_.Exception.Message
        }
    }
}

function Test-OneDrivePath {
    param (
        [AllowNull()]
        [string]$Path
    )

    return (
        -not [string]::IsNullOrWhiteSpace($Path) -and
        $Path -match '\\OneDrive(?:\s*-\s*[^\\]+)?\\'
    )
}

# ============================================================
# Initial discovery
# ============================================================

$UserProfile = Get-InteractiveUserProfile
$Bios = Get-CimInstance Win32_BIOS
$SerialNumber = ($Bios.SerialNumber -replace '[\\/:*?"<>|]', '_').Trim()

if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
    $SerialNumber = $env:COMPUTERNAME
}

$OneDriveDocuments = Get-OneDriveDocumentsPath -UserProfile $UserProfile

if (-not $OneDriveDocuments) {
    throw 'The signed-in user''s OneDrive Documents folder could not be found.'
}

$MigrationRoot = Join-Path $OneDriveDocuments 'Tenant Migration Backup'
$DeviceFolder = Join-Path $MigrationRoot $SerialNumber

$BookmarkRoot = Join-Path $DeviceFolder 'Browser Bookmarks'
$PasswordRoot = Join-Path $DeviceFolder 'Browser Passwords'
$DownloadsBackup = Join-Path $DeviceFolder 'Downloads'

$LogPath = Join-Path $DeviceFolder 'Migration.log'
$JsonPath = Join-Path $DeviceFolder 'MigrationReadiness.json'
$BitLockerPath = Join-Path $DeviceFolder 'BitLocker Recovery Key.txt'
$ReadyTag = Join-Path $DeviceFolder 'Ready.tag'
$NotReadyTag = Join-Path $DeviceFolder 'NotReady.tag'

New-Item -Path $DeviceFolder -ItemType Directory -Force | Out-Null
New-Item -Path $BookmarkRoot -ItemType Directory -Force | Out-Null
New-Item -Path $PasswordRoot -ItemType Directory -Force | Out-Null

$Results = [ordered]@{}

function Write-MigrationLog {
    param (
        [Parameter(Mandatory)]
        [string]$Item,

        [Parameter(Mandatory)]
        [ValidateSet('SUCCESS', 'FAILURE', 'WARNING', 'INFO')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Details
    )

    $Entry = '{0} | {1,-7} | {2} | {3}' -f (
        Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ), $Status, $Item, $Details

    Add-Content -LiteralPath $LogPath -Value $Entry -Encoding UTF8
    Write-Output $Entry
}

function Set-MigrationResult {
    param (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Success,

        [Parameter(Mandatory)]
        [string]$Details,

        [bool]$Required = $true,

        [hashtable]$AdditionalData
    )

    $Record = [ordered]@{
        Success  = $Success
        Required = $Required
        Details  = $Details
    }

    if ($AdditionalData) {
        foreach ($Key in $AdditionalData.Keys) {
            $Record[$Key] = $AdditionalData[$Key]
        }
    }

    $script:Results[$Name] = $Record

    Write-MigrationLog `
        -Item $Name `
        -Status $(if ($Success) {
            'SUCCESS'
        }
        elseif ($Required) {
            'FAILURE'
        }
        else {
            'WARNING'
        }) `
        -Details $Details
}

Write-MigrationLog `
    -Item 'Migration backup' `
    -Status 'INFO' `
    -Details "Starting backup for $($UserProfile.UserName) on $env:COMPUTERNAME."

Write-MigrationLog `
    -Item 'Destination' `
    -Status 'INFO' `
    -Details $DeviceFolder

# ============================================================
# Verify OneDrive Documents
# ============================================================

$DocumentsInOneDrive = Test-OneDrivePath -Path $OneDriveDocuments

Set-MigrationResult `
    -Name 'OneDriveDocuments' `
    -Success $DocumentsInOneDrive `
    -Details "Documents path: $OneDriveDocuments"

# ============================================================
# Copy browser bookmarks
# ============================================================

$EdgeBookmarks = Copy-BrowserBookmarks `
    -Browser Edge `
    -ProfilePath $UserProfile.ProfilePath `
    -DestinationRoot $BookmarkRoot

Set-MigrationResult `
    -Name 'EdgeBookmarks' `
    -Success $EdgeBookmarks.Success `
    -Details $EdgeBookmarks.Message `
    -AdditionalData @{
        ProfilesFound = $EdgeBookmarks.ProfilesFound
        FilesCopied   = $EdgeBookmarks.FilesCopied
    }

$ChromeBookmarks = Copy-BrowserBookmarks `
    -Browser Chrome `
    -ProfilePath $UserProfile.ProfilePath `
    -DestinationRoot $BookmarkRoot

Set-MigrationResult `
    -Name 'ChromeBookmarks' `
    -Success $ChromeBookmarks.Success `
    -Details $ChromeBookmarks.Message `
    -AdditionalData @{
        ProfilesFound = $ChromeBookmarks.ProfilesFound
        FilesCopied   = $ChromeBookmarks.FilesCopied
    }

# ============================================================
# Copy Downloads
# ============================================================

$DownloadsPath = Get-UserShellFolder `
    -SID $UserProfile.SID `
    -ValueName '{374DE290-123F-4565-9164-39C4925E467B}'

if (-not $DownloadsPath) {
    $DownloadsPath = Join-Path $UserProfile.ProfilePath 'Downloads'
}

$DownloadsResult = Copy-FolderContents `
    -Source $DownloadsPath `
    -Destination $DownloadsBackup

Set-MigrationResult `
    -Name 'DownloadsBackup' `
    -Success $DownloadsResult.Success `
    -Details "$($DownloadsResult.Message); files discovered: $($DownloadsResult.FileCount)" `
    -AdditionalData @{
        SourcePath   = $DownloadsPath
        BackupPath   = $DownloadsBackup
        FilesFound   = $DownloadsResult.FileCount
        RobocopyCode = $DownloadsResult.ExitCode
    }

# ============================================================
# Password-export readiness
# ============================================================

$EdgePasswordPath = Join-Path $PasswordRoot 'Edge Passwords.csv'
$ChromePasswordPath = Join-Path $PasswordRoot 'Chrome Passwords.csv'

$EdgePasswordExists = Test-Path -LiteralPath $EdgePasswordPath
$ChromePasswordExists = Test-Path -LiteralPath $ChromePasswordPath

Set-MigrationResult `
    -Name 'EdgePasswords' `
    -Success $EdgePasswordExists `
    -Required $RequireEdgePasswordExport `
    -Details $(if ($EdgePasswordExists) {
        "Password export found: $EdgePasswordPath"
    }
    else {
        "Not found. Export Edge passwords to: $EdgePasswordPath"
    })

Set-MigrationResult `
    -Name 'ChromePasswords' `
    -Success $ChromePasswordExists `
    -Required $RequireChromePasswordExport `
    -Details $(if ($ChromePasswordExists) {
        "Password export found: $ChromePasswordPath"
    }
    else {
        "Not found. Export Chrome passwords to: $ChromePasswordPath"
    })

# ============================================================
# BitLocker recovery key
# ============================================================

$BitLocker = Get-BitLockerRecoveryPassword

if ($BitLocker.Success) {
    $BitLockerFileContent = @"
WARNING: This file contains sensitive BitLocker recovery information.
Delete this file after the migration has been completed and verified.

Computer name: $env:COMPUTERNAME
Serial number: $SerialNumber
Operating-system drive: $env:SystemDrive
Protection status: $($BitLocker.ProtectionStatus)
Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
User: $($UserProfile.UserName)

Recovery password(s):
$($BitLocker.RecoveryPasswords -join "`r`n")
"@

    $BitLockerFileContent |
        Set-Content `
            -LiteralPath $BitLockerPath `
            -Encoding UTF8 `
            -Force

    Set-MigrationResult `
        -Name 'BitLockerRecoveryKey' `
        -Success $true `
        -Details "Recovery password written to $BitLockerPath"
}
else {
    Set-MigrationResult `
        -Name 'BitLockerRecoveryKey' `
        -Success $false `
        -Details $BitLocker.Message
}

# ============================================================
# Create readiness report
# ============================================================

$FailedRequiredItems = @(
    $Results.GetEnumerator() |
    Where-Object {
        $_.Value.Required -and
        -not $_.Value.Success
    } |
    ForEach-Object {
        $_.Key
    }
)

$ReadyForWipe = $FailedRequiredItems.Count -eq 0

$Report = [ordered]@{
    AssessmentTimeUTC    = (Get-Date).ToUniversalTime().ToString('o')
    AssessmentTimeLocal  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    ReadyForWipe         = $ReadyForWipe
    ComputerName         = $env:COMPUTERNAME
    SerialNumber         = $SerialNumber
    UserName             = $UserProfile.UserName
    UserSID              = $UserProfile.SID
    UserProfile          = $UserProfile.ProfilePath
    OneDriveDocuments    = $OneDriveDocuments
    DeviceBackupFolder   = $DeviceFolder
    PasswordExportFolder = $PasswordRoot
    FailedRequiredItems  = $FailedRequiredItems
    Results              = $Results
}

try {
    $Report |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath $JsonPath `
            -Encoding UTF8 `
            -Force

    Write-MigrationLog `
        -Item 'JSON readiness report' `
        -Status 'SUCCESS' `
        -Details "Created $JsonPath"
}
catch {
    $ReadyForWipe = $false
    $FailedRequiredItems += 'JsonReadinessReport'

    Write-MigrationLog `
        -Item 'JSON readiness report' `
        -Status 'FAILURE' `
        -Details $_.Exception.Message
}

# ============================================================
# Final readiness tag
# ============================================================

Remove-Item -LiteralPath $ReadyTag, $NotReadyTag `
    -Force `
    -ErrorAction SilentlyContinue

if ($ReadyForWipe) {
    @"
ReadyForWipe=True
ComputerName=$env:COMPUTERNAME
SerialNumber=$SerialNumber
User=$($UserProfile.UserName)
Completed=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Report=$JsonPath
"@ | Set-Content -LiteralPath $ReadyTag -Encoding UTF8

    Write-MigrationLog `
        -Item 'Final readiness' `
        -Status 'SUCCESS' `
        -Details 'All required backup items completed. Device is ready for wipe.'

    Write-Output "READY=True;SERIAL=$SerialNumber;FAILED=None"
    exit 0
}

@"
ReadyForWipe=False
ComputerName=$env:COMPUTERNAME
SerialNumber=$SerialNumber
User=$($UserProfile.UserName)
Completed=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
FailedItems=$($FailedRequiredItems -join ', ')
Report=$JsonPath
"@ | Set-Content -LiteralPath $NotReadyTag -Encoding UTF8

Write-MigrationLog `
    -Item 'Final readiness' `
    -Status 'FAILURE' `
    -Details "Failed or incomplete items: $($FailedRequiredItems -join ', ')"

Write-Output "READY=False;SERIAL=$SerialNumber;FAILED=$($FailedRequiredItems -join ',')"
exit 1
