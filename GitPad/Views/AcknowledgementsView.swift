import SwiftUI

/// Settings → Acknowledgements. Shipping libgit2 inside the app requires its notices
/// (and those of its bundled zlib, PCRE, SHA-1 collision detection and ntlmclient code)
/// to go with the binary.
struct AcknowledgementsView: View {
    private let libgit2License: String = {
        guard let url = Bundle.main.url(forResource: "libgit2-COPYING", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text missing from this build."
        }
        return text
    }()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("libgit2").font(.headline)
                    Text("GitPad uses libgit2, unmodified, for all Git operations. libgit2 is licensed under the GNU GPL v2 with a linking exception, which permits linking it into GitPad. It includes code under the zlib, BSD (PCRE) and MIT licenses, reproduced in full below, and the xdiff library under the GNU LGPL v2.1. GitPad's complete source code, which lets you rebuild it with a modified library, is at github.com/BerkGozek/GitPad.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Link("github.com/libgit2/libgit2", destination: URL(string: "https://github.com/libgit2/libgit2")!)
                        .font(.callout)
                }
                .padding(.vertical, 4)
            }
            Section("License Text") {
                Text(libgit2License)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
