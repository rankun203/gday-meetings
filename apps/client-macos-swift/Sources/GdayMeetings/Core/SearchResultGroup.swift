import Foundation

/// Meetings follow their first ranked match; matches retain their original order within each meeting.
struct SearchResultGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    private(set) var matches: [SearchDisplayResult]
    let rank: Int

    static func grouping(_ results: [SearchDisplayResult]) -> [SearchResultGroup] {
        var groups: [SearchResultGroup] = []
        var groupIndexes: [UUID: Int] = [:]
        var seenMatches: [UUID: Set<String>] = [:]
        for (index, result) in results.enumerated() {
            guard seenMatches[result.meetingID, default: []].insert(result.id).inserted else { continue }
            if let groupIndex = groupIndexes[result.meetingID] {
                groups[groupIndex].matches.append(result)
            }
            else {
                groupIndexes[result.meetingID] = groups.count
                groups.append(SearchResultGroup(id: result.meetingID, matches: [result], rank: index + 1))
            }
        }
        return groups
    }
}
