import Foundation
import SilkwebCore

// The direct-distribution `silkweb` helper (#129, #135). It runs with Silkweb closed and is
// installed outside the app bundle; see docs/agent-memory.md › Command line.
// #205: every command verifies agent-grants.json with the keychain key. Only `grant` commands get a signer, and they
// sign only with a terminal on stdin.
AgentHelperEntry.main(
    Array(CommandLine.arguments.dropFirst()), executable: CommandLine.arguments.first, verifier: AgentGrantKeychain(),
    signer: AgentGrantKeychain())
