import AppKit
import SwiftUI

struct AboutView: View {
    private static let githubURL = URL(string: "https://github.com/Sha0huaZhang/Voanisa")!
    private static let licenseURL = URL(string: "https://github.com/Sha0huaZhang/Voanisa/blob/main/LICENSE")!

    var body: some View {
        Form {
            Section("settings.about") {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voanisa")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("settings.about.tagline")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Text("settings.about.description")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("settings.version") {
                    Text(AppVersion.display)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("settings.about.rustCore") {
                    Text(RustCore.version)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 14) {
                    Link("settings.about.github", destination: Self.githubURL)
                    Link("settings.about.license", destination: Self.licenseURL)
                    Button("settings.about.openLog") {
                        NSWorkspace.shared.open(Diagnostics.fileURL)
                    }
                }

                Text("settings.about.copyright")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
