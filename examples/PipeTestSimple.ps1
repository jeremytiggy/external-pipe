$Global:pipeName = 'GZD'
$Global:readData = ''
$Global:writeData = ''
$Global:peekBytes = -1
$Global:CVAR_GET_Name = ''
$Global:CVAR_GET_Value = ''
$Global:CVAR_GET_Value_Raw = ''
$Global:CVAR_SET_Name = ''
$Global:CVAR_SET_Value = ''

$Global:CV_DataTypePrefix_String = 'CV_s'
$Global:CV_DataTypePrefix_Integer = 'CV_i'
$Global:CV_DataTypePrefix_FloatDouble = 'CV_f'
$Global:CV_DataTypePrefix_Boolean = 'CV_b'


# CVARs
$Global:CV_sTest = [string]'summon'
$Global:CV_iTest = [int]-123
$Global:CV_fTest = [float]1.23
$Global:CV_bTest = [bool]$false
$Global:CV_iPlayerHealth = [int]100


function printCVARs {
	Write-Host "CVARs:"
	Write-Host "CV_sTest `t $Global:CV_sTest"
	Write-Host "CV_iTest `t $Global:CV_iTest"
	Write-Host "CV_fTest `t $Global:CV_fTest"
	Write-Host "CV_bTest `t $Global:CV_bTest"
	Write-Host "CV_iPlayerHealth `t $Global:CV_iPlayerHealth"
}

function incomingDataIsServerRespondingToGET {
	$responseLine = $Global:readData
	if ($responseLine -match '^\s*"(.*?)"\s+is\s+"(.*?)"\s*$') { return $True }
	else { return $False}
}
function parseServerRespondingToGET {
	
	# Check if response to a CMD_CVAR_GET
	# Responses are formatted as: 
	# "CVAR_GET_Name" is "CVAR_GET_Value"
	# Using regular expressions to split out the items in between the quotes of the pattern.
	$responseLine = $Global:readData
	if ($responseLine -match '^\s*"(.*?)"\s+is\s+"(.*?)"\s*$') {
		$Global:CVAR_GET_Name  = $Matches[1]
		$Global:CVAR_GET_Value_String = $Matches[2]
		# Decide type based on prefix
		switch -Regex ($Global:CVAR_GET_Name) {
			'^CV_s' { $Global:CVAR_GET_Value = [string]$Global:CVAR_GET_Value_String }
			'^CV_i' { $Global:CVAR_GET_Value = [int]$Global:CVAR_GET_Value_String }
			'^CV_f' { $Global:CVAR_GET_Value = [float]$Global:CVAR_GET_Value_String }
			'^CV_b' { 
						if ($Global:CVAR_GET_Value_String -eq 'true') { $Global:CVAR_GET_Value = [bool]$True }
						elseif ($Global:CVAR_GET_Value_String -eq 'false') { $Global:CVAR_GET_Value = [bool]$False }
						elseif ($Global:CVAR_GET_Value_String -eq '1') { $Global:CVAR_GET_Value = [bool]$True }
						elseif ($Global:CVAR_GET_Value_String -eq '0') { $Global:CVAR_GET_Value = [bool]$False }
						else {$Global:CVAR_GET_Value = [bool]$False }
					}
			default { $Global:CVAR_GET_Value = $Global:CVAR_GET_Value_String } # fallback
		}
		$remoteCVAR_value = $Global:CVAR_GET_Value;
		
		# $localCVAR_Value = Get-Variable -Name $Global:CVAR_GET_Name -ValueOnly -Scope Global
		if (Test-Path "Variable:Global:$($Global:CVAR_GET_Name)") {
			$localCVAR_Value = Get-Variable -Name $Global:CVAR_GET_Name -ValueOnly -Scope Global
		} else {
			Write-Host "[GET]: Local CVAR ' $Global:CVAR_GET_Name ' is not declared explicitly in Script, but will attempt to create."
			$localCVAR_Value = "[NEW]"
			Set-Variable -Name $Global:CVAR_GET_Name -Value $localCVAR_Value -Scope Global
		}
		Set-Variable -Name $Global:CVAR_GET_Name -Value $remoteCVAR_value -Scope Global
		$localCVAR_finalValue = Get-Variable -Name $Global:CVAR_GET_Name -ValueOnly -Scope Global
		return "[GET]: `$Global:$Global:CVAR_GET_Name : $localCVAR_Value >> $remoteCVAR_value"
	}
	else {return "[GET]: No GET to parse]"}
	
}



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

