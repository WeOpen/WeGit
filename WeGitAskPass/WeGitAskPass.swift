import Foundation
import WeGitCore

@main
struct WeGitAskPass {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw AuthenticationFailure.invalidRequest }
            let answer = try AskPassClient.answer(prompt: CommandLine.arguments[1])
            try FileHandle.standardOutput.write(contentsOf: Data((answer + "\n").utf8))
        } catch {
            // A helper must never echo prompts, replies, environment or credentials into Git's logs.
            exit(1)
        }
    }
}
