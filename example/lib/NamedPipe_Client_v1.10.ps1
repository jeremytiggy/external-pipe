Write-Host "[NamedPipe_Client] Loading library..." -ForegroundColor Gray
# ------------------------------------------------------------------------------------------------------------------------------------------------------
# Windows IPC Named Pipe Client Definitions ---------------------------------
# Import Windows API function for non-blocking pipe check
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class PipeUtils {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool PeekNamedPipe(
        IntPtr hNamedPipe,
        byte[] lpBuffer,
        uint nBufferSize,
        out uint lpBytesRead,
        out uint lpTotalBytesAvail,
        out uint lpBytesLeftThisMessage);
}
"@
Write-Host "[NamedPipe_Client] function TypeDefinition registered" -ForegroundColor Green
function Convert-ToAsciiSafe {
    param (
        [string]$InputString
    )

    if ([string]::IsNullOrWhiteSpace($InputString)) {
        return ''
    }

    # Normalize & strip diacritics
    $normalized = $InputString.Normalize([Text.NormalizationForm]::FormD)
    $ascii = -join ($normalized.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark'
    })

    # Remove anything not printable ASCII
    $ascii = ($ascii -replace '[^ -~]', '').Trim()

    return $ascii
}
Write-Host "[NamedPipe_Client] function [string]Convert-ToAsciiSafe -[string]InputString" -ForegroundColor Green
# Pipe Parameters
$Global:NamedPipe_Server_Name = 'PipeName'
$Global:NamedPipe_Server_Process = 'Process.exe'
$Global:NamedPipe_Server_ResponseDelay = 57 #milliseconds
$Global:NamedPipe_Server_ResponseTimeLimit = 5000 #milliseconds
# Pipe Communications Variables
$Global:NamedPipe_Client_ConnectedToServer = $false
$Global:NamedPipe_Server_Data = ''
$Global:NamedPipe_Server_Data_available = $false
$Global:NamedPipe_Client_Data = ''
$Global:NamedPipe_Client_Debug = $false
Write-Host "[NamedPipe_Client] Pipe Parameters registered" -ForegroundColor Green
# Pipe Communications Helper Functions
function NamedPipe_Client_PeekAtServer {
	# Use Windows API to check for data without blocking
    $Global:NamedPipe_Server_Data_available = $false
	$bytesRead = 0
	$bytesAvailable = 0
	$bytesLeft = 0
	
	$success = [PipeUtils]::PeekNamedPipe(
		$Global:NamedPipe_Client_ServerReader.SafePipeHandle.DangerousGetHandle(),
		$null,
		0,
		[ref]$bytesRead,
		[ref]$bytesAvailable,
		[ref]$bytesLeft
	)
	
	if (-not $success) {
		$lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
		Write-Host "[NamedPipe_Client_PeekAtServer]: FAULT - Win32 error code $lastError" -ForegroundColor Red
		return -1
	}
	if ($success -and $bytesAvailable -gt 0) {		
		$Global:NamedPipe_Server_Data_available = $true
		if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_PeekAtServer]: Found $bytesAvailable bytes available" }
		return $bytesAvailable
	}
	else {
        if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_PeekAtServer]: WARNING - Connected, but no data available (Bytes available: $bytesAvailable)" -ForegroundColor Yellow }
		return 0
	}

}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_PeekAtServer registered" -ForegroundColor Green
function NamedPipe_Client_ReadFromServer {
	if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_ReadFromServer]: Attempting Peek then Read" }
	$bytesAvailable = (NamedPipe_Client_PeekAtServer)

	if ($bytesAvailable -gt 0) {
		# Read the available data
		$bytesRead = 0
		$buffer = New-Object byte[] $bytesAvailable
		$bytesRead = $Global:NamedPipe_Client_ServerReader.Read($buffer, 0, $bytesAvailable)
		
		if ($bytesRead -gt 0) {
			$linesRead = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead)
			$lineRead = $linesRead.Trim() -replace "`r|`n", ""
			$Global:NamedPipe_Server_Data = $lineRead
			if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_ReadFromServer]: Data From Server: $($lineRead)" }
			return $lineRead
		}
		else {            
			Write-Host "[NamedPipe_Client_ReadFromServer]: FAULT - Failed to read data after successful peek" -ForegroundColor Red 
			return $null
		}
	}
	else {
        Write-Host "[NamedPipe_Client_ReadFromServer]: WARNING - No data available (Bytes available: $bytesAvailable)" -ForegroundColor Yellow
		return $null
	}
	return $null
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_ReadFromServer registered" -ForegroundColor Green
function NamedPipe_Client_WriteToServer {
	param (
        [string]$ClientDataString
    )
	$safeAsciiClientData = Convert-ToAsciiSafe -InputString $ClientDataString
	$Global:NamedPipe_Client_Data = $safeAsciiClientData
	if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_WriteToServer ]: Sending Data: $($Global:NamedPipe_Client_Data)" }
    
	$Global:NamedPipe_Client_ServerWriter.WriteLine($Global:NamedPipe_Client_Data)
	
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_WriteToServer registered" -ForegroundColor Green
function NamedPipe_Client_PullServerData {
	param (
		[string]$requestString
	)
	if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_PullServerData]: Request: $($requestString)" }

	NamedPipe_Client_WriteToServer -ClientDataString $requestString

	# Wait for what should be an immediate response
	$bytesAvailable = 0
	$responseTime = 0
	$NoData_And_NotTimedOut = $true
	if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_PullServerData]: Beginning poll for server response. Timeout at $($Global:NamedPipe_Server_ResponseTimeLimit)ms" }
	while ($NoData_And_NotTimedOut) {
		Start-Sleep -Milliseconds $Global:NamedPipe_Server_ResponseDelay
		$responseTime+= $Global:NamedPipe_Server_ResponseDelay
		$bytesAvailable = NamedPipe_Client_PeekAtServer
		if ($bytesAvailable -ge 1) { $NoData_And_NotTimedOut = $false }
		if ($responseTime -ge $Global:NamedPipe_Server_ResponseTimeLimit) { $NoData_And_NotTimedOut = $false }
		if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_PullServerData]: Pausing for $($Global:NamedPipe_Server_ResponseDelay)ms to give server time to respond" }
	}
	if ($Global:NamedPipe_Client_Debug -eq $true) { 
		Write-Host "[NamedPipe_Client_PullServerData]: Waited $($responseTime) milliseconds" }
	# Start-Sleep -Milliseconds $Global:NamedPipe_Server_ResponseDelay

	$responseString = NamedPipe_Client_ReadFromServer
    
	if ($responseString -ne $null) {
		if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_PullServerData]: Response: $($responseString)" }
		return $responseString
	} else {
		Write-Host "[NamedPipe_Client_PullServerData]: FAULT - No Server Response to Request: $($requestString)" -ForegroundColor Red
		return $null
	}
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_PullServerData registered" -ForegroundColor Green
function NamedPipe_Client_CloseServerConnection {
	if ($Global:NamedPipe_Client_ServerWriter -ne $null) { 
		try { 
			$Global:NamedPipe_Client_ServerWriter.Dispose() 
			if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_CloseServerConnection]: StreamWriter disposed OK"}
		} 
		catch { 
			Write-Host "[NamedPipe_Client_CloseServerConnection]: FAULT - Problem disposing of StreamWriter"
		} 
	}
	$writerDisposed = $Global:NamedPipe_Client_ServerWriter -eq $null
	if ($Global:NamedPipe_Client_ServerReader -ne $null) { 
		try { 
			$Global:NamedPipe_Client_ServerReader.Dispose() 
			if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_CloseServerConnection]: StreamReader disposed OK"}
		} 
		catch { 
			Write-Host "[NamedPipe_Client_CloseServerConnection]: FAULT - Problem disposing of StreamReader"
		}
	}
	
	$Global:NamedPipe_Client_ConnectedToServer = $false
}

