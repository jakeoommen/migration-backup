# migration-backup

# Intune Tenant Migration Pre-Wipe Backup

## Overview

`Invoke-IntuneTenantMigrationPreWipeBackup.ps1` prepares Windows devices for migration from the current Intune tenant to a new tenant.

The script backs up selected user data to OneDrive, records the result of each step, and generates a readiness report before the device is wiped.

## Backup Location

The script creates a folder in the signed-in user’s OneDrive Documents folder using the device serial number.

```text
Documents
└── Tenant Migration Backup
    └── SERIALNUMBER
        ├── Browser Bookmarks
        │   ├── Edge
        │   └── Chrome
        ├── Browser Passwords
        │   ├── Edge Passwords.csv
        │   └── Chrome Passwords.csv
        ├── Downloads
        ├── MigrationReadiness.json
        ├── Migration.log
        └── BitLocker Recovery Key.txt
```

## Script Actions

The script:

* Backs up Microsoft Edge bookmarks
* Backs up Google Chrome bookmarks
* Backs up the user’s Downloads folder
* Confirms Edge and Chrome password exports are present
* Saves the BitLocker recovery key
* Creates a migration activity log
* Creates a JSON readiness report
* Reports whether the device is ready for migration

## Browser Password Exports

Both Google Chrome and Microsoft Edge encrypt passwords using the Windows Data Protection API (DPAPI), the encryption keys are fundamentally tied to the local Windows user profile security identifier (SID) and the active Entra ID account [0.21].

Users must export their saved passwords before the device is wiped.

### Google Chrome

1. Open `chrome://password-manager/settings`
2. Select **Export passwords**
3. Complete the Windows security prompt
4. Save the file as:

```text
Documents\Tenant Migration Backup\SERIALNUMBER\Browser Passwords\Chrome Passwords.csv
```

### Microsoft Edge

1. Open `edge://wallet/passwords`
2. Select **Export passwords**
3. Complete the Windows security prompt
4. Save the file as:

```text
Documents\Tenant Migration Backup\SERIALNUMBER\Browser Passwords\Edge Passwords.csv
```

## Intune Deployment Settings

Use the following Intune script settings:

| Setting                         | Value                         |
| ------------------------------- | ----------------------------- |
| Run using logged-on credentials | No                            |
| Run in 64-bit PowerShell        | Yes                           |
| Enforce script signature check  | No                            |
| Assignment                      | Tenant migration device group |

The user must be signed in and OneDrive must be configured when the script runs.

## Readiness Results

The script records each task as:

* `SUCCESS`
* `FAILURE`
* `WARNING`
* `INFO`

Example output:

```text
SUCCESS | Edge bookmarks backed up
SUCCESS | Chrome bookmarks backed up
SUCCESS | Downloads backed up
FAILURE | Chrome password export not found
```

The final Intune output follows this format:

```text
READY=True;SERIAL=ABC1234;FAILED=None
```

or:

```text
READY=False;SERIAL=ABC1234;FAILED=ChromePasswords
```

## Validation

Before wiping the device, confirm:

* The serial-number backup folder is present in OneDrive
* `Migration.log` shows successful results
* `MigrationReadiness.json` shows the device is ready
* Edge and Chrome bookmarks are present
* Edge and Chrome password exports are present
* Downloads are backed up
* The BitLocker recovery key file is present
* OneDrive has completed syncing the backup folder

## Security

The following files contain sensitive information:

```text
Edge Passwords.csv
Chrome Passwords.csv
BitLocker Recovery Key.txt
```

The password CSV files contain readable passwords. These files should be deleted after the migration and password import are complete.
