import SwiftUI

enum SidebarItem: Identifiable, Hashable {
    case songs
    case albums
    case playlist(UUID)
    case about
    case settings

    var id: String {
        switch self {
        case .songs: return "songs"
        case .albums: return "albums"
        case .playlist(let id): return "playlist-\(id.uuidString)"
        case .about: return "about"
        case .settings: return "settings"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .songs: return "sidebar.songs"
        case .albums: return "sidebar.albums"
        case .playlist: return "sidebar.playlists"
        case .about: return "sidebar.about"
        case .settings: return "sidebar.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .albums: return "square.stack"
        case .playlist: return "music.note.list"
        case .about: return "info.circle"
        case .settings: return "gearshape"
        }
    }
}
