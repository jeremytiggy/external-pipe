#pragma once
#include <string>
#include <tchar.h>
#include "c_dispatch.h"   // for AddCommandString
#include "g_level.h"      // for level startup events

/*
| Step                | Action                                                                 |
|---------------------|------------------------------------------------------------------------|
| Open                | Once before loop                                                       |
| Connect             | If not connected, before each operation                                |
| Write               | If not pending, set writeData and call Write()                         |
| Write (pending)     | Call Write() to poll for completion                                    |
| Read                | If not pending and HasReadData(), call Read()                          |
| Read (pending)      | Call Read() to poll for completion                                     |
| Error/Disconnect    | Call Close()                                                           |
| Shutdown            | Call Close()                                                           |
---
*/

#define CMD_CONSOLE_COMMAND     "COMMAND"
#define CMD_CVAR_GET            "GET"
#define CMD_READ_LAST_LINE      "RL"
#define CMD_START_LOG_STREAM    "SL"
#define CMD_END_LOG_STREAM      "EL"
#define CMD_CVAR_SET            "SET"

/*
Command									Response														Detail
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------
GET 									GET: missing variable name. Proper usage is GET <cvar>			Do not pass less than one argument
GET <cvar> <cvar>						GET: too many arguments. Proper usage is GET <cvar>				Do not pass more than one argument
GET <Undefined Cvar Name>				GET: "<Undefined CVar Name>" is unset							CVar is not declared.
                                                                                                        Declare first with GET or by loading mod.
GET <Defined CVar>						"<CVar>" is "<current value>"									The Cvar, named  in the first set of double-quotes,
                                                                                                        is declared and has the value in the second set of double-quotes."
SET <CVar Name>							SET: need variable value. Proper usage is SET <cvar> <value>	Do not pass only one argument
SET <CVar Name> <value> <value>			SET: too many arguments. Proper usage is SET <cvar> <value>		Do not pass more than two arguments
SET 									SET: malformed command. Proper usage is SET <cvar> <value>		Do not pass less than one argument
SET <Invalid CVar Name> <value>			SET: CVar could not be created									Do not use invalid names for CVars
SET <CVar Name> <current value>			"<Cvar>" is already  "<current value>"							New and Current Value are the same; No change
SET <Read-Only CVar Name> <value>		SET: CVar is read-only											CVar is defined as Read-Only
SET <CVar Name> <invalid value>			SET: value could not be verified after setting.					New Value of Cvar might be invalid
SET <New CVar Name> <Initial value>		"<cvar>" is "<initial value>"									Cvar successfully declared and initialized to <Initial Value>
SET <Existing CVar Name> <new value>	"<cvar>" is "<new value>"										Cvar value successfully changed to <new value>
                                                                                                        from <current value>
COMMAND <command string>				Executing Command: "<command string>"							Command passed to console
COMMAND <command 1>; <command 2>; …		Executing Command: "<command 1>; <command 2>; ..."				Multiple commands can be passed to the console
                                                                                                        when separated by semi-colons

*/

// Add this method declaration to your ExternalPipe class

    

class ExternalPipe
{
public:
    ExternalPipe();
    ~ExternalPipe();

    bool Open(const std::string& pipeName);
    bool Connect();
    void Close();

    bool Write();
    //std::string Read();
    bool Read();

    bool IsValid();
    bool IsConnected();
    bool HasReadData();
    void Flush();

    unsigned long ConsolePositionStart;
    void AddToWriteQueue(const std::string& stringData);
    void ProcessPipeCommand(const std::string& command);
    //void ProcessCVarSet(const std::string& payload);

    std::string writeData = ""; // Data for Write() command
    std::string writeQueue = "";
    std::string readData = "";  // Data from Read() command
    std::string CCMD_Command = "";
    const unsigned long Max_CCMD_Arguments = 10;
    std::string CCMD_argumentVector[10]; //argv from Console Command, ArgumentVector[]
    unsigned long CCMD_argumentCount = 0; //argv.argc() from Console Command, ArgumentVector.ArgumentCount
    std::string CCMD_ReplyToClient = "";

    
    std::string GET_CVar_Name = "";
    std::string GET_CVar_Value = "";
    std::string GET_CVar_ConsoleReturnString = "";
    std::string SET_CVar_Name = "";
    std::string SET_CVar_Value = "";
    std::string SET_CVar_ConsoleReturnString = "";
    
    struct PipeState {
        void* pipeHandle; // HANDLE
        bool open;
        bool connected;
        bool connectPending;
        char bytesWriteFileBuffer[4096]; // temporary buffer for writing
        unsigned long bytesWriteFileBufferLength; // length of data in bytesOutBuffer
        unsigned long bytesWritten; // number of bytes written so far
        bool writeFileResult = false; // result of WriteFile
        unsigned long writeFileReturnCode; // error code from WriteFile
        char bytesReadFileBuffer[4096];  // temporary buffer for reading
        unsigned long bytesReadFileBufferLength; // length of data in bytesReadFileBuffer
        unsigned long bytesToRead; // number of bytes requested to read
        unsigned long bytesReceived;  // number of bytes read so far
        bool readFileResult = false; // result of ReadFile
        unsigned long readFileReturnCode = 0; // error code from ReadFile
        bool writePending;
        unsigned long writeQueueSize = 0;
        bool writeCompleted;
        bool readPending;
        bool readCompleted;
        unsigned long PeekTotalBytesAvailable = 0;
        void* connectEvent = nullptr; // For Connect overlapped event
        void* writeEvent = nullptr;   // For Write overlapped event
        void* readEvent = nullptr;
        void* connectOverlapped = nullptr;
        void* writeOverlapped = nullptr;
        void* readOverlapped = nullptr;

    } pipeStatus;

private:
    //Configuration
    const bool blocking = false;
    const bool WaitForCompletion = false; // if blocking, wait indefinitely for completion
    const bool overlappedIO = true;
    const bool peekBeforeRead = true;
    const bool peekRequiredForRead = true; // if true, HasReadData() must be true before Read()
    const bool appendCRLF = true;
    const bool logging = false;
    const std::string crlf = "\r\n";
    unsigned long defaultReadSize = 4096; // default number of bytes to read if not peeking first
    unsigned long overlappedTimeout = 100; // milliseconds to wait for overlapped operations

    // Path
    std::string pipePath;

    // Helper methods
    void HandleClientDisconnection(const std::string& operation, unsigned long errorCode);
    void CleanupConnectResources();
	void CleanupWriteResources();
	void CleanupReadResources();
    bool PrepareWriteData();
    bool PrepareReadBuffer();
    bool FinalizeWriteOperation(bool success);
    bool FinalizeReadOperation(bool success);
};
