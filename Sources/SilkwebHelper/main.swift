import Foundation
import SilkwebCore

// The direct-distribution `silkweb` helper (#129, #135). It runs with Silkweb closed and is
// installed outside the app bundle; see docs/agent-memory.md › Command line.
let arguments = Array(CommandLine.arguments.dropFirst())
// #205: every command verifies agent-grants.json with the keychain key. Only `grant` commands get a signer, and they
// sign only with a terminal on stdin.
AgentGrantKeys.verifier = AgentGrantKeychain()
if arguments.first == "mcp" {
    // The stdio MCP server (#136): stdout carries MCP frames only, until stdin closes.
    exit(AgentMCPServer.main(arguments, handlesTermination: true))
}
// `grant init` (#186): owner setup. Prompts go to stderr as they're asked; stdout is plain text.
let output =
    arguments.first == "grant"
    ? AgentGrantInit.run(
        arguments, console: .standard, executable: CommandLine.arguments.first, signer: AgentGrantKeychain())
    : AgentHelper.run(arguments)
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.status)
