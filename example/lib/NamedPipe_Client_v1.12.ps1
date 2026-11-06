Write-Host "[NamedPipe_Client] Loading library..." -ForegroundColor Gray
# ------------------------------------------------------------------------------------------------------------------------------------------------------
# Windows IPC Named Pipe Client Definitions ---------------------------------
# Global Variables
# Pipe Parameters
$Global:NamedPipe_Client_AvailablePipeSelection_Filter = $true
$Global:NamedPipe_Client_AutomaticallySelectUniqueFilteredPipeServerName = $true
$Global:NamedPipe_Client_AvailablePipeSelection_NamePattern = '^[ZUG]ZD(_\d+)?$'
$Global:NamedPipe_Server_Name = 'Select' # can be replaced with actual pipe name if known/static
$Global:NamedPipe_Server_Process = 'Process'
$Global:NamedPipe_Server_ResponseDelay = 57 #milliseconds
$Global:NamedPipe_Server_ResponseTimeLimit = 5000 #milliseconds
# Pipe Communications Variables
$Global:NamedPipe_Client_ConnectedToServer = $false
$Global:NamedPipe_Server_Data = ''
$Global:NamedPipe_Server_Data_available = $false
$Global:NamedPipe_Client_Data = ''
$Global:NamedPipe_Client_Debug = $false
Write-Host "[NamedPipe_Client] Pipe Parameters registered" -ForegroundColor Green

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
Write-Host "[NamedPipe_Client] public class PipeUtils registered" -ForegroundColor Green
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
			$Global:NamedPipe_Client_ServerWriter = $null
			if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_CloseServerConnection]: StreamWriter disposed OK"}
		} 
		catch { 
			Write-Host "[NamedPipe_Client_CloseServerConnection]: FAULT - Problem disposing of StreamWriter"
		} 
	}
	if ($Global:NamedPipe_Client_ServerReader -ne $null) { 
		try { 
			$Global:NamedPipe_Client_ServerReader.Dispose() 
			$Global:NamedPipe_Client_ServerReader = $null
			if ($Global:NamedPipe_Client_Debug -eq $true) { Write-Host "[NamedPipe_Client_CloseServerConnection]: StreamReader disposed OK"}
		} 
		catch { 
			Write-Host "[NamedPipe_Client_CloseServerConnection]: FAULT - Problem disposing of StreamReader"
		}
	}
	
	$Global:NamedPipe_Client_ConnectedToServer = $false
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_CloseServerConnection registered" -ForegroundColor Green
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
Write-Host "[NamedPipe_Client] function NamedPipe_Client_ConnectToServer registered registered" -ForegroundColor Green
function NamedPipe_Client_GetAvailableList {
    $pipeList = [System.Collections.Generic.List[string]]::new()
    try {
        $enumerator = [System.IO.Directory]::EnumerateFiles("\\.\pipe\").GetEnumerator()
        $retries = 10
        while ($true) {
            try {
                if (-not $enumerator.MoveNext()) {
                    break
                }
                $pipeList.Add($enumerator.Current)
                $retries = 10
            } catch [System.ArgumentException] {
                $retries--
                if ($retries -eq 0) {
                    Write-Warning "[NamedPipe_Client_GetAvailableList]: Skipped too many pipes in a row, stopping enumeration."
                    break
                }
                continue
            }
        }
    } catch {
        Write-Error "[NamedPipe_Client_GetAvailableList]: Unexpected error during enumeration: $_"
        try {
            Write-Warning "[NamedPipe_Client_GetAvailableList]: Falling back to [System.IO.Directory]::GetFiles"
            $fallback = [System.IO.Directory]::GetFiles("\\.\pipe\")
            return $fallback | ForEach-Object {
                if ($_.StartsWith("\\.\pipe\")) { $_.Substring(9) } else { $_ }
            }
        } catch {
            Write-Error "[NamedPipe_Client_GetAvailableList]: Fallback also failed: $_"
            return @()
        }
    }

    return $pipeList | ForEach-Object {
        if ($_.StartsWith("\\.\pipe\")) {
            $_.Substring(9)
        } else {
            $_
        }
    }
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_GetAvailableList registered" -ForegroundColor Green
function NamedPipe_Client_SelectPipeServerFromAvailable {
	Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Looking for accessible pipes..." -ForegroundColor Gray

	$prefiltered_list = NamedPipe_Client_GetAvailableList
	$prefiltered_list_count = $prefiltered_list.Count
	Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: $($prefiltered_list_count) accessible pipes found." -ForegroundColor Gray
	if ($prefiltered_list_count -eq 0) {
		Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: No accessible pipes found." -ForegroundColor Yellow
		if ($Global:NamedPipe_Client_Debug -eq $true) {
			Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Pre-Filtered List:" -ForegroundColor White
			foreach ($p in $prefiltered_list) {
				Write-Host "  $p" -ForegroundColor White
			}
		}
		return "NoPipesAccessible"
	}
	
	#further filter list if requested
	$invalid_filter = [string]::IsNullOrWhiteSpace($Global:NamedPipe_Client_AvailablePipeSelection_NamePattern)
	$valid_filter = -not $invalid_filter
	$filter_pipe_names_list = $valid_filter -and $Global:NamedPipe_Client_AvailablePipeSelection_Filter
	$invalid_filter_error = $invalid_filter -and $Global:NamedPipe_Client_AvailablePipeSelection_Filter
	if ($invalid_filter_error) { Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Pipe Name Filter is blank. Using un-filtered list." -ForegroundColor Yellow }
	if ($filter_pipe_names_list) {
		Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Filter Expression:  $($Global:NamedPipe_Client_AvailablePipeSelection_NamePattern)" -ForegroundColor Gray
		$filtered_list = @($prefiltered_list | Where-Object {$_ -match $Global:NamedPipe_Client_AvailablePipeSelection_NamePattern})
		$filtered_list_count = $filtered_list.Count
		Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Filter applied. $($filtered_list_count) accessible pipes returned." -ForegroundColor Gray
		if ($filtered_list_count -eq 0) {
			if ($Global:NamedPipe_Client_Debug -eq $true) {
				Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Un-Filtered List:" -ForegroundColor White
				foreach ($p in $prefiltered_list) {
					Write-Host "  $p" -ForegroundColor White
				}
			}
			return "NoPipesAccessible"
		}
		$pipe_names_list = $filtered_list
	} else {
		$pipe_names_list = $prefiltered_list
	}	
	$number_of_pipes_found = $pipe_names_list.Count


	if ($Global:NamedPipe_Client_AutomaticallySelectUniqueFilteredPipeServerName -and ($number_of_pipes_found -eq 1)) {
		$pipe_name = $pipe_names_list[0]
		Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Automatically selecting the one, filtered, accessible pipe, '$($pipe_name)'" -ForegroundColor Green
		return $pipe_name
	}
	Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Found $number_of_pipes_found accessible pipes."
	Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Please select a number from the list:"
	for ($i = 0; $i -lt $number_of_pipes_found; $i++) {
        $pipe_number = $i + 1 
        Write-Host "$($pipe_number) - $($pipe_names_list[$i])" -ForegroundColor Cyan
    }
	Write-Host "0 - None of these" -ForegroundColor Cyan
	
	do {
        Write-Host -NoNewLine "[NamedPipe_Client_SelectPipeServerFromAvailable] (Line #)> " -ForegroundColor White
		$line_number_entry = Read-Host
		
    } until (
        $line_number_entry -match '^\d+$' -and
        [int]$line_number_entry -ge 0 -and
        [int]$line_number_entry -le $number_of_pipes_found
    )
	$line_number = [int]$line_number_entry
	if ($line_number -eq 0) {
		Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: No pipe selected." -ForegroundColor Yellow
		return "NoPipeSelected"
	}
	else {
		$pipe_names_list_index = $line_number - 1
		$pipe_name = $pipe_names_list[$pipe_names_list_index]
		Write-Host "[NamedPipe_Client_SelectPipeServerFromAvailable]: Pipe selected: $($pipe_name)" -ForegroundColor Green
		return $pipe_name
	}
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_SelectPipeServerFromAvailable" -ForegroundColor Green
function NamedPipe_Client_PipeAvailable {
	param(
        [string]$Name
    )
	$pipeNameProvided = (-not [string]::IsNullOrWhiteSpace($Name))
	if ($pipeNameProvided) {
		$pipe_server_name = $Name.Trim()
	} else {
		if ($Global:NamedPipe_Server_Name) {
			$pipe_server_name = $Global:NamedPipe_Server_Name.Trim()
		} else {
			$pipe_server_name = ""
		}
	}
	
	#if ($pipe_server_name -match '\\') { $pipe_server_name = Split-Path $pipe_server_name -Leaf }
	if ($pipe_server_name -match '^\\\\\.\\\\pipe\\\\') {
        $pipe_server_name = $pipe_server_name.Substring(9)
    }
	Write-Host "[NamedPipe_Client_PipeAvailable]: Validating Pipe '$($pipe_server_name)'"
	# Quick check for empty
    if ([string]::IsNullOrWhiteSpace($pipe_server_name)) {
        Write-Host "[NamedPipe_Client_PipeAvailable]: Server Name is blank" -ForegroundColor Red
        return $false
    } else {
		<#
		$system_IO_Directory_GetFiles_pipes = [System.IO.Directory]::GetFiles("\\.\pipe\")
		# $Global:NamedPipe_Server_Name will always be just the name, not the backslashes etc.
		$pipe_names_list = $system_IO_Directory_GetFiles_pipes | ForEach-Object { Split-Path $_ -Leaf }
		#>
		$pipe_names_list = NamedPipe_Client_GetAvailableList
		$number_of_pipes_found = $pipe_names_list.Count

		if ($number_of_pipes_found -eq 0) {
			Write-Host "[NamedPipe_Client_PipeAvailable]: No accessible pipes found at all; Cannot validate Pipe '$($pipe_server_name)'" -ForegroundColor Yellow
			return $false
		} else {
			#$pipe_name_found = $false
			$pipe_name_found = $pipe_server_name -in $pipe_names_list

			if ($pipe_name_found) {
				Write-Host "[NamedPipe_Client_PipeAvailable]: Matching pipe found" -ForegroundColor Gray
			} else {
				Write-Host "[NamedPipe_Client_PipeAvailable]: No matching pipe found" -ForegroundColor Gray
				if ($Global:NamedPipe_Client_Debug -eq $true) {
					Write-Host "[NamedPipe_Client_PipeAvailable]: Full List of Accessible, Unmatching Pipes:" -ForegroundColor Gray
					foreach ($p in $pipe_names_list) {
						Write-Host "  $p" -ForegroundColor Gray
					}
				}
			}
			Write-Host -NoNewLine "[NamedPipe_Client_PipeAvailable]: Pipe '$($pipe_server_name)' " -ForegroundColor White
			if ($pipe_name_found -eq $true) {
				Write-Host "AVAILABLE" -ForegroundColor GREEN
				return $true
			} else {
				Write-Host "UNAVAILABLE" -ForegroundColor YELLOW
				return $false
			}
		}
	}
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_PipeAvailable registered" -ForegroundColor Green
function NamedPipe_Client_ProcessRunning {
	param (
		[string]$Name
	)
	$processRunning = $false
	if (Get-Process -Name $Name -ErrorAction SilentlyContinue) { $processRunning = $true }
	Write-Host -NoNewLine "[NamedPipe_Client_ProcessRunning]: Process: $($Name) - " -ForegroundColor Cyan
	if ($processRunning) { Write-Host "RUNNING" -ForegroundColor Green }
	else { Write-Host "NOT RUNNING" -ForegroundColor Red }	
	return $processRunning
}
Write-Host "[NamedPipe_Client] function NamedPipe_Client_ProcessRunning registered" -ForegroundColor Green
function NamedPipe_Client_Startup {

    	
	$stillTryingToConnect = $true
	while ($stillTryingToConnect) { 
		# Check if the process is running
		if ($Global:NamedPipe_Server_Process) {
			$Global:NamedPipe_Server_Process = $Global:NamedPipe_Server_Process.Trim() -replace '\.exe$', ''
		} else { $Global:NamedPipe_Server_Process = "uninitialized_process_name" }
		Write-Host "[NamedPipe_Client_Startup]: Process: $($Global:NamedPipe_Server_Process)" -ForegroundColor Cyan
		$processRunning = NamedPipe_Client_ProcessRunning -Name $Global:NamedPipe_Server_Process
		
		if ($Global:NamedPipe_Server_Name) {
			$Global:NamedPipe_Server_Name = $Global:NamedPipe_Server_Name.Trim()
			# if ($Global:NamedPipe_Server_Name -match '\\') { $Global:NamedPipe_Server_Name = Split-Path $Global:NamedPipe_Server_Name -Leaf }
		} else { $Global:NamedPipe_Server_Name = "uninitialized_pipe_name" }
		$pipe_name_empty = ($Global:NamedPipe_Server_Name -eq "") -or ($Global:NamedPipe_Server_Name -eq "uninitialized_pipe_name")
		if ($pipe_name_empty) {
			Write-Host "[NamedPipe_Client_Startup]: Pipe Name is empty. Select a new Pipe Name." -ForegroundColor Yellow
		}
		$pipe_select_requested = ($Global:NamedPipe_Server_Name -eq "Select") -or ($Global:NamedPipe_Server_Name -eq "select")
		$pipe_select = $pipe_name_empty -or $pipe_select_requested
		if ($pipe_select -eq $true) {
			$Global:NamedPipe_Server_Name = NamedPipe_Client_SelectPipeServerFromAvailable
		}
		$initial_pipe_select_unsuccessful = ($Global:NamedPipe_Server_Name -eq "NoPipesAccessible") -or ($Global:NamedPipe_Server_Name -eq "NoPipeSelected")
		if ($initial_pipe_select_unsuccessful) {
			Write-Host "[NamedPipe_Client_Startup]: Pipe Name selection unsuccessful." -ForegroundColor Yellow
			$pipeAvailable = $false
		} else {
			Write-Host "[NamedPipe_Client_Startup]: Pipe: $($Global:NamedPipe_Server_Name)" -ForegroundColor Cyan
			$pipeAvailable = NamedPipe_Client_PipeAvailable	
		}
		
		$connectWithoutPrompt = $pipeAvailable -and ($Global:NamedPipe_Client_Debug -ne $true)
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
			Write-Host "[NamedPipe_Client_Startup]: Would you like to attempt to OPEN the named pipe $($Global:NamedPipe_Server_Name), change the TARGET pipe name before opening, or work OFFLINE?"
			do {
				Write-Host -NoNewLine "[NamedPipe_Client_Startup] (open|target=$($Global:NamedPipe_Server_Name)@$($Global:NamedPipe_Server_Process)|offline|exit)> "
				$cmd = Read-Host
			} until ( $cmd -ne '' )
			
			if ($cmd -eq 'exit') { exit 1 }
			elseif (($cmd -eq 'open') -or ($cmd -eq 'target')) { 
				if ($cmd -eq 'target') {
					$makeEdits = $true
					while ($makeEdits -eq $true) {
						
						Write-Host "[NamedPipe_Client_Startup: target]: Enter target Process & Pipe. Leave blank to use existing values" -ForegroundColor White
						Write-Host -NoNewLine "[$($Global:NamedPipe_Server_Process)] Enter Process Name without extension: > "
						$NewProcessName_Entry = Read-Host
						$NewProcessName_Entry = $NewProcessName_Entry.Trim() -replace '\.exe$', ''
						if ($NewProcessName_Entry -ne '') { $NewProcessName = $NewProcessName_Entry }
						else { $NewProcessName = $Global:NamedPipe_Server_Process }
						$proposedProcessRunning = NamedPipe_Client_ProcessRunning -Name $NewProcessName
						if (-not $proposedProcessRunning) {
							Write-Host "[NamedPipe_Client_Startup: target]: If the proposed pipe server is currently running, consider revising your entry." -ForegroundColor Yellow
						}
						
						$NewPipeName_Selection = NamedPipe_Client_SelectPipeServerFromAvailable
						$manuallyEnterPipeName = ( $NewPipeName_Selection -eq "NoPipesAccessible" ) -or ( $NewPipeName_Selection -eq "NoPipeSelected" )
						if ($manuallyEnterPipeName) {
							Write-Host "[NamedPipe_Client_Startup: target]: Enter Pipe Name. Leave blank to use existing value" -ForegroundColor White
							Write-Host -NoNewLine "[$($Global:NamedPipe_Server_Name)] Enter Pipe Name: > "
							$NewPipeName_Entry = Read-Host
							if ($NewPipeName_Entry -ne '') { $NewPipeName = $NewPipeName_Entry }
							else { $NewPipeName = $Global:NamedPipe_Server_Name }
						}
						else { $NewPipeName = $NewPipeName_Selection }
						$proposedPipeAvailable = NamedPipe_Client_PipeAvailable -Name $NewPipeName
						if (-not $proposedPipeAvailable) {
							Write-Host "[NamedPipe_Client_Startup: target]: If the proposed pipe server is currently running, consider revising your entry." -ForegroundColor Yellow
						}
						
						Write-Host "[NamedPipe_Client_Startup: target]: Proposed New Target: $($NewPipeName)@$($NewProcessName)."
						
						Write-Host "[NamedPipe_Client_Startup: target]: CONFIRM and open connection, EDIT pipe & process, or DISCARD changes?"
						Write-Host -NoNewLine "[NamedPipe_Client_Startup: target]: (confirm|edit|discard)> "
						$reviewEditsDecision = Read-Host
						if ($reviewEditsDecision -eq 'confirm') {
							$Global:NamedPipe_Server_Process = $NewProcessName
							$Global:NamedPipe_Server_Name = $NewPipeName
							Write-Host "[NamedPipe_Client_Startup]: Applying changes. Using New Target: $($NewPipeName)@$($NewProcessName)" -ForegroundColor Cyan
							$makeEdits = $false
						}
						elseif ($reviewEditsDecision -eq 'edit') {
							Write-Host "[NamedPipe_Client_Startup: target]: Discarding proposed changes" -ForegroundColor Cyan
							$NewProcessName_Entry = $null
							$NewProcessName = $null
							$NewPipeName_Selection = $null
							$NewPipeName_Entry = $null
							$NewPipeName = $null
							$makeEdits = $true
						}
						else {
							#discard or invalid entry
							Write-Host "[NamedPipe_Client_Startup: target]: Discarding changes. Using Initial Target: $($Global:NamedPipe_Server_Name)@$($Global:NamedPipe_Server_Process)" -ForegroundColor Cyan
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
