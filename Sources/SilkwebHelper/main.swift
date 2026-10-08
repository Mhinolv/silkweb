import Foundation
import SilkwebCore

// The direct-distribution `silkweb` helper (#129, #135). It runs with Silkweb closed and is
// installed outside the app bundle; see docs/agent-memory.md › Command line.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "mcp" {
    // The stdio MCP server (#136): stdout carries MCP frames only, until stdin closes.
    exit(AgentMCPServer.main(arguments, handlesTermination: true))
}
let output = AgentHelper.run(arguments)
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.status)
