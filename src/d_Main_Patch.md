// D_Main.CPP Patch Locations
...
// PUBLIC FUNCTION PROTOTYPES ----------------------------------------------
...
// Begin IPC Pipe + GZDoom API Addition
#include "externalpipe.h" // class
static ExternalPipe g_Pipe; // class instance
// End IPC Pipe + GZDoom API Addition
// PRIVATE FUNCTION PROTOTYPES ---------------------------------------------
...
void D_ErrorCleanup ()
{
...
	// Begin IPC Pipe + GZDoom API Addition
	// Close the pipe on error cleanup
	g_Pipe.Close();
  // End IPC Pipe + GZDoom API Addition
}
...
void D_DoomLoop ()
{
...
	vid_cursor->Callback();
	// Begin IPC Pipe + GZDoom API Addition
	// Open the pipe 'GZD' for communication
	g_Pipe.Open("GZD");
	// End IPC Pipe + GZDoom API Addition
	for (;;)
	{
		try
		{
      ...
      // Begin IPC Pipe + GZDoom API Addition
      // IPC Pipe + GZDoom API
			// Clear Write Queue
			if (!g_Pipe.writeQueue.empty())
			{
				g_Pipe.writeQueue.clear();
				g_Pipe.pipeStatus.writeQueueSize = 0;
			}
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
			// Write Pipe Buffer
			if (!g_Pipe.writeData.empty())
			{
				g_Pipe.Write();
				if (g_Pipe.pipeStatus.writeCompleted) {
					g_Pipe.writeData.clear();
				}
			}
			// End Windows IPC Pipe + GZDoom API
      // End IPC Pipe + GZDoom API Addition
    }
    catch (const CRecoverableError &error)
    ...
