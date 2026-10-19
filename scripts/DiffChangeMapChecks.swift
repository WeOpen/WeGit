import Foundation

@main struct DiffChangeMapChecks {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(
                Data("Diff map check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        typealias Tick = DiffChangeMap.Tick
        var passed: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else {
                throw NSError(
                    domain: "WeGit.DiffChangeMap", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: name])
            }
            passed.append(name)
        }
        // Actual Git -U3 fixture: @@ -1,6 +1,1006 @@ and @@ -147,7 +1147,7 @@.
        let unequal = [
            Tick(id: 0, offset: 0, extent: 1006.0 / 1154),
            Tick(id: 1, offset: 1146.0 / 1154, extent: 0.015),
        ]
        try check(
            "A tap near the bottom of a large mark selects that mark",
            DiffChangeMap.target(at: 0.7845753899480069 * 400, height: 400, ticks: unequal) == 0)
        try check(
            "The small later mark remains selectable",
            DiffChangeMap.target(at: 398, height: 400, ticks: unequal) == 1)
        let separated = [Tick(id: 4, offset: 0.1, extent: 0.4), Tick(id: 9, offset: 0.7, extent: 0.1)]
        try check(
            "A gap tap uses the nearest painted interval rather than its start",
            DiffChangeMap.target(at: 55, height: 100, ticks: separated) == 4)
        try check(
            "A gap nearer the later interval selects it",
            DiffChangeMap.target(at: 65, height: 100, ticks: separated) == 9)
        let thin = Tick(id: 7, offset: 0.2, extent: 0.001)
        try check("Tiny marks retain the two-pixel drawn height", thin.range(height: 100) == 20...22)
        try check(
            "The entire two-pixel mark is hittable",
            DiffChangeMap.target(at: 21.5, height: 100, ticks: [thin]) == 7)
        let overlap = [Tick(id: 1, offset: 0.2, extent: 0.3), Tick(id: 2, offset: 0.3, extent: 0.1)]
        try check(
            "Overlapping marks select the last painted mark",
            DiffChangeMap.target(at: 35, height: 100, ticks: overlap) == 2)
        try check("An empty map has no target", DiffChangeMap.target(at: 1, height: 100, ticks: []) == nil)
        try check(
            "Zero-height maps have no target", DiffChangeMap.target(at: 1, height: 0, ticks: unequal) == nil)
        try check(
            "Negative-height maps have no target",
            DiffChangeMap.target(at: 1, height: -1, ticks: unequal) == nil)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: passed, options: [.prettyPrinted, .sortedKeys]).write(
            to: output)
        print("\(passed.count) diff change map behavior checks passed.")
    }
}
