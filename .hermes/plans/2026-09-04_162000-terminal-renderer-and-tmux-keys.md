# SSH Terminal Renderer and tmux Keys Implementation Plan

**Goal:** Replace the plain `UITextView` terminal with Blink's ANSI/VT-compatible renderer while preserving the SSH-only transport boundary, then add reliable tmux prefix shortcuts.

**Architecture:** Reuse `TermView` and `TermDevice` as rendering/input components only. Do not reuse `TermController`, `MCPSession`, `ios_system`, snippets, or any local-command transport. Add a narrow adapter that converts `TermView` input and resize callbacks into `DirectSSHSession` byte writes and PTY resize requests.

**Decisions:**
- `TermView` handles escape sequences, cursor movement, alternate screen, colours, and scrollback; `UITextView` is removed.
- Terminal bytes remain opaque after they leave `DirectSSHSession`; do not decode/reformat SSH output in Swift.
- `TermDevice.rawMode = true` so Ctrl-B, Ctrl-C, Ctrl-D and all tmux input are forwarded as bytes, never interpreted as local-shell controls.
- tmux controls are UI shortcuts which emit literal bytes: Ctrl-B (`0x02`) followed by `c`, `p`, `n`, or `d`. They are not local commands.
- Initial scope is one SSH interactive PTY per view. No local shell, no general command runner, and no nested ProxyJump changes.

---

## Task 1: Prove the renderer can be isolated from the old session stack

**Files:**
- Inspect: `Blink/TermView.h`, `Blink/TermView.m`, `Blink/TermDevice.h`, `Blink/TermDevice.m`
- Inspect: `Blink/TermController.swift`
- Modify: `BlinkSSH.xcodeproj/project.pbxproj`

1. Add only the Objective-C files and resources transitively required by `TermView`/`TermDevice` to the `BlinkSSH` target.
2. Do not add `TermController.swift`, `MCPSession`, `ios_system`, Mosh, snippets, File Provider, or command targets.
3. Build Debug for simulator and iPhone.
4. Launch the app and instantiate the renderer with no SSH connection; verify its ready callback fires and no old Blink storage/App Group path is accessed.

**Done when:** A blank `TermView` renders inside the minimal target without importing the old transport stack.

## Task 2: Add a terminal-to-SSH adapter

**Files:**
- Create: `SSHOnly/SSHTerminalAdapter.swift`
- Modify: `SSHOnly/TerminalViewController.swift`
- Modify: `BlinkSSH.xcodeproj/project.pbxproj`

1. Define one adapter owning `TermDevice` and `TermView`, implementing `TermDeviceDelegate`.
2. Set `rawMode = true` before attaching the view.
3. Route the renderer's `sendString`/raw keyboard callback directly to `DirectSSHSession.send` as UTF-8 bytes.
4. Route terminal output from `DirectSSHSession.receiveOutput` to the renderer's byte-safe `write`/`writeB64` API on its required queue.
5. Start SSH only after the terminal renderer reports ready; preserve the existing host-key alert flow.
6. Keep connection-state diagnostics outside the remote byte stream or render them through a distinct local status overlay, so they cannot corrupt ANSI output.

**Tests:**
- Add a focused adapter test seam for byte forwarding: input `"\u{0002}c"` must reach the session unchanged.
- Manually verify a remote `ls --color`, `top`/`htop` alternative-screen session, and cursor movement show no literal escape sequences.

## Task 3: Wire real PTY dimensions and resize

**Files:**
- Modify: `SSHOnly/DirectSSHSession.swift`
- Modify: `SSHOnly/TerminalViewController.swift`
- Modify: `SSHOnly/SSHTerminalAdapter.swift`

1. Change the initial PTY request from hard-coded `24 × 80` to dimensions supplied by `TermDevice` after renderer readiness.
2. Add `DirectSSHSession.resize(rows:columns:)` that invokes `SSH.Stream.resizePty(rows:columns:)` on the session worker run loop and reports failures through existing connection state.
3. Forward `TermDeviceDelegate.deviceSizeChanged` to that method; coalesce duplicate sizes.
4. Verify rotation, keyboard appearance, and iPad/simulator size changes update remote `stty size`.

**Done when:** Full-screen programs redraw correctly and `stty size` matches the rendered terminal.

## Task 4: Add tmux prefix controls

**Files:**
- Modify: `SSHOnly/TerminalViewController.swift` or `SSHOnly/SSHTerminalAdapter.swift`

1. Add a compact terminal accessory/control row with buttons `C`, `P`, `N`, and `D` labelled `tmux` in accessibility text.
2. Each button emits exactly two writes, or one combined byte payload: Ctrl-B then lowercase command byte.
3. Add a separate `Ctrl` key only if the renderer does not provide one reliably; do not invent a general macro system.
4. Confirm the controls work when focus is in a full-screen remote program and do not steal focus from the renderer.

**Tests:**
- Unit-test byte sequences:
  - Create window: `[0x02, 0x63]`
  - Previous: `[0x02, 0x70]`
  - Next: `[0x02, 0x6e]`
  - Detach: `[0x02, 0x64]`
- Manual test against the existing tmux-enabled SSH account.

## Task 5: Remove the temporary text terminal and verify end-to-end

**Files:**
- Modify: `SSHOnly/TerminalViewController.swift`
- Remove only obsolete `UITextView`/`UITextField` wiring after the renderer works.

1. Remove `Terminal ready`, `Terminal visible`, and other temporary ProxyJump diagnostics from the terminal byte area.
2. Retain explicit host-key trust UI and a visible disconnected/failed state outside the emulated terminal.
3. Run `ProfileStoreTests`.
4. Build Debug simulator and signed Debug iPhone app.
5. Verify direct SSH and alias-based ProxyJump on physical iPhone, then verify ANSI colour, alternate screen, resize, and tmux shortcuts.
6. Run `git diff --check`; commit source/tests/project changes only. Do not commit `TestIdentity`, generated frameworks, headers, or DerivedData.

## Risks and controls

- `TermView` may bring hidden dependencies from old Blink. Treat every added source/resource as suspect; stop if it requires a local command/session component.
- ANSI output can be binary or split across callbacks. Preserve bytes rather than converting chunks to `String` in `DirectSSHSession`.
- Do not reuse `TermDevice` cooked mode: it intercepts Ctrl-C/Ctrl-D for local behavior, which violates remote-terminal semantics.
- The current Debug identity packaging remains Debug-only and must remain absent from Release artifacts.
