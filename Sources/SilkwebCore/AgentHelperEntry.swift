import Foundation

/// The `silkweb` helper's process entry (#129, #135), shared by the shipped helper and the test host (#248) so both
/// run the same commands. Only the key store differs: the shipped helper passes the keychain for both; the test host
/// passes a fixed test key and no signer.
public enum AgentHelperEntry {
    /// Runs one helper command and exits. `verifier` checks agent-grants.json for every command (#205); only `grant`
    /// commands get `signer`, and they sign only with a terminal on stdin.
    public static func main(
        _ arguments: [String], executable: String?, verifier: any AgentGrantVerifier, signer: (any AgentGrantSigner)?
    ) -> Never {
        AgentGrantKeys.verifier = verifier
        if arguments.first == "mcp" {
            // The stdio MCP server (#136): stdout carries MCP frames only, until stdin closes.
            exit(AgentMCPServer.main(arguments, handlesTermination: true))
        }
        // `grant init` (#186): owner setup. Prompts go to stderr as they're asked; stdout is plain text.
        let output =
            arguments.first == "grant"
            ? AgentGrantInit.run(arguments, console: .standard, executable: executable, signer: signer)
            : AgentHelper.run(arguments)
        FileHandle.standardOutput.write(Data(output.stdout.utf8))
        FileHandle.standardError.write(Data(output.stderr.utf8))
        exit(output.status)
    }
}