function PeekPipe {
	# Use Windows API to check for data without blocking
	$Global:peekBytes = -1
	$bytesRead = 0
	$bytesAvailable = 0
	$bytesLeft = 0
	
	$success = [PipeUtils]::PeekNamedPipe(
		$Global:pipe.SafePipeHandle.DangerousGetHandle(),
		$null,
		0,
		[ref]$bytesRead,
		[ref]$bytesAvailable,
		[ref]$bytesLeft
	)
	
	if (-not $success) {
		$lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
		$Global:peekBytes = -1
		return "[Peek Error]: Win32 error code $lastError"
	}
	if ($success -and $bytesAvailable -gt 0) {

		# Read the available data
		
		$Global:peekBytes = $bytesAvailable
		return "[Peek]: Found $bytesAvailable bytes available"
	}
	else {
		$Global:peekBytes = 0
		return "[Peek]: Connected, but no data available (Bytes available: $bytesAvailable)"
	}

}

function ReadPipe {
	$Global:readData = ''
	$peekResultString = (PeekPipe)
	$bytesAvailable = $Global:peekBytes
	if ($bytesAvailable -gt 0) {

		# Read the available data
		$bytesRead = 0
		$buffer = New-Object byte[] $bytesAvailable
		$bytesRead = $Global:pipe.Read($buffer, 0, $bytesAvailable)
		
		if ($bytesRead -gt 0) {
			$response = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead)
			$response = $response.Trim() -replace "`r|`n", ""
			$Global:readData = $response
			return "[Received]: $Global:readData"
		}
		else {
			return "[Read Error]: Failed to read data after successful peek"
		}
	}
	else {
		return "[Read Error]: No data available (Bytes available: $bytesAvailable)"
	}
}

function WritePipe {
	$Global:writer.WriteLine($Global:writeData)
	$returnEcho = "[Sent]: $Global:writeData"
	
	$Global:writeData = ''
	
	# Optional: Check if we got an immediate response
	Start-Sleep -Milliseconds 50
	$peekResultString = (PeekPipe)
	$bytesAvailable = $Global:peekBytes
	
	$returnAvailable = ''
	if ($bytesAvailable -gt 0) {
		$returnAvailable = "`n[Notice]: Server responded with $bytesAvailable bytes"
	}
	return "$returnEcho$returnAvailable"
}

function OpenPipe {
    Write-Host "Connecting to pipe: $Global:pipeName"
    $Global:pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Global:pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $Global:pipe.Connect(5000)
    Write-Host "Connected successfully!"
    $Global:writer = New-Object System.IO.StreamWriter($Global:pipe, [System.Text.Encoding]::ASCII)
    $Global:writer.AutoFlush = $true
}

try {

	(OpenPipe)
    while ($true) {
        Write-Host -NoNewline "[Enter Command (or exit|status|reopen|print)]: "
        $cmd = Read-Host
        if ($cmd -ne '') {
			$Global:writeData = $cmd
			if ($cmd -eq 'exit') { break }
			elseif ($cmd -eq 'reopen') { (OpenPipe) }
			elseif ($cmd -eq 'status') { Write-Host (PeekPipe) }
			elseif ($cmd -eq 'print') { printCVARs }
			else { Write-Host (WritePipe) }
		}
		
		$peekResultString = (PeekPipe)
		while ($Global:peekBytes -gt 0) {
			Write-Host (ReadPipe)
			if ((incomingDataIsServerRespondingToGET)) {
				Write-Host (parseServerRespondingToGET)
			}
		}
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)"
}
finally {
    if ($writer -ne $null) { 
        try { $Global:writer.Dispose() } catch { }
    }
    if ($pipe -ne $null) { 
        try { $Global:pipe.Dispose() } catch { }
    }
    Write-Host "Disconnected from pipe"
}
