GZDoom External Pipe API by JeremyTiggy

++ Version History ++
v0.1	Initial Release
v0.2	Removed warning about data validation for SET command. 
		Added "Pull" system description. 

++ Summary ++
External programs can now change or read the value of console variables (CVars) for extended ACS/ZScript functionality.
External programs can now also send explicit Console Command strings to GZDoom, just as if they were typed.
This ultimately provides an outside data connection to the GZDoom console and CVar system.


++ Operation ++
The supporting code runs in the GZDoom 'D_DoomLoop' in d_main.cpp each tick (1/35th of a second). 
The class can be found in the new program 'externalpipe.h/.cpp'.
The API consists of a Windows IPC Named Pipe Server, named 'GZD' that takes commands from a connected Client, and writes a response back.
Each 'tick', or GZDoom program cycle, the API reads one command from the named pipe, parses it, executes it, then writes back the response.


++ Connection ++
The API uses a Windows IPC Named Pipe, 'GZD.' 
Connect using a duplex async connection.
Send single command string (UTF-8, terminated \r\n) to server. 
Note: May need to flush write buffer if it doesn't auto-flush on return+newline. Consult relevant programming documentation.
Use Pipe Peek command to confirm that the server has response available.

++ Client-Driven Response ++
This system is Client-driven.
At the moment, it is a "Pull" system - this means that the Client must send a command to GZDoom to get a response.
The server will not send unsolicited messages to the Client.
All data received by the client from the server will be responses to the last transmitted command.


++ Proper Usage ++

Command									Function					Response
---------------------------------------------------------------------------------------------------------------
GET <Valid Existing Cvar Name>			Read value of CVar			"<cvar>" is "<current value>"
SET <Valid CVar Name> <Valid New Value>	Write new value of CVar		"<cvar>" is "<new value>"
COMMAND <console command string>		Pass string to Console		Executing Command: "<console command string>"

Example 1 - Client reads known declared CVar:
Client Sends: GET sv_cheats
GZDoom finds CVar "sv_cheats", then makes a copy of it's value as a string representation.
Server Sends: "sv_cheats" is "1"

Example 2 - Client sends new value for known declared CVar:
Client Sends: SET CV_sPlayerName DoomSlayer6566
GZDoom finds CVar "CV_sPlayername" and changes it from "Player" to "DoomSlayer6566".
ACS or ZScript running detects the change in the CVar and runs a script to update the Player's displayed name.
Server Sends: "CV_sPlayername" is "DoomSlayer6566"

Example 3 - Client sends explicit console command:
Client Sends: COMMAND puke 666
GZDoom console executes: puke 666.
GZDoom checks available numbered scripts in all loaded mods, find Script 666, and runs it.
Server Sends: Executing Command: "puke 666"


++ Troubleshooting ++

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
SET <New CVar Name> <Initial value>		"<cvar>" is "<initial value>"									Cvar successfully declared and initialized to <Initial Value>
SET <Existing CVar Name> <new value>	"<cvar>" is "<new value>"										Cvar value successfully changed to <new value> 
																										from <current value>
COMMAND <command string>				Executing Command: "<command string>"							Command passed to console
COMMAND <command 1>; <command 2>; …		Executing Command: "<command 1>; <command 2>; ..."				Multiple commands can be passed to the console 
																										when separated by semi-colons


++ Compiling ++
1. Add 'externalpipe.cpp' and 'externalpipe.h' to the same folder as 'd_main.cpp'.
2. Modify 'd_main.cpp' as follows:
	a. Add '#include #include "externalpipe.h"' to the end of the 'HEADER FILES' region.
	b. Add 'static ExternalPipe g_Pipe;' to the end of the 'PUBLIC FUNCTION PROTOTYPES' region.
	c. Add the line 'g_Pipe.Close();' to the end of the function 'void D_ErrorCleanup ()'.
	d. Add the line 'g_Pipe.Open("GZD"); int pipe_counter = 0;' before the 'for (;;)' loop in 'void D_DoomLoop()'.
	e. Add the following lines of code after the line 'TryRunTics ();' in 'void D_DoomLoop ()':

	// Windows IPC Pipe + GZDoom API
	pipe_counter++;
	if (pipe_counter > 0) // Adjust this value to change pipe read/write frequency
	{
		// Windows IPC Pipe
		// Clear Write Queue
		if (!g_Pipe.writeQueue.empty()) 
		{
			g_Pipe.writeQueue.clear();
			g_Pipe.pipeStatus.writeQueueSize = 0;
		}

		// Windows IPC Pipe
		// Read
		g_Pipe.Read();
		
		// GZDoom API
		// Process Read Data, check for Console Commands
		if (!g_Pipe.readData.empty()) {
			g_Pipe.ProcessPipeCommand(g_Pipe.readData);
			g_Pipe.readData.clear();
		}
		// Send Console Command Reply to Pipe Write Buffer
		if (!g_Pipe.CCMD_ReplyToClient.empty()) {
			g_Pipe.writeData.clear();
			g_Pipe.writeData = g_Pipe.CCMD_ReplyToClient;
			g_Pipe.CCMD_ReplyToClient.clear();
		}
		// Windows IPC Pipe
		// Write Pipe Buffer
		if (!g_Pipe.writeData.empty()) 
		{
			g_Pipe.Write();
			if (g_Pipe.pipeStatus.writeCompleted) {
				g_Pipe.writeData.clear();
			}
		}
		pipe_counter = 0; // reset counter
	}//end if (pipe_counter > 0)
	// End Windows IPC Pipe + GZDoom API
	
	f. Save the updated 'd_main.cpp', then compile.
	
++ Sample Applications ++
--- Powershell Script ---
Included is a Windows Powershell script example showing 
	 - how to connect to the GZDoom External Pipe API
	 - how to formulate API commands
	 - how to read responses from GZDoom
Start GZDoom, then start or load a new game before you run the script.
The script runs best when executed as Administrator with the following command:
	powershell -ExecutionPolicy Bypass -File <absolute filepath of the script>
But, the script may run without Administrator privileges depending on your system configuration.
You can type GET or SET commands, direct console commands, or use one of the other included demo functions.


--- ACS Script Demo ---
Included is a PK3 developed in SLADE, ExternalPipeAPI.pk3.
There are two demo ACS scripts included in the PK3.
 - API.acs: shows how to trigger an internal event when a CVar is changed via the Pipe API.
 - PlayerInfoCVARs.acs: shows how to populate player info that can be read by the client.


--- GZDoom.exe ---
Included is a compliled version of the GZDoom.EXE for 4.14.2. Paste this into an existing installation of 4.14.2 to activate the pipe.
	
++ Credits ++
All contributors to GZDoom
JeremyTiggy, 2025
Most of the Pipe handling code comes from the Microsoft Developer Network

++ License ++
GNU General Public License
