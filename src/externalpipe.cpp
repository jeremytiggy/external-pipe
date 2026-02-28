// externalpipe.cpp
#include "externalpipe.h"

#include <windows.h>
#include <stdio.h>
#include <tchar.h>
#include <strsafe.h>
#include <string>
#include <sstream>
//#include <unordered_map>
#include <algorithm>
#include <cassert>

//GZDoom Includes
#include "printf.h"
#include "g_cvars.h"

// Helper Functions
static std::string ExtractPipeName(const std::string& fullPath)
{
	// Windows pipe names use backslashes.
	// Find the last backslash and return the text after it.
	// Example: "\\.\pipe\GZD" -> "GZD"
    size_t pos = fullPath.find_last_of('\\');
    if (pos == std::string::npos) return fullPath;
    return fullPath.substr(pos + 1);
}

static std::string GetCurrentTimeString() {
	// Generates a timestamp string in the format "YYYY-MM-DD HH:MM:SS.milliseconds"
    // Example: 2025-11-08 00:31:01.650
    SYSTEMTIME systemTime;
    GetLocalTime(&systemTime);

    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%04d-%02d-%02d %02d:%02d:%02d.%03d",
        systemTime.wYear, systemTime.wMonth, systemTime.wDay,
        systemTime.wHour, systemTime.wMinute, systemTime.wSecond,
        systemTime.wMilliseconds);

    return std::string(buffer);
}

static void LogPipeOperation(const bool enableLogging, const std::string& pipePath, const std::string& operation, const std::string& message, unsigned long errorCode = 0)
{
	// Logs a formatted message for pipe operations.
    // Format: [Timestamp] | [PipeName].[Operation] | [Message] [Exitcode if any]
	// Example: 2025-11-08 00:30:35.719 | GZD.IsConnected | Peek complete. Exitcode 230
    // Example: 
	// If enableLogging is TRUE, messages are set to PRINT_HIGH level, which sends the data to the Players' Screen and Console.
	// If enableLogging is FALSE, messages are set to PRINT_LOG level, which sends the data to the log file only.
	// The variable 'enableLogging' is part of the ExternalPipe private class configuration. So, it's global. Changing it requires recompilation.
    std::string logMsg = GetCurrentTimeString() + " | " + ExtractPipeName(pipePath) + "." + operation + " | " + message;
    if (errorCode != 0) {
        logMsg += " Exitcode " + std::to_string(errorCode);
    }
    logMsg += "\n";
    if (enableLogging)
    {
        // Printf(PRINT_HIGH, logMsg.c_str());
        Printf(PRINT_LOG, logMsg.c_str());
    }
    
}



// Class Implementation
ExternalPipe::ExternalPipe()
{
    pipeStatus.pipeHandle = (void*)INVALID_HANDLE_VALUE;
}

ExternalPipe::~ExternalPipe()
{
    Close();
}

bool ExternalPipe::Open(const std::string& pipeName)
{
    std::string operation = "Open";

    pipePath = std::string("\\\\.\\pipe\\") + pipeName;
    HANDLE hPipe = (HANDLE)pipeStatus.pipeHandle;

    if (hPipe != INVALID_HANDLE_VALUE)
    {
        LogPipeOperation(logging, pipePath, operation, std::string("NOTE: Handle already exists. "));
        if (pipeStatus.open)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("NOTE: Pipe already marked open. Close and re-open to reset."));
		}
        return true;
    }

    

    LogPipeOperation(logging, pipePath, operation, std::string("Initializing State."));
    // Initialize state
    pipeStatus.open = false;
    pipeStatus.connected = false;
    pipeStatus.connectPending = false;
    memset(pipeStatus.bytesWriteFileBuffer, 0, sizeof(pipeStatus.bytesWriteFileBuffer));
    memset(pipeStatus.bytesReadFileBuffer, 0, sizeof(pipeStatus.bytesReadFileBuffer));
    pipeStatus.writePending = false;
    pipeStatus.readPending = false;
    pipeStatus.readCompleted = false;
    pipeStatus.PeekTotalBytesAvailable = 0;
    pipeStatus.connectEvent = (void*)INVALID_HANDLE_VALUE;
    pipeStatus.connectOverlapped = (void*)INVALID_HANDLE_VALUE;
    pipeStatus.readEvent = (void*)INVALID_HANDLE_VALUE;
    pipeStatus.readOverlapped = (void*)INVALID_HANDLE_VALUE;
    pipeStatus.writeEvent = (void*)INVALID_HANDLE_VALUE;
    pipeStatus.writeOverlapped = (void*)INVALID_HANDLE_VALUE;
    writeData.clear();
    readData.clear();

    LogPipeOperation(logging, pipePath, operation, std::string("Creating Pipe at path: ") + pipePath);
    // Create named pipe
    LPCSTR lpName = pipePath.c_str();
    DWORD dwOpenMode = overlappedIO ? (PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED) : PIPE_ACCESS_DUPLEX;
    DWORD dwPipeMode = PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT;
    DWORD nMaxInstances = PIPE_UNLIMITED_INSTANCES;
    DWORD nOutBufferSize = 4096;
    DWORD nInBufferSize = 4096;
    DWORD nDefaultTimeOut = 0;
    LPSECURITY_ATTRIBUTES lpSecurityAttributes = nullptr;

    HANDLE hCreateNamedPipeResult = CreateNamedPipeA(lpName, dwOpenMode, dwPipeMode, nMaxInstances, nOutBufferSize, nInBufferSize, nDefaultTimeOut, lpSecurityAttributes);

    DWORD lastError = GetLastError();
    LogPipeOperation(logging, pipePath, operation, std::string("Create Pipe command executed."), lastError);
    if (hCreateNamedPipeResult == INVALID_HANDLE_VALUE)
    {
        LogPipeOperation(logging, pipePath, operation, std::string("FAULT: Not Opened"), lastError);
        return false;
    }

    pipeStatus.pipeHandle = (void*)hCreateNamedPipeResult;
    LogPipeOperation(logging, pipePath, operation, std::string("Server ready for Client"), lastError);
    pipeStatus.open = true;
    return true;
}

void ExternalPipe::HandleClientDisconnection(const std::string& operation, unsigned long errorCode)
{
    std::string errorMsg;
    switch (errorCode)
    {
    case ERROR_NO_DATA:
        errorMsg = "Client disconnected gracefully";
        break;
    case ERROR_BROKEN_PIPE:
        errorMsg = "Pipe broken - client disconnected unexpectedly";
        break;
    case ERROR_PIPE_NOT_CONNECTED:
        errorMsg = "No client connected";
        break;
    default:
        errorMsg = "Client connection lost";
        break;
    }

    LogPipeOperation(logging, pipePath, operation, errorMsg, errorCode);

    // Reset connection state
    pipeStatus.connected = false;
    pipeStatus.connectPending = false;
    pipeStatus.writePending = false;
    pipeStatus.readPending = false;
}