function NamedPipe_Client_ConnectToServer {
    Write-Host "[NamedPipe_Client_ConnectToServer]: Connecting to pipe: $Global:NamedPipe_Server_Name"
	try {
		if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_ConnectToServer]: Creating NamedPipeClientStream" }
		$Global:NamedPipe_Client_ServerReader = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Global:NamedPipe_Server_Name, [System.IO.Pipes.PipeDirection]::InOut)
		if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_ConnectToServer]: Connecting..." }
		$Global:NamedPipe_Client_ServerReader.Connect(5000)		
		if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_ConnectToServer]: Creating StreamWriter" }
		$Global:NamedPipe_Client_ServerWriter = New-Object System.IO.StreamWriter($Global:NamedPipe_Client_ServerReader, [System.Text.Encoding]::ASCII)
		if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_ConnectToServer]: Setting AutoFlush" }
		$Global:NamedPipe_Client_ServerWriter.AutoFlush = $true
		if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_ConnectToServer]: Pipe $Global:NamedPipe_Server_Name Connected successfully!" -ForegroundColor Green}
		return $true
	} catch {
		Write-Host "[NamedPipe_Client_ConnectToServer]: FAULT - Pipe $Global:NamedPipe_Server_Name Connection Failed" -ForegroundColor Red
		return $false
	}
	return $false
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_ConnectToServer registered" -ForegroundColor Green
function NamedPipe_Client_Startup {
    
    $ProcessName = $Global:NamedPipe_Server_Process
	$PipeName = $Global:NamedPipe_Server_Name
	
	$stillTryingToConnect = $true
	while ($stillTryingToConnect) { 
		# Check if the process is running
		$processRunning = $false
		if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) { $processRunning = $true }
		Write-Host "[NamedPipe_Client_Startup]: Pipe: $($Global:NamedPipe_Server_Name)" -ForegroundColor Cyan
		
		Write-Host -NoNewLine "[NamedPipe_Client_Startup]: Process: $($Global:NamedPipe_Server_Process) - " -ForegroundColor Cyan
		if ($processRunning) { Write-Host "RUNNING" -ForegroundColor Green }
		else { Write-Host "NOT RUNNING" -ForegroundColor Red }	
		
		$connectWithoutPrompt = $processRunning -and ($Global:NamedPipe_Client_Debug -ne $true)
		# If the debug is turned off, and the process is running, go ahead and try to connect
		if ($connectWithoutPrompt) {
			try { 
				$Global:NamedPipe_Client_ConnectedToServer = NamedPipe_Client_ConnectToServer 
				if ($Global:NamedPipe_Client_ConnectedToServer) { 
					Write-Host "[NamedPipe_Client_Startup]: Connected to Pipe $($Global:NamedPipe_Server_Name) successfully!" -ForegroundColor Green
				}
			} 
			catch {	Write-Host "[NamedPipe_Client_Startup]: ERROR. Failed to connect to pipe: $($_.Exception.Message)" -ForegroundColor Red }
			$stillTryingToConnect = $Global:NamedPipe_Client_ConnectedToServer -eq $false
		}
		Write-Host "[NamedPipe_Client_Startup]: Connected: $($Global:NamedPipe_Client_ConnectedToServer)" -ForegroundColor Cyan
		
		# If the pipe didn't connect, or if debugging is enabled...
		if ($Global:NamedPipe_Client_ConnectedToServer -ne $true) {
			Write-Host "[NamedPipe_Client_Startup]: Would you like to attempt to OPEN the named pipe $($PipeName), change the TARGET pipe name before opening, or work OFFLINE?"
			Write-Host -NoNewLine "[NamedPipe_Client_Startup] (open|target=$($PipeName)@$($ProcessName)|offline|exit)> "
			$cmd = Read-Host
			if ($cmd -eq '') { exit 1 }
			if ($cmd -ne '') {
				if ($cmd -eq 'exit') { exit 1 }
				elseif (($cmd -eq 'open') -or ($cmd -eq 'target')) { 
					if ($cmd -eq 'target') {
						$makeEdits = $true
						while ($makeEdits -eq $true) {
							Write-Host "[NamedPipe_Client_Startup]: Enter target Process & Pipe. Leave blank to use existing value" -ForegroundColor White
							Write-Host -NoNewLine "[$($ProcessName)] Enter Process Name without extension: > "
							$NewProcessName = Read-Host
							if ($NewProcessName -eq '') { $NewProcessName = $ProcessName }
							Write-Host "[NamedPipe_Client_Startup]: Enter Pipe Name. Leave blank to use existing value" -ForegroundColor White
							Write-Host -NoNewLine "[$($PipeName)] Enter Pipe Name: > "
							$NewPipeName = Read-Host
							if ($NewPipeName -eq '') { $NewPipeName = $PipeName }
							Write-Host "[NamedPipe_Client_Startup]: Proposed New Target: $($NewPipeName)@$($NewProcessName)."
							if (Get-Process -Name $NewProcessName -ErrorAction SilentlyContinue)
							{ Write-Host "[NamedPipe_Client_Startup]: $NewProcessName is running" -ForegroundColor Green }
							else { Write-Host "[NamedPipe_Client_Startup]: $NewProcessName is not running" -ForegroundColor Yellow }
							Write-Host "[NamedPipe_Client_Startup]: CONFIRM and open connection, EDIT pipe & process, or DISCARD changes?"
							Write-Host -NoNewLine "[NamedPipe_Client_Startup]: (confirm|edit|discard)> "
							$reviewEditsDecision = Read-Host
							if ($reviewEditsDecision -eq 'confirm') {
								$Global:NamedPipe_Server_Process = $NewProcessName
								$Global:NamedPipe_Server_Name = $NewPipeName
								Write-Host "[NamedPipe_Client_Startup]: Applying changes. Using New Target: $($NewPipeName)@$($NewProcessName)" -ForegroundColor Yellow
								$makeEdits = $false
							}
							elseif ($reviewEditsDecision -eq 'edit') {
								$ProcessName = $NewProcessName
								$PipeName = $NewPipeName
								$makeEdits = $true
							}
							else {
								#discard or invalid entry
								$ProcessName = $Global:NamedPipe_Server_Process
								$PipeName = $Global:NamedPipe_Server_Name
								Write-Host "[NamedPipe_Client_Startup]: Discarding changes. Using Initial Target: $($PipeName)@$($ProcessName)" -ForegroundColor Yellow
								$makeEdits = $false
							}
							#Loop if $makeEdits = $true (edit)
						}
					}
					
					# Open Pipe Connection
					try {
						$Global:NamedPipe_Client_ConnectedToServer = NamedPipe_Client_ConnectToServer
						$stillTryingToConnect = ($Global:NamedPipe_Client_ConnectedToServer -ne $true)
						
					} catch {
						Write-Host "[NamedPipe_Client_Startup]: ERROR. Failed to connect to pipe: $($_.Exception.Message)" -ForegroundColor Red
						$stillTryingToConnect = $true
					}	
				}
				elseif ($cmd -eq 'offline') { 
					Write-Host "[NamedPipe_Client_Startup]: Continuing in offline mode. No Named Pipe Communications initiated." -ForegroundColor Yellow
					$stillTryingToConnect = $false
				}
				else { 
					Write-Host '[NamedPipe_Client_Startup]: Exiting...' 
					$stillTryingToConnect = $false
					exit 1
				}
			} #end of if (-ne '')
			
		}
	} #end while still trying to connect
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_Startup registered" -ForegroundColor Green
# Windows IPC Named Pipe Client Definitions^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# ------------------------------------------------------------------------------------------------------------------------------------------------------
# When using the Windows IPC Named Pipe Client, make sure to set $Global:NamedPipe_Server_Name to match the pipe name used
function NamedPipe_Client_loaded {
	Write-Host "[NamedPipe_Client] Windows IPC Named Pipe Client library loaded and ready to use." -ForegroundColor Green
}

Write-Host "[NamedPipe_Client] Library Loaded" -ForegroundColor Gray
