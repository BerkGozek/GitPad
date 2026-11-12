# Third-party notices

GitPad's own code is under the [MIT License](LICENSE). The app also includes the following
third-party software. Their notices ship inside the app too (Settings → Acknowledgements).

## libgit2 1.9.2

- Source: <https://github.com/libgit2/libgit2>, built through the SwiftPM package
  <https://github.com/ibrahimcetin/libgit2> (tag `1.9.2`, unmodified library sources)
- License: **GNU GPL v2 with a linking exception**. The exception allows linking the unmodified
  library into any program, including one under a different license, and distributing that
  program; the GPL still applies to libgit2 itself (e.g. if you modify and redistribute it).
- Full text: [`GitPad/Resources/libgit2-COPYING.txt`](GitPad/Resources/libgit2-COPYING.txt)

libgit2 bundles code under its own licenses. The full notices are in the file above. The parts
compiled into GitPad (iOS build) are:

| Component | License |
|---|---|
| zlib | zlib License |
| PCRE (regular expressions) | BSD |
| SHA-1 collision detection | MIT |
| ntlmclient | MIT |
| llhttp (HTTP parser) | MIT |
| xdiff (LibXDiff, diff/merge engine) | **GNU LGPL v2.1 or later** (header in `deps/xdiff/*`; LGPL text at the end of the license file) |
| wildmatch | Public domain |

Windows-only parts listed in libgit2's license file (WinHTTP definitions under LGPL) are not
compiled into the iOS app.

### LGPL (xdiff)

On iOS, xdiff is linked statically into the app. The LGPL requires that users can rebuild the
app with a modified version of the library. GitPad meets this by publishing its complete source
code, including the build setup (`project.yml`, `Packages/GitPadKit/Package.swift`), at
<https://github.com/BerkGozek/GitPad>: swap in a modified libgit2/xdiff and rebuild.