bool ExternalPipe::IsValid()
{
    std::string operation = "IsValid";
    LogPipeOperation(logging, pipePath, operation, std::string("Beginning Handle validation."));
    HANDLE PipeHandle = (HANDLE)pipeStatus.pipeHandle;
    BOOL PipeHandleInitiallyInvalid = PipeHandle == INVALID_HANDLE_VALUE;

    if (PipeHandleInitiallyInvalid)
    {
        LogPipeOperation(logging, pipePath, operation, std::string("FAULT: Not Connected. Invalid Handle"));
        LogPipeOperation(logging, pipePath, operation, pipeStatus.connected ? std::string("But was already marked connected") : std::string("And was not marked connected"));
        LogPipeOperation(logging, pipePath, operation, std::string("Attempting to Close and Re-open pipe"));

        Close();
        Open(ExtractPipeName(pipePath));

        BOOL PipeHandleStillInvalidAfterCloseAndOpen = (HANDLE)pipeStatus.pipeHandle == INVALID_HANDLE_VALUE;
        if (PipeHandleStillInvalidAfterCloseAndOpen)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("FAULT: Still Invalid Handle after Re-open"));
            return false;
        }
        else
        {
            LogPipeOperation(logging, pipePath, operation, std::string("Re-opened Successfully"));
        }
    }
    else {
        LogPipeOperation(logging, pipePath, operation, std::string("Handle valid from the start."));
    }

    BOOL PipeHandleValid = (HANDLE)pipeStatus.pipeHandle != INVALID_HANDLE_VALUE;
    pipeStatus.open = PipeHandleValid;
    return PipeHandleValid;
}

bool ExternalPipe::IsConnected()
{
    std::string operation = "IsConnected";

    LogPipeOperation(logging, pipePath, operation, std::string("Validating Handle."));
    BOOL pipeValid = IsValid();
    if (!pipeValid)
    {
        if (pipeStatus.connected)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("STATE INCONSISTENCY: pipeStatus.connected=true but handle is invalid. "));
			LogPipeOperation(logging, pipePath, operation, std::string("Troubleshooting: Check if Close() was called without updating pipeStatus.connected"));
        }
        pipeStatus.connected = false;
        return false;
    }
    LogPipeOperation(logging, pipePath, operation, std::string("Handle is Valid."));

    HANDLE hPipe = (HANDLE)pipeStatus.pipeHandle;

    DWORD bytesAvailable = 0;
    DWORD bytesRead = 0;
    DWORD bytesLeft = 0;
    LogPipeOperation(logging, pipePath, operation, std::string("Peeking...") );
    BOOL peekResult = PeekNamedPipe(hPipe, nullptr, 0, &bytesRead, &bytesAvailable, &bytesLeft);
    DWORD lastError = GetLastError();
    LogPipeOperation(logging, pipePath, operation, std::string("Peek complete."), lastError );
    if (peekResult)
    {
        if (!pipeStatus.connected)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("STATE INCONSISTENCY: Pipe is functional but pipeStatus.connected=false. "));
            LogPipeOperation(logging, pipePath, operation, std::string("Troubleshooting: Connect() succeeded but pipeStatus.connected was not updated"));
        }
        pipeStatus.connected = true;
        LogPipeOperation(logging, pipePath, operation, "Connected and functional");
        return true;
    }
    LogPipeOperation(logging, pipePath, operation, "Dysfunctional or not connected", lastError);
    switch (lastError)
    {
    case ERROR_NO_DATA:

    case ERROR_BROKEN_PIPE:
        if (pipeStatus.connected)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("STATE INCONSISTENCY: pipeStatus.connected=true but pipe is broken/disconnected."));
            LogPipeOperation(logging, pipePath, operation, std::string("Troubleshooting: Client disconnected unexpectedly"));
        }
        HandleClientDisconnection(operation, lastError);
		return false;
    case ERROR_PIPE_NOT_CONNECTED:
        if (pipeStatus.connected)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("STATE INCONSISTENCY: pipeStatus.connected=true but pipe is broken/disconnected."));
            LogPipeOperation(logging, pipePath, operation, std::string("Troubleshooting: Client disconnected unexpectedly"));
        }
        HandleClientDisconnection(operation, lastError);
        return false;

    case ERROR_INVALID_HANDLE:
        if (pipeStatus.connected)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("STATE INCONSISTENCY: pipeStatus.connected=true but handle is invalid"));
        }
        pipeStatus.connected = false;
        LogPipeOperation(logging, pipePath, operation, std::string("Not connected - invalid handle"), lastError);
        return false;

    case ERROR_PIPE_BUSY:
        LogPipeOperation(logging, pipePath, operation, std::string("Pipe busy - connection status unchanged"), lastError);
        return pipeStatus.connected;

    default:
        LogPipeOperation(logging, pipePath, operation, std::string("Connection status uncertain - error: "), lastError);
        return pipeStatus.connected;
    }
    //failsafe
    return pipeStatus.connected;
}

void ExternalPipe::Close()
{
    std::string operation = "Close";
    LogPipeOperation(logging, pipePath, operation, std::string("Closing Pipe."));

    if ((HANDLE)pipeStatus.pipeHandle != INVALID_HANDLE_VALUE)
    {
        FlushFileBuffers((HANDLE)pipeStatus.pipeHandle);
        CloseHandle((HANDLE)pipeStatus.pipeHandle);
        pipeStatus.pipeHandle = (void*)INVALID_HANDLE_VALUE;
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.pipeHandle set to INVALID_HANDLE_VALUE."));
    }
    else
    {
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.pipeHandle already INVALID_HANDLE_VALUE."));
	}

    // Cleanup all resources
	CleanupConnectResources();
	CleanupWriteResources();
	CleanupReadResources();
    

    LogPipeOperation(logging, pipePath, operation, std::string("Resetting state."));
    // Reset state
    pipeStatus.open = false;
    pipeStatus.connected = false;
    pipeStatus.connectPending = false;
    memset(pipeStatus.bytesWriteFileBuffer, 0, sizeof(pipeStatus.bytesWriteFileBuffer));
    memset(pipeStatus.bytesReadFileBuffer, 0, sizeof(pipeStatus.bytesReadFileBuffer));
    pipeStatus.writePending = false;
    pipeStatus.readPending = false;
    pipeStatus.readCompleted = false;
    pipeStatus.PeekTotalBytesAvailable = 0;
    LogPipeOperation(logging, pipePath, operation, std::string("State Reset."));

    LogPipeOperation(logging, pipePath, operation, "Closed", GetLastError());
}

