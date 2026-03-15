GZDoom External Pipe API by JeremyTiggy

++ Version History ++
v1.0	Fixed buffer overflow for command parameters
		Added configuration .PK3
v0.2	Removed warning about data validation for SET command. 
		Added "Pull" system description. 
v0.1	Initial Release

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
2. Add in the pipe logic from the included 'd_main.cpp' or just replace it if it is 4.14.4.
3. Save the updated 'd_main.cpp', then compile.
	
++ Sample Applications ++
--- Powershell Script ---
Included are Windows Powershell script examples showing 
	 - how to connect to the GZDoom Named Pipe and test those particular features
	 - how to send console commands to GZDoom thru the pipe
Start GZDoom, then start or load a new game before you run either script.
The script runs best when executed as Administrator with the following command:
	powershell -ExecutionPolicy Bypass -File <absolute filepath of the script>
But, the script may run without Administrator privileges depending on your system configuration.


--- GZDoom Menu PK3 ---
Use the included ExternalPipeSettingsMenu.pk3 to adjust pipe settings or enable/disable the pipe.

--- GZDoom.exe ---
Included is a compliled version of the GZDoom.EXE for 4.14.2. Paste this into an existing installation of 4.14.2 to activate the pipe.
	
++ Credits ++
All contributors to GZDoom
JeremyTiggy, 2025
Most of the Pipe handling code comes from the Microsoft Developer Network

++ License ++
GNU General Public License
