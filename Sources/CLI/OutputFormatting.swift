import Foundation

enum OutputFormatting {
    /// Encodes values as pretty-printed, stable-ordered JSON (US06: scriptable).
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    /// Renders rows as aligned columns with a header line.
    static func table(header: [String], rows: [[String]]) -> String {
        let all = [header] + rows
        var widths = [Int](repeating: 0, count: header.count)
        for row in all {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        return all.map { row in
            row.enumerated()
                .map { i, cell in
                    i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                }
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