bool ExternalPipe::HasReadData()
{
    std::string operation = "HasReadData";
    pipeStatus.PeekTotalBytesAvailable = 0;

    if (!IsConnected())
    {
        LogPipeOperation(logging, pipePath, operation, std::string("Stopping. Not Connected"));
        return false;
    }

    HANDLE hPipe = (HANDLE)pipeStatus.pipeHandle;
    DWORD bytesAvailable = 0;

	LogPipeOperation(logging, pipePath, operation, std::string("Peeking for available data..."));
    BOOL peekResult = PeekNamedPipe(hPipe, nullptr, 0, nullptr, &bytesAvailable, nullptr);
    DWORD lastError = GetLastError();
	LogPipeOperation(logging, pipePath, operation, std::string("Peek complete."), lastError);

    if (!peekResult)
    {
        switch (lastError)
        {
        case ERROR_NO_DATA:
			LogPipeOperation(logging, pipePath, operation, "No data available", lastError);
        case ERROR_BROKEN_PIPE:
			LogPipeOperation(logging, pipePath, operation, "Client disconnected", lastError);
        case ERROR_PIPE_NOT_CONNECTED:
			LogPipeOperation(logging, pipePath, operation, "Client disconnected", lastError);
            HandleClientDisconnection(operation, lastError);
            break;
        default:
            LogPipeOperation(logging, pipePath, operation, "Peek failed", lastError);
            break;
        }
        return false;
    }
	LogPipeOperation(logging, pipePath, operation, std::string("Peek succeeded. Bytes available: ") + std::to_string(bytesAvailable), lastError);
    pipeStatus.PeekTotalBytesAvailable = bytesAvailable;
    return (bytesAvailable > 0);
}

void ExternalPipe::Flush()
{
    std::string operation = "Flush";
    if ((HANDLE)pipeStatus.pipeHandle != INVALID_HANDLE_VALUE)
    {
        FlushFileBuffers((HANDLE)pipeStatus.pipeHandle);
        LogPipeOperation(logging, pipePath, operation, "File buffers flushed");
    }
    else
    {
        LogPipeOperation(logging, pipePath, operation, "Cannot flush - invalid handle");
    }
}

void ExternalPipe::CleanupConnectResources()
{
	std::string operation = "CleanupConnectResources";
    if (pipeStatus.connectEvent != nullptr && (HANDLE)pipeStatus.connectEvent != INVALID_HANDLE_VALUE)
    {
        CloseHandle((HANDLE)pipeStatus.connectEvent);
        pipeStatus.connectEvent = nullptr;
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.connectEvent set to INVALID_HANDLE_VALUE."));
    }
    else
    {
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.connectEvent already INVALID_HANDLE_VALUE."));
    }

    if (pipeStatus.connectOverlapped != nullptr)
    {
        delete static_cast<OVERLAPPED*>(pipeStatus.connectOverlapped);
        pipeStatus.connectOverlapped = nullptr;
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.connectOverlapped set to nullptr."));
    }
    else
    {
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.connectOverlapped already nullptr."));
    }
    
    
}

void ExternalPipe::CleanupWriteResources()
{
    std::string operation = "CleanupWriteResources";
    if (pipeStatus.writeEvent != nullptr && (HANDLE)pipeStatus.writeEvent != INVALID_HANDLE_VALUE)
    {
        CloseHandle((HANDLE)pipeStatus.writeEvent);
        pipeStatus.writeEvent = nullptr;
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.writeEvent set to INVALID_HANDLE_VALUE."));
    }
    else
    {
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.writeEvent already INVALID_HANDLE_VALUE."));
    }

    if (pipeStatus.writeOverlapped != nullptr)
    {
        delete static_cast<OVERLAPPED*>(pipeStatus.writeOverlapped);
        pipeStatus.writeOverlapped = nullptr;
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.writeOverlapped set to nullptr."));
    }
    else
    {
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.writeOverlapped already nullptr."));
    }


}

void ExternalPipe::CleanupReadResources()
{
    std::string operation = "CleanupReadResources";
    if (pipeStatus.readEvent != nullptr && (HANDLE)pipeStatus.readEvent != INVALID_HANDLE_VALUE)
    {
        CloseHandle((HANDLE)pipeStatus.readEvent);
        pipeStatus.readEvent = nullptr;
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.readEvent set to INVALID_HANDLE_VALUE."));
    }
    else
    {
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.readEvent already INVALID_HANDLE_VALUE."));
    }

    if (pipeStatus.readOverlapped != nullptr)
    {
        delete static_cast<OVERLAPPED*>(pipeStatus.readOverlapped);
        pipeStatus.readOverlapped = nullptr;
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.readOverlapped set to nullptr."));
    }
    else
    {
        LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus.readOverlapped already nullptr."));
    }


}

bool ExternalPipe::PrepareWriteData()
{
    std::string operation = "PrepareWriteData";

    if (writeData.empty())
    {
        LogPipeOperation(logging, pipePath, operation, "No data to prepare for writing");
        return false;
    }

    // Strip all existing CR and LF characters from the input data
    std::string cleanData;
    cleanData.reserve(writeData.size());

    size_t crCount = 0;
    size_t lfCount = 0;

    for (char c : writeData)
    {
        if (c == '\r')
        {
            crCount++;
        }
        else if (c == '\n')
        {
            lfCount++;
        }
        else
        {
            cleanData += c;
        }
    }

    size_t strippedCount = crCount + lfCount;
    if (strippedCount > 0)
    {
        LogPipeOperation(logging, pipePath, operation,
            std::string("Stripped ") + std::to_string(strippedCount) +
            " control characters (CR: " + std::to_string(crCount) +
            ", LF: " + std::to_string(lfCount) + ") from input data");
    }

    // Check if we have any data left after stripping
    if (cleanData.empty())
    {
        LogPipeOperation(logging, pipePath, operation, "No data remaining after stripping CR/LF characters");
        return false;
    }

    // Clear the write buffer
    memset(pipeStatus.bytesWriteFileBuffer, 0, sizeof(pipeStatus.bytesWriteFileBuffer));

    // Calculate available space (leave room for CRLF + null terminator)
    const size_t maxDataSize = sizeof(pipeStatus.bytesWriteFileBuffer) - 3; // CR + LF + null

    if (cleanData.size() > maxDataSize)
    {
        LogPipeOperation(logging, pipePath, operation,
            std::string("Data truncated from ") + std::to_string(cleanData.size()) +
            " to " + std::to_string(maxDataSize) + " bytes due to buffer size limits");
    }

    // Copy the cleaned data to the buffer
    size_t bytesToCopy = std::min<size_t>(cleanData.size(), maxDataSize);
    memcpy(pipeStatus.bytesWriteFileBuffer, cleanData.data(), bytesToCopy);

    // Add CRLF terminator if configured
    if (appendCRLF)
    {
        // Double-check we have space for CRLF
        if (bytesToCopy + 2 >= sizeof(pipeStatus.bytesWriteFileBuffer))
        {
            LogPipeOperation(logging, pipePath, operation, "WARNING: Insufficient space for CRLF terminator");
            pipeStatus.bytesWriteFileBufferLength = bytesToCopy;
        }
        else
        {
            pipeStatus.bytesWriteFileBuffer[bytesToCopy] = '\r';
            pipeStatus.bytesWriteFileBuffer[bytesToCopy + 1] = '\n';
            pipeStatus.bytesWriteFileBufferLength = bytesToCopy + 2;
        }
    }
    else
    {
        pipeStatus.bytesWriteFileBufferLength = bytesToCopy;
    }

    // Add null terminator (always ensure we have space)
    if (pipeStatus.bytesWriteFileBufferLength < sizeof(pipeStatus.bytesWriteFileBuffer) - 1)
    {
        pipeStatus.bytesWriteFileBuffer[pipeStatus.bytesWriteFileBufferLength] = '\0';
    }
    else
    {
        // Buffer is full, null terminate at the last position
        pipeStatus.bytesWriteFileBuffer[sizeof(pipeStatus.bytesWriteFileBuffer) - 1] = '\0';
        LogPipeOperation(logging, pipePath, operation, "WARNING: Buffer full, null terminator placed at end");
    }

    std::string debugmessage = std::string("Prepared ") + std::to_string(pipeStatus.bytesWriteFileBufferLength) +
        " bytes for writing (clean data: " + std::to_string(bytesToCopy) +
		" bytes, CRLF added: " + (appendCRLF ? "yes" : "no");
    LogPipeOperation(logging, pipePath, operation, debugmessage);

        // Debug output of first few bytes
        if (pipeStatus.bytesWriteFileBufferLength > 0)
        {
            std::string debugSample;
            size_t sampleLength = std::min<size_t>(size_t(20), pipeStatus.bytesWriteFileBufferLength);
            for (size_t i = 0; i < sampleLength; ++i)
            {
                char c = pipeStatus.bytesWriteFileBuffer[i];
                if (c >= 32 && c <= 126) // Printable ASCII
                {
                    debugSample += c;
                }
                else
                {
                    debugSample += "\\x" + std::to_string(static_cast<unsigned char>(c));
                }
            }
            LogPipeOperation(logging, pipePath, operation, "Data sample: " + debugSample);
        }

        return true;
}

