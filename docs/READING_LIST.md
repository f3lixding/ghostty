# Ghostty Codebase Study Plan

A structured guide to understanding the Ghostty terminal emulator codebase.
This plan is designed to help you progressively build knowledge from
foundational concepts to advanced features.

## Prerequisites

- Basic understanding of terminal emulators
- Familiarity with Zig programming language
- Understanding of VT/ANSI escape sequences
- Basic knowledge of graphics rendering (OpenGL/Metal)

## Phase 1: Project Overview & Architecture (Week 1)

### Essential Reading
1. **README.md** - Project goals and philosophy
2. **HACKING.md** - Development setup and workflow
3. **CONTRIBUTING.md** - Contribution guidelines
4. **AGENTS.md** - Agent development guide

### Core Architecture Documents
- `src/main_ghostty.zig` - Main entry point for the application
- `src/main_c.zig` - C API entry point for libghostty
- `src/App.zig` - Application-level state management
- `src/build_config.zig` - Build configuration and feature flags

### Key Concepts to Understand
- Multi-platform architecture (macOS, Linux, Windows)
- Separation between core terminal logic and platform-specific UI
- The libghostty library concept

## Phase 2: Terminal Core (Week 2-3)

### Terminal State Management Start with these files in order:

1. **`src/terminal/main.zig`** - Terminal module overview
2. **`src/terminal/Terminal.zig`** (412KB!) - Core terminal state
   - Focus on: Colors, Dirty tracking, MouseEvents
   - This is the heart of the terminal - take your time here
3. **`src/terminal/Screen.zig`** (352KB) - Screen buffer management
   - Understand: Cursor, Dirty tracking, SemanticPrompt
4. **`src/terminal/PageList.zig`** (481KB) - Scrollback buffer
   - Key concept: Linked list of pages for terminal history

### Terminal Parsing & Processing
5. **`src/terminal/Parser.zig`** - VT sequence parser
6. **`src/terminal/stream.zig`** - Terminal input stream processing
7. **`src/terminal/formatter.zig`** (197KB) - Output formatting

### Control Sequences
8. **`src/terminal/ansi.zig`** - ANSI escape sequences
9. **`src/terminal/csi.zig`** - CSI (Control Sequence Introducer)
10. **`src/terminal/osc.zig`** - OSC (Operating System Command)
11. **`src/terminal/dcs.zig`** - DCS (Device Control String)
12. **`src/terminal/apc.zig`** - APC (Application Program Command)

### Supporting Structures
- `src/terminal/style.zig` - Text styling (bold, italic, colors)
- `src/terminal/color.zig` - Color management
- `src/terminal/Selection.zig` - Text selection
- `src/terminal/modes.zig` - Terminal modes (application mode, etc.)

## Phase 3: Terminal I/O (Week 4)

### PTY Management
1. **`src/pty.zig`** - PTY abstraction layer
2. **`src/termio/Termio.zig`** - Terminal I/O coordination
3. **`src/termio/Exec.zig`** - Process execution
4. **`src/termio/Thread.zig`** - I/O threading
5. **`src/termio/stream_handler.zig`** - Stream handling logic

### Shell Integration
- `src/termio/shell_integration.zig` - Shell integration features
- `src/shell-integration/` - Shell-specific integration scripts

## Phase 4: Rendering Stack (Week 5-6)

### Rendering Architecture
1. **`src/Surface.zig`** (242KB) - Surface abstraction (terminal widget)
2. **`src/renderer/generic.zig`** (141KB) - Generic renderer implementation
3. **`src/renderer/Thread.zig`** - Rendering thread management

### Graphics Backends
4. **`src/renderer/Metal.zig`** - macOS Metal renderer
5. **`src/renderer/OpenGL.zig`** - Linux OpenGL renderer
6. **`src/renderer/metal/` directory** - Metal-specific code
7. **`src/renderer/opengl/` directory** - OpenGL-specific code

### Rendering Components
- `src/renderer/cell.zig` - Cell rendering
- `src/renderer/cursor.zig` - Cursor rendering
- `src/renderer/image.zig` - Image protocol support
- `src/renderer/link.zig` - Hyperlink rendering
- `src/renderer/shaders/` - Shader code

