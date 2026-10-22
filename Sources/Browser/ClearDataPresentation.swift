import Foundation

/// A destructive destination captured before presentation, not a projection of the current Space.
@MainActor
struct ClearDataPresentation: Identifiable {
    let id = UUID()
    let profileID: UUID
    let profileName: String
    let data: BrowsingData

    init(profileName: String, data: BrowsingData) {
        profileID = data.profileID
        self.profileName = profileName
        self.data = data
    }
}