bool ExternalPipe::PrepareReadBuffer()
{
    memset(pipeStatus.bytesReadFileBuffer, 0, sizeof(pipeStatus.bytesReadFileBuffer));
    pipeStatus.bytesToRead = std::min<DWORD>(sizeof(pipeStatus.bytesReadFileBuffer) - 1, pipeStatus.PeekTotalBytesAvailable);

    LogPipeOperation(logging, pipePath, "Read", std::string("Prepared to read ") + std::to_string(pipeStatus.bytesToRead) + " bytes");
    return true;
}

bool ExternalPipe::FinalizeWriteOperation(bool success)
{
    std::string operation = "Write";
    LogPipeOperation(logging, pipePath, operation, std::string("Beginning write finalization process."));
    BOOL bytesAllWritten = pipeStatus.bytesWritten == pipeStatus.bytesWriteFileBufferLength;
    std::string bytesWrittenMessage = bytesAllWritten ? "Bytes Written matches WriteFile Buffer Length." : "Bytes Written doesn't match WriteFile Buffer Length.";
    LogPipeOperation(logging, pipePath, operation, bytesWrittenMessage);
    BOOL writeDataAndBufferReadyToClear = success && bytesAllWritten;
    std::string writeDataClearMessage = writeDataAndBufferReadyToClear ? "Write Data & Buffer Ready to Clear." : "Write Data & Buffer not ready to clear.";
    LogPipeOperation(logging, pipePath, operation, writeDataClearMessage);
    if (writeDataAndBufferReadyToClear)
    {
        LogPipeOperation(logging, pipePath, operation, std::string("Clearing Write Data."));
        writeData.clear();
        LogPipeOperation(logging, pipePath, operation, std::string("Write Data cleared."));
        LogPipeOperation(logging, pipePath, operation, std::string("Clearing Write File Buffer."));
        memset(pipeStatus.bytesWriteFileBuffer, 0, sizeof(pipeStatus.bytesWriteFileBuffer));
        LogPipeOperation(logging, pipePath, operation, std::string("Write File Buffer cleared."));
        LogPipeOperation(logging, pipePath, operation, std::string("Flushing File Buffers."));
        //FlushFileBuffers((HANDLE)pipeStatus.pipeHandle);
        //LogPipeOperation(logging, pipePath, operation, std::string("File Buffers flushed."));
    }

    pipeStatus.writePending = false;
    pipeStatus.writeCompleted = success; 
    LogPipeOperation(logging, pipePath, operation, std::string("pipeStatus updated."));

    // Cleanup
    CleanupWriteResources();

    LogPipeOperation(logging, pipePath, operation, success ? "Write completed successfully" : "Write failed");
    return success;
}

bool ExternalPipe::FinalizeReadOperation(bool success)
{
    std::string operation = "Read";

    if (success && pipeStatus.bytesReceived > 0)
    {
        size_t safeLen = std::min<size_t>(pipeStatus.bytesReceived, sizeof(pipeStatus.bytesReadFileBuffer) - 1);
        pipeStatus.bytesReadFileBuffer[safeLen] = '\0';
        readData = std::string(reinterpret_cast<char*>(pipeStatus.bytesReadFileBuffer), safeLen);
        // Remove all CR and LF characters from the read data
        readData.erase(std::remove_if(readData.begin(), readData.end(),
            [](char c) { return c == '\r' || c == '\n'; }),
            readData.end());

        LogPipeOperation(logging, pipePath, operation,
            std::string("Read and cleaned ") + std::to_string(readData.size()) +
            " bytes (original: " + std::to_string(safeLen) + " bytes)");
    }
    else
    {
        readData.clear();
    }

    pipeStatus.readPending = false;
    pipeStatus.readCompleted = success;

    // Cleanup
	CleanupReadResources();

    LogPipeOperation(logging, pipePath, operation, success ? "Read completed successfully" : "Read failed");
    return success;
}