## Phase 5: Font System (Week 7)

### Font Management
1. **`src/font/main.zig`** - Font subsystem overview
2. **`src/font/Collection.zig`** - Font collection management
3. **`src/font/SharedGrid.zig`** - Shared font grid state
4. **`src/font/SharedGridSet.zig`** - Multiple grid management
5. **`src/font/Atlas.zig`** - Texture atlas for glyphs

### Font Rendering
- `src/font/face.zig` - Font face abstraction
- `src/font/discovery.zig` - Font discovery on system
- `src/font/shaper/` - Text shaping (HarfBuzz integration)
- `src/font/sprite/` - Built-in sprite fonts (box drawing, etc.)

### Special Glyphs
- `src/font/sprite/draw/box.zig` - Box drawing characters
- `src/font/sprite/draw/braille.zig` - Braille patterns
- `src/font/sprite/draw/powerline.zig` - Powerline symbols

## Phase 6: Input Handling (Week 8)

### Input Processing
1. **`src/input/Binding.zig`** (164KB) - Key binding system
2. **`src/input/key.zig`** - Key representation
3. **`src/input/key_encode.zig`** - Key encoding for terminal
4. **`src/input/key_mods.zig`** - Keyboard modifiers

### Input Features
- `src/input/mouse.zig` - Mouse input handling
- `src/input/paste.zig` - Paste handling
- `src/input/command.zig` - Command execution
- `src/surface_mouse.zig` - Surface-level mouse handling

## Phase 7: Configuration System (Week 9)

### Configuration
1. **`src/config/Config.zig`** (394KB) - Main configuration structure
2. **`src/config/io.zig`** - Configuration I/O
3. **`src/config/theme.zig`** - Theme management
4. **`src/config/conditional.zig`** - Conditional configuration

### Configuration Features
- `src/config/path.zig` - Path handling
- `src/config/command.zig` - Command configuration
- `src/config/url.zig` - URL handling

## Phase 8: Platform Integration (Week 10-11)

### Application Runtime (apprt)
1. **`src/apprt.zig`** - Runtime abstraction overview
2. **`src/apprt/action.zig`** - Application actions
3. **`src/apprt/surface.zig`** - Surface interface

### macOS Integration
- `macos/Sources/Ghostty/` - SwiftUI application
- `src/apprt/embedded.zig` - Embedded runtime for macOS

### Linux/GTK Integration
- `src/apprt/gtk/` - GTK4 implementation
- `src/apprt/gtk/class/` - GTK widget classes

### OS Utilities
- `src/os/` - OS-specific utilities
- `src/os/xdg.zig` - XDG base directory support
- `src/os/macos.zig` - macOS-specific utilities

## Phase 9: Advanced Features (Week 12)

### Kitty Graphics Protocol
- `src/terminal/kitty/graphics.zig` - Kitty graphics protocol
- `src/terminal/kitty/` - Other Kitty protocol features

### Sixel Support
- `src/terminal/kitty/sixel.zig` - Sixel image format

### Search
- `src/terminal/search/` - Terminal search functionality
- `src/terminal/search/Thread.zig` - Search threading

### Tmux Integration
- `src/terminal/tmux/` - Tmux control mode support

## Phase 10: Data Structures & Utilities (Week 13)

### Core Data Structures
- `src/datastruct/` - Custom data structures
- `src/datastruct/split_tree.zig` - Split tree for panes
- `src/datastruct/lru.zig` - LRU cache
- `src/datastruct/blocking_queue.zig` - Thread-safe queue

### Unicode Support
- `src/unicode/` - Unicode utilities
- `src/unicode/grapheme.zig` - Grapheme cluster handling
- `src/unicode/props.zig` - Unicode properties

### SIMD Optimizations
- `src/simd/` - SIMD-optimized operations
- `src/simd/vt.zig` - VT parsing optimizations
- `src/simd/base64.zig` - Base64 encoding/decoding

## Phase 11: Testing & Debugging (Week 14)

### Testing Infrastructure
- `test/` - Test cases and utilities
- `src/benchmark/` - Performance benchmarks
- `src/inspector/` - Debug inspector (ImGui-based)

