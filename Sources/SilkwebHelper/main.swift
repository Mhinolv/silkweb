import Foundation
import SilkwebCore

// The direct-distribution `silkweb` helper (#129, #135). It runs with Silkweb closed and is
// installed outside the app bundle; see docs/agent-memory.md › Command line.
let output = AgentHelper.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.status)