bool ExternalPipe::Connect()
{
    std::string operation = "Connect";

    if (!IsValid())
    {
        LogPipeOperation(logging, pipePath, operation, "FAULT: Not Valid. Exit at start of call");
        return false;
    }

    HANDLE hPipe = (HANDLE)pipeStatus.pipeHandle;

    // Initialize overlapped structures if needed
    if (overlappedIO && ((pipeStatus.connectEvent == nullptr) || (pipeStatus.connectEvent == (void*)INVALID_HANDLE_VALUE)))
    {
        pipeStatus.connectEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        if (pipeStatus.connectEvent == nullptr || pipeStatus.connectEvent == (void*)INVALID_HANDLE_VALUE)
        {
            LogPipeOperation(logging, pipePath, operation, "FAULT: Connect Event initialization failed", GetLastError());
            return false;
        }
    }

    if (overlappedIO && ((pipeStatus.connectOverlapped == nullptr) || (pipeStatus.connectOverlapped == (void*)INVALID_HANDLE_VALUE)))
    {
        pipeStatus.connectOverlapped = new OVERLAPPED();
        ZeroMemory(static_cast<OVERLAPPED*>(pipeStatus.connectOverlapped), sizeof(OVERLAPPED));
        static_cast<OVERLAPPED*>(pipeStatus.connectOverlapped)->hEvent = (HANDLE)pipeStatus.connectEvent;
    }

    OVERLAPPED* connectOverlapped = static_cast<OVERLAPPED*>(pipeStatus.connectOverlapped);

    // Start connection
    BOOL connectResult = ConnectNamedPipe(hPipe, connectOverlapped);
    DWORD lastError = GetLastError();

    LogPipeOperation(logging, pipePath, operation, std::string("ConnectNamedPipe returned ") + (connectResult ? "TRUE" : "FALSE"), lastError);

    if (connectResult)
    {
        LogPipeOperation(logging, pipePath, operation, "Client connected synchronously");
        pipeStatus.connected = true;
        pipeStatus.connectPending = false;
        CleanupConnectResources();
        return true;
    }

    switch (lastError)
    {
    case ERROR_PIPE_CONNECTED:
        LogPipeOperation(logging, pipePath, operation, "Client already connected");
        pipeStatus.connected = true;
        pipeStatus.connectPending = false;
        CleanupConnectResources();
        return true;

    case ERROR_IO_PENDING:
        LogPipeOperation(logging, pipePath, operation, "Connection pending - waiting for completion");
        pipeStatus.connectPending = true;

        if (overlappedIO)
        {
            DWORD bytesTransferred = 0;
            DWORD waitTimeout = blocking ? INFINITE : overlappedTimeout;
            DWORD waitResult = WaitForSingleObject((HANDLE)pipeStatus.connectEvent, waitTimeout);

            if (waitResult == WAIT_OBJECT_0)
            {
                if (GetOverlappedResult(hPipe, connectOverlapped, &bytesTransferred, FALSE))
                {
                    pipeStatus.connected = true;
                    pipeStatus.connectPending = false;
                    CleanupConnectResources();
                    return true;
                }
            }
        }
        return false;

    case ERROR_NO_DATA:
    case ERROR_BROKEN_PIPE:
        HandleClientDisconnection(operation, lastError);
        LogPipeOperation(logging, pipePath, operation, "Client disconnected during connection attempt - need to reopen pipe");
        return false;

    default:
        LogPipeOperation(logging, pipePath, operation, "Connection failed", lastError);
        return false;
    }
}

void ExternalPipe::AddToWriteQueue(const std::string& stringData) {
    if (!stringData.empty())
    {
        pipeStatus.writeQueueSize++;
        if (pipeStatus.writeQueueSize > 1)
        {
            writeQueue += "\n";
        }
        writeQueue += stringData;
    }
}

bool ExternalPipe::Write()
{
    std::string operation = "Write";

    if (!IsValid())
    {
        LogPipeOperation(logging, pipePath, operation, "Cannot write - invalid handle");
        return false;
    }

    if (!IsConnected())
    {
        LogPipeOperation(logging, pipePath, operation, "Cannot write - not connected");
        return false;
    }

    // Check if we have data to write
    if (writeData.empty() && !pipeStatus.writePending)
    {
        LogPipeOperation(logging, pipePath, operation, "No data to write");
        return false;
    }

    HANDLE hPipe = (HANDLE)pipeStatus.pipeHandle;

    // Initialize overlapped structures if needed
    if (overlappedIO && ((pipeStatus.writeEvent == nullptr) || (pipeStatus.writeEvent == (void*)INVALID_HANDLE_VALUE)))
    {
        pipeStatus.writeEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        if (pipeStatus.writeEvent == nullptr || pipeStatus.writeEvent == (void*)INVALID_HANDLE_VALUE)
        {
            LogPipeOperation(logging, pipePath, operation, "FAULT: Write Event initialization failed", GetLastError());
            return false;
        }
    }

    if (overlappedIO && ((pipeStatus.writeOverlapped == nullptr) || (pipeStatus.writeOverlapped == (void*)INVALID_HANDLE_VALUE)))
    {
        pipeStatus.writeOverlapped = new OVERLAPPED();
        ZeroMemory(static_cast<OVERLAPPED*>(pipeStatus.writeOverlapped), sizeof(OVERLAPPED));
        static_cast<OVERLAPPED*>(pipeStatus.writeOverlapped)->hEvent = (HANDLE)pipeStatus.writeEvent;
    }

    OVERLAPPED* writeOverlapped = static_cast<OVERLAPPED*>(pipeStatus.writeOverlapped);

    // Prepare data if this is a new write operation
    if (!pipeStatus.writePending)
    {
        if (!PrepareWriteData())
        {
            return false;
        }
        pipeStatus.writePending = true;
    }

    // Perform the write operation
    BOOL writeResult = WriteFile(hPipe, pipeStatus.bytesWriteFileBuffer,
        pipeStatus.bytesWriteFileBufferLength,
        &pipeStatus.bytesWritten, writeOverlapped);

    DWORD lastError = GetLastError();
    pipeStatus.writeFileReturnCode = lastError;

    LogPipeOperation(logging, pipePath, operation, std::string("WriteFile returned ") + (writeResult ? "TRUE" : "FALSE"), lastError);

    if (writeResult)
    {
        return FinalizeWriteOperation(true);
    }

    switch (lastError)
    {
    case ERROR_IO_PENDING:
        LogPipeOperation(logging, pipePath, operation, "Write pending");
        pipeStatus.writePending = true;
        return false;

    case ERROR_NO_DATA:
    case ERROR_BROKEN_PIPE:
    case ERROR_PIPE_NOT_CONNECTED:
        HandleClientDisconnection(operation, lastError);
        FinalizeWriteOperation(false);
        return false;

    default:
        LogPipeOperation(logging, pipePath, operation, "Write failed", lastError);
        return FinalizeWriteOperation(false);
    }
}

