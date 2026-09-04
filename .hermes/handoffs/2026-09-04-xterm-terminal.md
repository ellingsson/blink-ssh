# BlinkSSH xterm terminal handoff

## Current state

The `ssh-only-clean` branch replaces the unsuccessful hterm renderer experiment with a local xterm.js 5.5.0 terminal embedded in `WKWebView`. No renderer resource is fetched from a CDN or any other network source.

The working tree was made ready for commit: abandoned untracked hterm prototype files and the superseded handoff were removed. The files in this handoff are intentionally tracked.

## Implemented behavior

- `SSHOnly/XTermTerminalView.swift` hosts the local renderer and exchanges only base64 through the Swift/JavaScript boundary.
- `SSHOnly/XTermBridge.js` encodes typed Unicode input to UTF-8 bytes and decodes arbitrary terminal bytes.
- `DirectSSHSession.receiveOutput` uses `Data`; output is not routed through lossy Swift string conversion before the renderer.
- Initial PTY dimensions come from the renderer. Resize messages update the remote PTY.
- The local xterm distribution and MIT license are in `SSHOnly/TerminalAssets`.
- Normal interactive profiles expose tmux buttons: C, P, N, D, which send `Ctrl-B` plus `c`, `p`, `n`, `d` respectively.
- `SSHProfile.command` persists an optional command. A nonempty command uses the SSH exec request rather than typing into an interactive shell; output remains visible and the session closes after command completion. Tmux controls are hidden for command profiles.

## Key files

- `SSHOnly/TerminalViewController.swift`: terminal screen, renderer hookup, resize and tmux toolbar.
- `SSHOnly/DirectSSHSession.swift`: SSH connection, shell/exec selection, output and close handling.
- `SSHOnly/XTermTerminalView.swift`: WebKit message boundary.
- `SSHOnly/XTerminal.html`, `SSHOnly/XTerminal.js`, `SSHOnly/XTermBridge.js`: local renderer and byte bridge.
- `SSHOnly/ProfileStore.swift`, `SSHOnly/SSHOnlyApp.swift`: optional profile command storage and editor field.
- `SSHOnly/TerminalBytes.swift`: base64 helpers and tmux shortcut bytes.

## Verification run on 2026-09-04

Passed:

- `node SSHOnly/Tests/XTermBridgeTests.js`
- `node --check SSHOnly/XTermBridge.js`
- `node --check SSHOnly/XTerminal.js`
- `swiftc -parse-as-library SSHOnly/TerminalBytes.swift SSHOnly/Tests/TerminalBytesTests.swift -o /tmp/TerminalBytesTests && /tmp/TerminalBytesTests`
- `swiftc -parse-as-library SSHOnly/ProfileStore.swift SSHOnly/Tests/ProfileStoreTests.swift -o /tmp/ProfileStoreTests && /tmp/ProfileStoreTests`
- `plutil -lint BlinkSSH.xcodeproj/project.pbxproj`
- `git diff --cached --check`
- Simulator build for device `7F977299-10A1-4961-8AE4-5384BEAFF701`
- Signed iPhoneOS build for generic iOS destination

The iPhoneOS build emitted the pre-existing orientation warning: all interface orientations should be supported unless the app requires full screen. It did not fail the build.

## Manual validation still useful

The xterm SSH terminal was previously installed and confirmed working on the physical iPhone. After future renderer or SSH changes, manually check a direct SSH session, ANSI/full-screen application, rotation with `stty size`, tmux controls, ProxyJump, and an exec-command profile whose command exits.

## Constraints

Keep the SSH-only transport boundary. Do not introduce a CDN-backed terminal asset, do not serialize raw SSH terminal data through `String`, and do not replace the exec path with typing the command into an interactive shell.
