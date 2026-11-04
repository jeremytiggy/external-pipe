ZDoom External Pipe API by JeremyTiggy

++ Version History ++
v1.3	Added UZDoom, Zandronum
		Added command line option "+pipe_nameUnique 1"
		Changed from GZDoom to Zdoom
v1.0	Fixed buffer overflow for command parameters
		Added configuration .PK3
v0.2	Removed warning about data validation for SET command. 
		Added "Pull" system description. 
v0.1	Initial Release

++ Summary ++
External programs can now change or read the value of console variables (CVars) for extended ACS/ZScript functionality.
External programs can now also send explicit Console Command strings to ZDoom, just as if they were typed.
This ultimately provides an outside data connection to the ZDoom console and CVar system.


++ Operation ++
The supporting code runs in the ZDoom 'D_DoomLoop' in d_main.cpp each tick (1/35th of a second). 
The class can be found in the new program 'externalpipe.h/.cpp'.
The API consists of a Windows IPC Named Pipe Server that takes commands from a connected Client, and writes a response back.
Each 'tick', or ZDoom program cycle, the API reads one command from the named pipe, parses it, executes it, then writes back the response.

++ Connection ++
The API uses a Windows IPC Named Pipe, the name of which differs with each engine.
Connect using a duplex async connection.
Send single command string (UTF-8, terminated \r\n) to server. 
Note: May need to flush write buffer if it doesn't auto-flush on return+newline. Consult relevant programming documentation.
Use Pipe Peek command to confirm that the server has response available.

++ Client-Driven Response ++
This system is Client-driven.
At the moment, it is a "Pull" system - this means that the Client must send a command to ZDoom to get a response.
The server will not send unsolicited messages to the Client.
All data received by the client from the server will be responses to the last transmitted command.

++ Console Variables ++
pipe_cycleTicksDisconnected - how many ticks to wait between new connection checks															
pipe_cycleTicksConnected - how many ticks to wait between Pipe Reads while a connection is active
pipe_noDataFrames - how many consecutive frames of no data received to wait before switching to the "no data" idle state
pipe_cycleTicksNoData - how many ticks to wait between Pipe Reads when in the "no data" idle state (after being connected but receiving no data for a while)
pipe_log - whether to log pipe activity to the console
pipe_logConsole - 0:log only to file, 1:log to file and console
pipe_enable - whether to enable the pipe at all
pipe_nameUnique - whether to use a unique name for the pipe (based on datetimestamp) to allow multiple instances of the game to run without interfering with each other's pipes
pipe_name - the name of the pipe that can be connected to
pipe_enabled - whether the pipe is currently enabled. 
pipe_open - whether the pipe is currently open. This is set by the pipe code itself
pipe_connected - whether the pipe is currently connected. This is set by the pipe code itself
pipe_latencyms - latency of the last completed pipe operation in milliseconds
pipe_debug - enable custom debugging functions (remove for production)
pipe_readData - command received from the other process, to be processed in the main loop
pipe_writeData - the data to be sent to the other process, to be set by the main loop. This is read by the pipe code itself

++ Latency ++
Within the main ZDoom loop, the logic doesn't execute every single tick.
If a client has not yet connected, the process checks for a new connection based on the value of CVAR pipe_cycleTicksDisconnected.
Once a client connects, the process check for new data according to the CVAR pipe_cycleTicksConnected.
If consecutive check for data turn up with not data for CVAR pipe_noDataFrames occurrences, then the process slows down in frequency to the CVAR pipe_cycleTicksNoData rate.
The process switches back to the higher frequency once data is received.
The current scan frequency can be found in CVAR pipe_latencyms.

++ Pipe Naming ++
Process		Name
--------------------
GZDoom		GZD
UZDoom		UZD
Zandronum	ZZD
If "+pipe_nameUnique 1" is included as a commandline argument, the name will be prefixed with a serial number to allow for multiple pipe instances.
The pipe name can be viewed with a "GET pipe_name" console command.

++ Pipe Data Payloads ++
Command									Function					Response
---------------------------------------------------------------------------------------------------------------
GET <Valid Existing Cvar Name>			Read value of CVar			"<cvar>" is "<current value>"
SET <Valid CVar Name> <Valid New Value>	Write new value of CVar		"<cvar>" is "<new value>"
COMMAND <console command string>		Pass string to Console		Executing Command: "<console command string>"

Example 1 - Client reads known declared CVar:
Client Sends: GET sv_cheats
ZDoom finds CVar "sv_cheats", then makes a copy of it's value as a string representation.
Server Sends: "sv_cheats" is "1"

Example 2 - Client sends new value for known declared CVar:
Client Sends: SET CV_sPlayerName DoomSlayer6566
ZDoom finds CVar "CV_sPlayername" and changes it from "Player" to "DoomSlayer6566".
ACS or ZScript running detects the change in the CVar and runs a script to update the Player's displayed name.
Server Sends: "CV_sPlayername" is "DoomSlayer6566"

Example 3 - Client sends explicit console command:
Client Sends: COMMAND puke 666
ZDoom console executes: puke 666.
ZDoom checks available numbered scripts in all loaded mods, find Script 666, and runs it.
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
2. Add in the pipe logic from the included 'd_main.cpp'
3. Save the updated 'd_main.cpp', then compile.
	
++ Applications ++
--- Powershell Script ---
Included are Windows Powershell script examples showing 
	 - how to connect to the ZDoom Named Pipe and test those particular features
	 - how to send console commands to ZDoom thru the pipe
Start ZDoom, then start or load a new game before you run either script.
The script runs best when executed as Administrator with the following command:
	powershell -ExecutionPolicy Bypass -File <absolute filepath of the script>
But, the script may run without Administrator privileges depending on your system configuration.

--- External Pipe Options Menu PK3 ---
Included is a options menu showing the status of the named pipe, and access to the Latency settings.
Use the Restart Pipe command in the menu to fix simple connectivity issues if a client is having a hard time connecting. 

When using the ExternalPipeSettingsMenu PK3 files, please make sure the load order is as follows:
00_ExternalPipeSettingsMenu_Shared.pk3
01_ExternalPipeSettingsMenu_ZDoom.pk3 OR 01_ExternalPipeSettingsMenu_Zandronum.pk3


--- Pre-Compiled ZDoom Versions ---
Included are compiled executables, all running the External Pipe process.
 - GZDoom 4.14.2
 - UZDoom 4.14.3
 - Zandronum 3.2.1
	
++ Credits ++
All contributors to ZDoom, GZDoom, UZDoom, Zandronum
JeremyTiggy, 2025
Most of the Pipe handling code comes from the Microsoft Developer Network
Most high-order functions were sourced from StackOverflow, MSDN

++ License ++
GNU General Public License