bool ExternalPipe::Read()
{
    std::string operation = "Read";
	LogPipeOperation(logging, pipePath, operation, std::string("Starting Read operation"));
    BOOL initiallyConnected = IsConnected();
    BOOL initiallyDisconnected = !initiallyConnected;
    if (initiallyDisconnected)
    {
        LogPipeOperation(logging, pipePath, operation, std::string("Cannot read - not connected"));
        LogPipeOperation(logging, pipePath, operation, std::string("Attempting to connect, be right back."));
        BOOL attemptToConnectSuccessful = Connect();
        if (attemptToConnectSuccessful)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("Connection attempt successful. Proceeding."));
        }
        else
        {
            LogPipeOperation(logging, pipePath, operation, std::string("Connection attempt not successful. Exiting Read."));
            return false;
        }
    }

    // Peek for data if configured
    BOOL needsToHaveDataToContinue = !overlappedIO || peekRequiredForRead;
    if (needsToHaveDataToContinue)
    {
		BOOL hasData = HasReadData();
        BOOL noDataToContinueWith = needsToHaveDataToContinue && !hasData;
        if (noDataToContinueWith)
        {
            LogPipeOperation(logging, pipePath, operation, std::string("Nothing to read"));
            return false;
        }
        else 
        {
            LogPipeOperation(logging, pipePath, operation, std::string("Data is available to read"));
        }
	}
    

    HANDLE hPipe = (HANDLE)pipeStatus.pipeHandle;

    // Initialize overlapped structures if needed
    LogPipeOperation(logging, pipePath, operation, std::string("Initializing overlapped structures."));
    if (overlappedIO && ((pipeStatus.readEvent == nullptr) || (pipeStatus.readEvent == (void*)INVALID_HANDLE_VALUE)))
    {
        pipeStatus.readEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        if (pipeStatus.readEvent == nullptr || pipeStatus.readEvent == (void*)INVALID_HANDLE_VALUE)
        {
            LogPipeOperation(logging, pipePath, operation, "FAULT: Read Event initialization failed", GetLastError());
            return false;
        }
        else
        {
            LogPipeOperation(logging, pipePath, operation, std::string("Read Event initialized."));
        }
    }

    if (overlappedIO && ((pipeStatus.readOverlapped == nullptr) || (pipeStatus.readOverlapped == (void*)INVALID_HANDLE_VALUE)))
    {
        pipeStatus.readOverlapped = new OVERLAPPED();
        ZeroMemory(static_cast<OVERLAPPED*>(pipeStatus.readOverlapped), sizeof(OVERLAPPED));
        static_cast<OVERLAPPED*>(pipeStatus.readOverlapped)->hEvent = (HANDLE)pipeStatus.readEvent;
        LogPipeOperation(logging, pipePath, operation, std::string("Read Overlapped initialized."));
    }

    OVERLAPPED* readOverlapped = static_cast<OVERLAPPED*>(pipeStatus.readOverlapped);

    // Prepare buffer if this is a new read operation
    std::string readPendingMessage = pipeStatus.readPending ? "Read is Pending." : "No Read is Pending.";
    LogPipeOperation(logging, pipePath, operation, readPendingMessage);
    if (!pipeStatus.readPending)
    {
        if (!PrepareReadBuffer())
        {
            LogPipeOperation(logging, pipePath, operation, std::string("Read Buffer Preparations failed."));
            return false;
        }
        pipeStatus.readPending = true;
        LogPipeOperation(logging, pipePath, operation, std::string("Read Buffer prepared."));
    }

    // Perform the read operation
    LogPipeOperation(logging, pipePath, operation, std::string("Performing ReadFile operation."));
    BOOL readResult = ReadFile(hPipe, pipeStatus.bytesReadFileBuffer,
        pipeStatus.bytesToRead, &pipeStatus.bytesReceived, readOverlapped);

    DWORD lastError = GetLastError();
    pipeStatus.readFileReturnCode = lastError;

    LogPipeOperation(logging, pipePath, operation, std::string("ReadFile returned ") + (readResult ? "TRUE" : "FALSE"), lastError);

    if (readResult)
    {
        return FinalizeReadOperation(true);
    }

    switch (lastError)
    {
    case ERROR_IO_PENDING:
        LogPipeOperation(logging, pipePath, operation, std::string("Read pending"));
        pipeStatus.readPending = true;
        return false;

    case ERROR_NO_DATA:
    case ERROR_BROKEN_PIPE:
    case ERROR_PIPE_NOT_CONNECTED:
        LogPipeOperation(logging, pipePath, operation, std::string("Client Not Connected to Pipe. Handling disconnect"));
        HandleClientDisconnection(operation, lastError);
        FinalizeReadOperation(false);
        return false;

    case ERROR_MORE_DATA:
        LogPipeOperation(logging, pipePath, operation, "Message larger than buffer - partial read");
        return FinalizeReadOperation(true);

    default:
        LogPipeOperation(logging, pipePath, operation, "Read failed", lastError);
        return FinalizeReadOperation(false);
    }
}

