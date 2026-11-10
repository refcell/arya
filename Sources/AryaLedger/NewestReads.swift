import AryaCore
import Foundation

extension LedgerReader {
    /// Up to `limit` events matching `filter` with `seq < before` (the newest when nil),
    /// returned in `seq` order. Reads segments newest to oldest and stops once it has
    /// enough: within a segment, the sieve picks candidate lines from the bytes and only
    /// the newest candidates are opened. For recap and activity views ("the last 20
    /// approvals") over weeks of history.
    public func newest(_ filter: LedgerFilter = LedgerFilter(), before: Int64? = nil, limit: Int)
        throws -> [Event]
    {
        let limit = max(1, limit)
        do {
            return try newestBySegment(filter, before: before, limit: limit)
        } catch is NonContiguousSegment {
            // A damaged or hand-edited ledger: fall back to one forward pass.
            var window: [Event] = []
            try forEach(filter) { event in
                if let before, event.seq >= before { return }
                window.append(event)
                if window.count > limit { window.removeFirst() }
            }
            return window
        }
    }

    private func newestBySegment(_ filter: LedgerFilter, before: Int64?, limit: Int) throws
        -> [Event]
    {
        let sieve = LineSieve(filter)
        var found: [Event] = []  // newest first
        for segment in try existingSegments().reversed() {
            guard let first = try firstEvent(of: segment) else { continue }
            if let before, first.seq >= before { continue }
            if let since = filter.since, let last = try lastEvent(of: segment), last.at < since {
                break
            }
            var candidates: [(offset: Int64, length: Int, number: Int)] = []
            try scanLines(segment) { line, offset, number in
                if let before, first.seq + Int64(number) - 1 >= before { return }
                if sieve.passesAll || line.withUnsafeBufferPointer({ sieve.admits($0) }) {
                    candidates.append((offset, line.count, number))
                }
            }
            let fd = try FileIO.open(segment.url, O_RDONLY)
            defer { close(fd) }
            for candidate in candidates.reversed() {
                let line = try FileIO.read(
                    fd, at: candidate.offset, count: candidate.length, name: segment.name)
                let event: Event
                do {
                    event = try opened(LedgerLine.open(line))
                } catch let problem as LineProblem {
                    throw LedgerReadError(
                        segment: segment.name, line: candidate.number, offset: candidate.offset,
                        problem: problem)
                }
                guard event.seq == first.seq + Int64(candidate.number) - 1 else {
                    throw NonContiguousSegment()
                }
                guard filter.matches(event) else { continue }
                found.append(event)
                if found.count == limit { return found.reversed() }
            }
        }
        return found.reversed()
    }
}

private struct NonContiguousSegment: Error {}
