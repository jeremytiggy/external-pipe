# ------------------------------------------------------------------------------------------------------------------------------------------------------
# This function searches for the latest version of a script with a given base name in a specified directory, loads it, and returns the file info object of the loaded script. 
# The expected naming convention for the scripts is BaseName_vX.X.ps1, where X.X represents the version number. If no matching scripts are found, an error is thrown.
# The -Path parameter is optional and defaults to the current directory if not provided.
function Get-LatestVersionedScript {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$BaseName,

        [string]$Path = "."
    )

    Write-Verbose "Searching for latest version of $BaseName in '$Path'"

    $pattern = "${BaseName}_v*.ps1"

    # Try versioned files first
    $scripts = Get-ChildItem -Path $Path -Filter $pattern -File -ErrorAction SilentlyContinue

    if ($scripts) {

        $latest = $scripts |
            Sort-Object {
                if ($_.Name -match 'v(\d+(\.\d+)+)') {
                    [version]$matches[1]
                }
                else {
                    [version]"0.0"
                }
            } -Descending |
            Select-Object -First 1

        return $latest
    }

    # Fallback to non-versioned file
    $baseFile = Join-Path $Path "${BaseName}.ps1"

    if (Test-Path $baseFile) {
        return Get-Item $baseFile
    }

    throw "No matching versioned or base script found for '$BaseName' in '$Path'."
}
# Include library for pipe communication functions and variables
# Include WindowsIPCNamedPipeClient_v1.0.ps1 pipe communication functions and variables
try {

    $script = Get-LatestVersionedScript -BaseName "NamedPipe_Client"

    Write-Host "Loading $($script.Name)..."

    . $script.FullName

}
catch {

    Write-Host "Failed to load latest NamedPipe_Client."
    Write-Host $_
    exit 1

}
NamedPipe_Client_loaded

# Pipe Client Startup -------------------------------
$Global:NamedPipe_Server_Name = 'GZD'
$Global:NamedPipe_Server_Process = 'powershell'
$Global:NamedPipe_Server_ResponseDelay = 57 #milliseconds
$Global:NamedPipe_Client_Debug = $true
# Pipe Client Startup ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Write-Host "`n[Startup]: Starting communications..." -ForegroundColor White
NamedPipe_Client_Startup
# Communication Status After Startups
if ($Global:NamedPipe_Client_ConnectedToServer) {
    Write-Host "[Startup]: Named Pipe Client connected to Server." -ForegroundColor Green
} else {
    Write-Host "[Startup]: Named Pipe Client not connected to Server." -ForegroundColor Yellow
}
Write-Host "[Startup]: Starting main loop..." -ForegroundColor White
try {
    while ($true) {
		$userCommandPromptString = "[Main Loop]: Enter Command (exit|"
		if ($Global:NamedPipe_Client_ConnectedToServer -ne $true) {
			Write-Host "[Main Loop]: The Pipe connection isn't made, but you can 'open' it at any time." -ForegroundColor Yellow
			$userCommandPromptString += "open)> "
			
		} else {
			Write-Host "[Main Loop]: Since the Pipe is Open, you can initiate a PULL from the named pipe server." -ForegroundColor Green
			$userCommandPromptString += "peek|read|pull|close)> "
		}
		Write-Host -NoNewline $userCommandPromptString
		$cmd = Read-Host
		if ($cmd -ne '') {
			if ($cmd -eq 'exit') { exit 1 }
			elseif ($cmd -eq 'open') { NamedPipe_Client_Startup }
			elseif ($cmd -eq 'peek') { 
				$bytes = NamedPipe_Client_PeekAtServer 
				Write-Host "[Peek]: $($bytes) available to read from Server."
			}
			elseif ($cmd -eq 'read') { 
				$Global:NamedPipe_Server_Data = NamedPipe_Client_ReadFromServer 
				Write-Host "[Read]: Data: $($Global:NamedPipe_Server_Data)"
			}
			elseif ($cmd -eq 'write') { 
				Write-Host -NoNewLine "[Write]: Enter Data to Write to Server> "
				$Global:NamedPipe_Client_Data = Read-Host
				NamedPipe_Client_WriteToServer -ClientDataString $Global:NamedPipe_Client_Data
				Write-Host "[Write]: Data sent. Check for response with Peek or Read."
			}
			elseif ($cmd -eq 'pull') {
				Write-Host -NoNewLine "[Pull]: Enter Request to Server> "
				$Global:NamedPipe_Client_Data = Read-Host
				$Global:NamedPipe_Server_Data = NamedPipe_Client_PullServerData -requestString $Global:NamedPipe_Client_Data
				Write-Host "[Pull]: Response: $($Global:NamedPipe_Server_Data)"
			}
			elseif ($cmd -eq 'close') { 
				Write-Host "[Close]: Attempting to close pipe."
				NamedPipe_Client_CloseServerConnection
			}
			
		}
	}
}
catch {
	Write-Host "SERVER ERROR: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    # Terminate Pipe
    NamedPipe_Client_CloseServerConnection
    Write-Host "[Shutdown]: Pipe Disconnected"
}
