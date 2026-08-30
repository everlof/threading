import Foundation
import ThreadingExtensionKit

public enum GitLabMergeRequestState: String, Codable, CaseIterable, Equatable, Sendable {
    case opened
    case closed
    case locked
    case merged

    public var label: String {
        switch self {
        case .opened: "Open"
        case .closed: "Closed"
        case .locked: "Locked"
        case .merged: "Merged"
        }
    }

    public var status: ExtensionStatusRole {
        switch self {
        case .opened, .merged: .positive
        case .closed: .neutral
        case .locked: .warning
        }
    }
}

public struct GitLabMergeRequest: Equatable, Sendable {
    public let iid: Int64
    public let state: String
    public let sourceBranch: String
    public let sourceProjectID: Int64?
    public let projectID: Int64
    public let updatedAt: String

    public init(
        iid: Int64,
        state: String,
        sourceBranch: String,
        sourceProjectID: Int64?,
        projectID: Int64,
        updatedAt: String
    ) {
        self.iid = iid
        self.state = state
        self.sourceBranch = sourceBranch
        self.sourceProjectID = sourceProjectID
        self.projectID = projectID
        self.updatedAt = updatedAt
    }
}

extension GitLabMergeRequest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case iid
        case state
        case sourceBranch = "source_branch"
        case sourceProjectID = "source_project_id"
        case projectID = "project_id"
        case updatedAt = "updated_at"
    }
}

public struct GitLabBranchMergeRequest: Equatable, Sendable {
    public let branch: String
    public let state: GitLabMergeRequestState
    public let updatedAt: String
    public let iid: Int64

    public init(
        branch: String,
        state: GitLabMergeRequestState,
        updatedAt: String,
        iid: Int64
    ) {
        self.branch = branch
        self.state = state
        self.updatedAt = updatedAt
        self.iid = iid
    }
}

public enum GitLabMergeRequestReductionError: Error, Equatable, Sendable {
    case malformed
    case unknownState(String)
    case factLimitExceeded
}

public enum GitLabMergeRequestReducer {
    public static func decodePage(_ data: Data) throws -> [GitLabMergeRequest] {
        let records: [GitLabMergeRequest]
        do {
            records = try JSONDecoder().decode([GitLabMergeRequest].self, from: data)
        } catch {
            throw GitLabMergeRequestReductionError.malformed
        }
        guard records.count <= GitLabStateLimits.maximumMergeRequestsPerPage else {
            throw GitLabMergeRequestReductionError.malformed
        }
        return records
    }

    public static func reduce(
        _ records: [GitLabMergeRequest]
    ) throws -> [GitLabBranchMergeRequest] {
        var selected: [String: (request: GitLabBranchMergeRequest, timestamp: GitLabTimestamp)] = [:]

        for record in records {
            guard let sourceProjectID = record.sourceProjectID,
                  sourceProjectID == record.projectID else {
                continue
            }
            guard !record.sourceBranch.isEmpty,
                  record.sourceBranch.utf8.count <= ExtensionFactSubject.maximumBranchBytes,
                  record.iid > 0,
                  record.projectID > 0,
                  let timestamp = GitLabTimestamp(record.updatedAt) else {
                throw GitLabMergeRequestReductionError.malformed
            }
            guard let state = GitLabMergeRequestState(rawValue: record.state) else {
                throw GitLabMergeRequestReductionError.unknownState(
                    String(record.state.prefix(64))
                )
            }

            let candidate = GitLabBranchMergeRequest(
                branch: record.sourceBranch,
                state: state,
                updatedAt: record.updatedAt,
                iid: record.iid
            )
            if let existing = selected[record.sourceBranch] {
                if timestamp > existing.timestamp
                    || (timestamp == existing.timestamp && record.iid > existing.request.iid) {
                    selected[record.sourceBranch] = (candidate, timestamp)
                }
            } else {
                selected[record.sourceBranch] = (candidate, timestamp)
            }
        }

        guard selected.count <= GitLabStateLimits.maximumFactsPerRepository else {
            throw GitLabMergeRequestReductionError.factLimitExceeded
        }
        return selected.values.map(\.request).sorted { $0.branch < $1.branch }
    }
}

public enum GitLabProjectPathEncoder {
    private static let hexadecimal = Array("0123456789ABCDEF".utf8)

    /// Encodes the complete namespace/project path as one GitLab project path component.
    public static func encode(_ path: String) -> String {
        var result: [UInt8] = []
        result.reserveCapacity(path.utf8.count * 3)
        for byte in path.utf8 {
            if isUnreserved(byte) {
                result.append(byte)
            } else {
                result.append(UInt8(ascii: "%"))
                result.append(hexadecimal[Int(byte >> 4)])
                result.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    public static func mergeRequestsURL(
        repositoryPath: String,
        page: Int
    ) -> String {
        "https://gitlab.com/api/v4/projects/\(encode(repositoryPath))"
            + "/merge_requests?scope=all&state=all&order_by=updated_at&sort=desc"
            + "&per_page=100&page=\(page)"
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "~")
    }
}

private struct GitLabTimestamp: Comparable, Equatable {
    let seconds: Int64
    let fraction: [UInt8]

    init?(_ value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20, bytes.count <= 64,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":"),
              let year = Self.number(bytes, 0..<4),
              let month = Self.number(bytes, 5..<7),
              let day = Self.number(bytes, 8..<10),
              let hour = Self.number(bytes, 11..<13),
              let minute = Self.number(bytes, 14..<16),
              let second = Self.number(bytes, 17..<19),
              year > 0, (1...12).contains(month),
              (1...Self.daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        var index = 19
        var parsedFraction: [UInt8] = []
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            let start = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                parsedFraction.append(bytes[index] - UInt8(ascii: "0"))
                index += 1
            }
            guard index > start else { return nil }
            while parsedFraction.last == 0 { parsedFraction.removeLast() }
        }

        let offsetSeconds: Int
        if index < bytes.count, bytes[index] == UInt8(ascii: "Z") {
            index += 1
            offsetSeconds = 0
        } else {
            guard index + 6 == bytes.count,
                  bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-"),
                  bytes[index + 3] == UInt8(ascii: ":"),
                  let offsetHour = Self.number(bytes, (index + 1)..<(index + 3)),
                  let offsetMinute = Self.number(bytes, (index + 4)..<(index + 6)),
                  (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else {
                return nil
            }
            let magnitude = offsetHour * 3_600 + offsetMinute * 60
            offsetSeconds = bytes[index] == UInt8(ascii: "+") ? magnitude : -magnitude
            index += 6
        }
        guard index == bytes.count else { return nil }

        let days = Self.daysFromCivil(year: year, month: month, day: day)
        seconds = days * 86_400
            + Int64(hour * 3_600 + minute * 60 + second - offsetSeconds)
        fraction = parsedFraction
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        let count = max(lhs.fraction.count, rhs.fraction.count)
        for index in 0..<count {
            let left = index < lhs.fraction.count ? lhs.fraction[index] : 0
            let right = index < rhs.fraction.count ? rhs.fraction[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var value = 0
        for index in range {
            let byte = bytes[index]
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else {
                return nil
            }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Howard Hinnant's civil-date conversion, with 1970-01-01 as day zero.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        var adjustedYear = year
        if month <= 2 { adjustedYear -= 1 }
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era * 146_097 + dayOfEra - 719_468)
    }
}