### CLI Tools
- `src/cli/` - Command-line interface
- `src/cli/diagnostics.zig` - Diagnostic tools
- `src/cli/list_fonts.zig` - Font listing
- `src/cli/show_config.zig` - Configuration display

### Crash Reporting
- `src/crash/` - Crash reporting system
- `src/crash/sentry.zig` - Sentry integration

## Phase 12: Build System & Packaging (Week 15)

### Build System
- `build.zig` - Main build script
- `build.zig.zon` - Zig package dependencies
- `src/build/` - Build utilities

### Packaging
- `pkg/` - Third-party package integrations
- `nix/` - Nix packaging
- `flatpak/` - Flatpak packaging
- `snap/` - Snap packaging

## Study Tips

### Reading Strategy
1. **Start with comments**: Many files have extensive `//!` doc comments at the
top
2. **Follow the data flow**: Trace how data moves from input → terminal →
renderer
3. **Use grep**: Search for specific features or functions you're interested in
4. **Build incrementally**: Try building and running after each phase
5. **Read tests**: Test files often show how components are used

### Key Files to Bookmark
- `src/terminal/Terminal.zig` - Core terminal state
- `src/Surface.zig` - Surface/widget abstraction
- `src/renderer/generic.zig` - Rendering logic
- `src/font/SharedGrid.zig` - Font rendering state
- `src/config/Config.zig` - Configuration options

### Debugging Techniques
1. Enable debug logging: `GHOSTTY_LOG=stderr zig build run`
2. Use the inspector: Build with `-Dinspector` flag
3. Run tests: `zig build test -Dtest-filter=<name>`
4. Check memory: `zig build run-valgrind` (Linux)

## Common Patterns in the Codebase

### Zig Patterns
- **Comptime configuration**: Heavy use of comptime for platform-specific code
- **Error handling**: Extensive use of error unions and `errdefer`
- **Memory management**: Manual memory management with allocators
- **C interop**: FFI with C libraries (FreeType, HarfBuzz, etc.)

### Architecture Patterns
- **Message passing**: Mailbox pattern for thread communication
- **Dirty tracking**: Efficient rendering through dirty flags
- **Pooling**: Object pools for performance (pages, cells, etc.)
- **Layered abstraction**: Platform-agnostic core with platform-specific shells

## Resources

### External Documentation
- [VT100 Escape Sequences](https://vt100.net/docs/vt100-ug/)
- [ECMA-48
  Standard](https://ecma-international.org/publications-and-standards/standards/ecma-48/)
- [Kitty Graphics Protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
- [Zig Language Reference](https://ziglang.org/documentation/master/)

### Related Projects
- [xterm.js](https://github.com/xtermjs/xterm.js) - Terminal emulator in
  TypeScript
- [Alacritty](https://github.com/alacritty/alacritty) - GPU-accelerated
  terminal in Rust
- [Kitty](https://github.com/kovidgoyal/kitty) - Feature-rich terminal in
  Python/C

## Progress Tracking

Create a checklist as you work through each phase:

- [ ] Phase 1: Project Overview
- [ ] Phase 2: Terminal Core
- [ ] Phase 3: Terminal I/O
- [ ] Phase 4: Rendering Stack
- [ ] Phase 5: Font System
- [ ] Phase 6: Input Handling
- [ ] Phase 7: Configuration
- [ ] Phase 8: Platform Integration
- [ ] Phase 9: Advanced Features
- [ ] Phase 10: Data Structures
- [ ] Phase 11: Testing & Debugging
- [ ] Phase 12: Build System

## Next Steps After Completion

Once you've completed this study plan:

1. **Pick a feature to implement**: Start with something small
2. **Fix a bug**: Look at GitHub issues tagged "good first issue"
3. **Write documentation**: Help others understand what you've learned
4. **Optimize performance**: Profile and improve hot paths
5. **Add platform support**: Help with Windows or other platforms

## Notes

- File sizes mentioned are approximate and may change
- Focus on understanding concepts rather than memorizing code
- Don't hesitate to skip sections that aren't relevant to your goals
- The codebase is actively developed - some details may change

---

**Last Updated**: 2026-02-12 **Codebase Version**: Main branch (tip)
