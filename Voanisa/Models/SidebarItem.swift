import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case songs
    case playlists
    case albums
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .songs: return "sidebar.songs"
        case .playlists: return "sidebar.playlists"
        case .albums: return "sidebar.albums"
        case .settings: return "sidebar.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .playlists: return "music.note.list"
        case .albums: return "square.stack"
        case .settings: return "gearshape"
        }
    }
}
