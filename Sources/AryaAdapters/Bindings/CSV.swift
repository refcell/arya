import Foundation

/// A small RFC 4180 reader: comma-separated fields, double-quoted fields that may hold commas,
/// newlines, and doubled quotes, and LF or CRLF line ends. The first row is the header.
enum CSV {
    /// The rows after the header as dictionaries keyed by header name. Empty cells are absent,
    /// and blank lines are skipped.
    static func records(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        return rows.dropFirst().compactMap { row in
            var record: [String: String] = [:]
            for (index, name) in header.enumerated() where index < row.count {
                if !row[index].isEmpty { record[name] = row[index] }
            }
            return record.isEmpty ? nil : record
        }
    }

    /// The header row, in order.
    static func header(_ text: String) -> [String] { parse(text).first ?? [] }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let scalar = pending {
                pending = nil
                return scalar
            }
            return iterator.next()
        }
        func endRow() {
            row.append(field)
            field = ""
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while let scalar = next() {
            if quoted {
                if scalar == "\"" {
                    if let following = next() {
                        if following == "\"" {
                            field.unicodeScalars.append("\"")
                        } else {
                            quoted = false
                            pending = following
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty: quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                if let following = next(), following != "\n" { pending = following }
                endRow()
            case "\n": endRow()
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