void ExternalPipe::ProcessPipeCommand(const std::string& commandString)
{
    
    std::string operation = "ProcessPipeCommand";
    CCMD_ReplyToClient.clear();

    std::string cmd = commandString;
    std::string CCMD_argumentString;
    std::string CCMD_secondaryArgumentString;
	std::string CCMD_CVAR_GET_SET_Name;
	std::string CCMD_CVAR_SET_Value;


    // Pre-allocate a fixed-size array (adjust N as needed)
    const unsigned long MAX_ARGS = 10;
    
    CCMD_argumentCount = 0; //argv.argc() from Console Command, ArgumentVector.ArgumentCount

    std::istringstream iss(commandString); //separate string by whitespace
    while (iss >> CCMD_argumentVector[CCMD_argumentCount] && CCMD_argumentCount < MAX_ARGS)
    {
        if (CCMD_argumentCount == 1) {
            CCMD_argumentString = CCMD_argumentVector[CCMD_argumentCount];
        }
		else if (CCMD_argumentCount > 1) {
            CCMD_argumentString += " " + CCMD_argumentVector[CCMD_argumentCount];
			if (CCMD_argumentCount == 2) {
                CCMD_secondaryArgumentString += CCMD_argumentVector[CCMD_argumentCount]; 
            }
            else { 
                CCMD_secondaryArgumentString += " " + CCMD_argumentVector[CCMD_argumentCount]; 
            }
		}
        LogPipeOperation(logging, pipePath, operation, "Command Arguments: " + CCMD_argumentVector[CCMD_argumentCount]);
        ++CCMD_argumentCount;
    }
    LogPipeOperation(logging, pipePath, operation, "Number of Arguments Including Base Command: " + CCMD_argumentCount);
    CCMD_Command = CCMD_argumentVector[0]; //the command is the first item
    //Make it Upper Case
    std::transform(CCMD_Command.begin(), CCMD_Command.end(), CCMD_Command.begin(),
        [](unsigned char c) { return std::toupper(c); });


    LogPipeOperation(logging, pipePath, operation,
        "Processing command: '" + CCMD_Command + "'");
    LogPipeOperation(logging, pipePath, operation,
        "Command Arguments: '" + CCMD_argumentString + "'");

    GET_CVar_Name.clear();
	GET_CVar_Value.clear();
	GET_CVar_ConsoleReturnString.clear();
	SET_CVar_Name.clear();
	SET_CVar_Value.clear();
	GET_CVar_ConsoleReturnString.clear();


    // Process based on command prefix
    
    if (CCMD_Command == CMD_CVAR_GET) {
        //ProcessCVarGet(payload);
        GET_CVar_Name = CCMD_argumentVector[1];
        GET_CVar_Value.clear();
        GET_CVar_ConsoleReturnString.clear();
        LogPipeOperation(logging, pipePath, operation, "GET value of \"" + GET_CVar_Name + "\"");
        
        //Reference: c_cvars.cpp, CCMD (get)
        /*CCMD (get)
        {
            FBaseCVar *var, *prev;

            if (argv.argc() >= 2)
            {
                if ( (var = FindCVar (argv[1], &prev)) )
                {
                    UCVarValue val;
                    val = var->GetGenericRep (CVAR_String);
                    Printf ("\"%s\" is \"%s\"\n", var->GetName(), val.String);
                }
                else
                {
                    Printf ("\"%s\" is unset\n", argv[1]);
                }
            }
            else
            {
                Printf ("get: need variable name\n");
            }
        }*/
        
		bool GET_Cvar_Command_ProperlyFormed = (CCMD_argumentCount = 2);
        if (!GET_Cvar_Command_ProperlyFormed)
        {
            if (CCMD_argumentCount < 2)
            {
                LogPipeOperation(logging, pipePath, operation, "GET is improperly formed: Missing Name.");
                GET_CVar_ConsoleReturnString = "GET: missing variable name. Proper usage is GET <cvar>";
            }
            if (CCMD_argumentCount > 2)
            {
                LogPipeOperation(logging, pipePath, operation, "GET is improperly formed: Too many arguments.");
                GET_CVar_ConsoleReturnString = "GET: too many arguments. Proper usage is GET <cvar>";
			}
        }
        if (GET_Cvar_Command_ProperlyFormed)
        {
            LogPipeOperation(logging, pipePath, operation, "GET is properly formed. Target CVar: " + GET_CVar_Name);
            FBaseCVar* var, * prev;
            var = FindCVar(GET_CVar_Name.c_str(), &prev);
            bool CVAR_Declared = var != nullptr && var != NULL;
            
            if (!CVAR_Declared)
            {
                LogPipeOperation(logging, pipePath, operation, "CVar not found.");
                GET_CVar_ConsoleReturnString = "\"" + GET_CVar_Name + "\" is unset";
            }
			
            if (CVAR_Declared)
            {
				std::string Find_CVar_Name = std::string(var->GetName());
                LogPipeOperation(logging, pipePath, operation, "Requested: \"" + GET_CVar_Name + "\", Closest Match: \"" + Find_CVar_Name + "\"");
				bool CVar_Name_Matches = (GET_CVar_Name == Find_CVar_Name);
                if (!CVar_Name_Matches)
                {
                    LogPipeOperation(logging, pipePath, operation, "CVar Name mismatch. Requested: \"" + GET_CVar_Name + "\", Closest Match: \"" + Find_CVar_Name + "\"");
                    GET_CVar_ConsoleReturnString = "GET: Name mismatch. Requested: \"" + GET_CVar_Name + "\", Closest Match: \"" + Find_CVar_Name + "\"";
				}
                if (CVar_Name_Matches)
                {
                    UCVarValue val;
                    val = var->GetGenericRep(CVAR_String);
                    GET_CVar_Value = std::string(val.String);
                    GET_CVar_Name = std::string(var->GetName());
                    LogPipeOperation(logging, pipePath, operation, "CVar \"" + GET_CVar_Name + "\" is \"" + GET_CVar_Value + "\"");
                    GET_CVar_ConsoleReturnString = "\"" + GET_CVar_Name + "\"" + " is " + "\"" + GET_CVar_Value + "\"";
                }
                
            }
			
        }// end if (GET_Cvar_Command_ProperlyFormed)
        

        LogPipeOperation(logging, pipePath, operation, GET_CVar_ConsoleReturnString);
        CCMD_ReplyToClient = GET_CVar_ConsoleReturnString;
    }
    else if (CCMD_Command == CMD_CVAR_SET) {
		//Reference c_cvars.cpp, CCMD (set)
        /*CCMD (set)
        {
	        if (argv.argc() != 3)
	        {
		        Printf ("usage: set <variable> <value>\n");
	        }
	        else
	        {
		        FBaseCVar *var;

		        var = FindCVar (argv[1], NULL);
		        if (var == NULL)
			        var = new FStringCVar (argv[1], NULL, CVAR_AUTO | CVAR_UNSETTABLE | cvar_defflags);

		        var->CmdSet (argv[2]);
	        }
        }*/

        //ProcessCVarSet(payload);
        SET_CVar_Name = CCMD_argumentVector[1];
        SET_CVar_Value = CCMD_secondaryArgumentString; //CCMD_argumentVector[2];
        SET_CVar_ConsoleReturnString.clear();

        FBaseCVar* var, * prev;
        UCVarValue val;
		bool SET_CVar_Command_ProperlyFormed = (CCMD_argumentCount >= 3);

        if (!SET_CVar_Command_ProperlyFormed)
        {
            if (CCMD_argumentCount < 2)
            {
                LogPipeOperation(logging, pipePath, operation, "SET is improperly formed: Missing Name.");
                SET_CVar_ConsoleReturnString = "SET: need variable name. Proper usage is SET <cvar> <value>";
            }
            else if (CCMD_argumentCount < 3)
            {
                LogPipeOperation(logging, pipePath, operation, "SET is improperly formed: Missing Value.");
                SET_CVar_ConsoleReturnString = "SET: need variable value. Proper usage is SET <cvar> <value>";
            }
            else
            {
                LogPipeOperation(logging, pipePath, operation, "SET is improperly formed: Unknown error.");
                SET_CVar_ConsoleReturnString = "SET: malformed command. Proper usage is SET <cvar> <value>";
            }
            /*else if (CCMD_argumentCount > 3)
            {
                LogPipeOperation(logging, pipePath, operation, "SET is improperly formed: Too many arguments.");
                SET_CVar_ConsoleReturnString = "SET: too many arguments. Proper usage is SET <cvar> <value>";
            }*/
		}//end if (!GET_Cvar_Command_ProperlyFormed)

        if (SET_CVar_Command_ProperlyFormed)
        {
            LogPipeOperation(logging, pipePath, operation, "SET is properly formed. CVAR: " + SET_CVar_Name + "; Value: " + SET_CVar_Value);
            
			//Check if CVAR exists
            std::string SET_CVar_Value_Previous;
			FBaseCVar* exists_var, * exists_prev; //redefining to reset
            exists_var = FindCVar(SET_CVar_Name.c_str(), &exists_prev);
            bool CVar_AlreadyDeclared = exists_var != nullptr && exists_var != NULL;
			bool CVar_SuccessfullyDeclaredManually = false;
            bool CVar_Value_AlreadySet;
			// If CVar doesn't exist, try to create it manually
            if (!CVar_AlreadyDeclared)
            {
                LogPipeOperation(logging, pipePath, operation, "CVar \"" + SET_CVar_Name + "\" is not yet declared. Declaring...");
				int cvar_defflags_local = (CVAR_SERVERINFO | CVAR_UNSETTABLE | CVAR_NOSAVE | CVAR_MOD);
                
                //var = new FStringCVar(SET_CVar_Name.c_str(), NULL, cvar_defflags_local);
                FBaseCVar* new_var = new FStringCVar(SET_CVar_Name.c_str(), SET_CVar_Value.c_str(), cvar_defflags_local);
                //var = new FStringCVar(SET_CVar_Name.c_str(), SET_CVar_Value.c_str(), cvar_defflags_local);
                
                FBaseCVar* confirm_var, * confirm_prev; //redefining to reset
                confirm_var = FindCVar(SET_CVar_Name.c_str(), &confirm_prev);
                CVar_SuccessfullyDeclaredManually = confirm_var != nullptr && confirm_var != NULL; //recheck after creation
                if (CVar_SuccessfullyDeclaredManually)
                {
                    LogPipeOperation(logging, pipePath, operation, "CVar \"" + SET_CVar_Name + "\" successfully declared.");
                    CVar_Value_AlreadySet = true;
                    SET_CVar_ConsoleReturnString = "\"" + SET_CVar_Name + "\" is \"" + SET_CVar_Value + "\"";
                }
                if (!CVar_SuccessfullyDeclaredManually)
                {
                    LogPipeOperation(logging, pipePath, operation, "CVar \"" + SET_CVar_Name + "\" declaration failed.");
                    SET_CVar_ConsoleReturnString = "SET: CVar could not be created";
                }
            }

            //If CVar already exists, check it's current value
            if (CVar_AlreadyDeclared)
            {
				LogPipeOperation(logging, pipePath, operation, "CVar \"" + SET_CVar_Name + "\" is declared. Checking current value...");
                FBaseCVar* current_var, * current_prev; //redefining to reset
                current_var = FindCVar(SET_CVar_Name.c_str(), &current_prev);
                GET_CVar_Name = std::string(current_var->GetName());
                LogPipeOperation(logging, pipePath, operation, "Matching CVar Name: \"" + GET_CVar_Name + "\"");
                UCVarValue current_val;
                current_val = current_var->GetGenericRep(CVAR_String);
                GET_CVar_Value = std::string(current_val.String);
				LogPipeOperation(logging, pipePath, operation, "Current CVar Value: \"" + GET_CVar_Value + "\"");
				bool GET_CVar_HasValue = !(GET_CVar_Value.empty());
				LogPipeOperation(logging, pipePath, operation, "CVar Has Value: " + std::string(GET_CVar_HasValue ? "TRUE" : "FALSE"));
                
                
                if (GET_CVar_HasValue)
                {
                    SET_CVar_Value_Previous = GET_CVar_Value;
                    LogPipeOperation(logging, pipePath, operation, "CVar \"" + GET_CVar_Name + "\" is \"" + SET_CVar_Value_Previous + "\"");

                    CVar_Value_AlreadySet = (SET_CVar_Value_Previous == SET_CVar_Value) && GET_CVar_HasValue;
                    if (CVar_Value_AlreadySet)
                    {
                        LogPipeOperation(logging, pipePath, operation, "CVar value is already set to the desired value. No change made");
                        SET_CVar_ConsoleReturnString = "\"" + SET_CVar_Name + "\" is already \"" + SET_CVar_Value + "\"";
                        CCMD_ReplyToClient = SET_CVar_ConsoleReturnString;
                    }
                }
                if (!GET_CVar_HasValue)
                {
                    LogPipeOperation(logging, pipePath, operation, "CVar \"" + GET_CVar_Name + "\" is unset.");
				}

			} //end if (CVar_AlreadyDeclared)

			bool CVar_Declared = CVar_AlreadyDeclared || CVar_SuccessfullyDeclaredManually;
			LogPipeOperation(logging, pipePath, operation, "CVar Declared: " + std::string(CVar_Declared ? "TRUE" : "FALSE"));
			bool CVar_Declared_And_Requires_Update = CVar_Declared && !CVar_Value_AlreadySet;
			LogPipeOperation(logging, pipePath, operation, "CVar Requires Update: " + std::string(CVar_Declared_And_Requires_Update ? "TRUE" : "FALSE"));
            if (CVar_Declared_And_Requires_Update)
            {
                FBaseCVar* set_var, * set_prev; //redefining to reset
                set_var = FindCVar(SET_CVar_Name.c_str(), &set_prev);
                bool CVar_ReadOnly = set_var->GetFlags() & CVAR_NOSET;
				LogPipeOperation(logging, pipePath, operation, "CVar Read-Only: " + std::string(CVar_ReadOnly ? "TRUE" : "FALSE"));
                if (CVar_ReadOnly)
                {
                    LogPipeOperation(logging, pipePath, operation, "CVar is read-only, cannot set value.");
                    SET_CVar_ConsoleReturnString = "SET: CVar is read-only";
                }
                if (!CVar_ReadOnly) 
                {
                    LogPipeOperation(logging, pipePath, operation, "CVar value is different from desired value. Proceeding to set.");
                    
                    set_var->CmdSet(SET_CVar_Value.c_str());
					// Had to delete verification logic because the CmdSet may modify the value (eg. clamp to min/max), so verifying against the requested value is not reliable.
                    LogPipeOperation(logging, pipePath, operation, "CVar value successfully set.");
                    SET_CVar_ConsoleReturnString = "\"" + SET_CVar_Name + "\" is \"" + SET_CVar_Value + "\"";
					
				} //end if (!CVAR_ReadOnly)
			}//end if (CVar_Declared_And_Requires_Update)
		}//end if (SET_cvar_Command_ProperlyFormed)

        CCMD_ReplyToClient = SET_CVar_ConsoleReturnString;
    }
    else if (CCMD_Command == CMD_READ_LAST_LINE) {
        //ProcessReadLastLine(payload);
    }
    else if (CCMD_Command == CMD_START_LOG_STREAM) {
        //ProcessStartLogStream(payload);
    }
    else if (CCMD_Command == CMD_END_LOG_STREAM) {
        //ProcessEndLogStream(payload);
    }
    else if (CCMD_Command == CMD_CONSOLE_COMMAND) {
        std::string CMD_Prefix = CMD_CONSOLE_COMMAND;
        CMD_Prefix.append(" ");
        int prefixLength = CMD_Prefix.length();
        std::string ConsoleCommandStringToExecute = commandString.substr(prefixLength, commandString.length() - 1);
        std::string EXECUTE_ConsoleReturnString = "Executing Command: \"" + ConsoleCommandStringToExecute + "\"";
        LogPipeOperation(logging, pipePath, operation, EXECUTE_ConsoleReturnString);
        AddCommandString(ConsoleCommandStringToExecute.c_str());
        CCMD_ReplyToClient = EXECUTE_ConsoleReturnString;
    }
    else 
    {
        std::string INVALID_ConsoleReturnString = "Invalid Command: \"" + commandString + "\"";
        LogPipeOperation(logging, pipePath, operation, INVALID_ConsoleReturnString);
        CCMD_ReplyToClient = INVALID_ConsoleReturnString;
    }
    
}

