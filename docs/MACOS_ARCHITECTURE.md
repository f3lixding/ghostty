# macOS Architecture: Swift-Zig Integration

This document explains how Ghostty's macOS app integrates the Swift UI layer with the Zig terminal core.

## Architecture Overview

Ghostty on macOS runs as a **single process** with two main components:

```
┌─────────────────────────────────────┐
│   Single Process (Ghostty.app)      │
├─────────────────────────────────────┤
│  Swift/SwiftUI Layer (UI)           │
│  - Window management                │
│  - Native macOS UI                  │
│  - Event handling                   │
│         ↕ C FFI                     │
│  Zig/libghostty (Core Logic)        │
│  - Terminal emulation               │
│  - VT parsing                       │
│  - PTY management                   │
│  - Font rendering                   │
│  - Metal shader execution           │
└─────────────────────────────────────┘
```

**Key Point**: This is NOT an IPC architecture. Swift and Zig share the same address space and communicate via direct function calls through C FFI.

## Startup Flow

### 1. Entry Point: `main.swift`

**File**: `macos/Sources/App/macOS/main.swift`

```swift
// Initialize Zig global state
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    exit(1)
}

// Check for CLI actions (e.g., `ghostty +help`)
ghostty_cli_try_action();

// Start the macOS app (never returns)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

**What happens**:
1. Calls Zig's `ghostty_init()` to initialize global state
2. Checks if user ran a CLI command (like `ghostty +list-fonts`)
3. Starts the macOS application event loop

### 2. Zig Initialization: `ghostty_init()`

**File**: `src/main_c.zig` (line 105)

```zig
pub export fn ghostty_init(argc: usize, argv: [*][*:0]u8) c_int {
    state.init() catch return GHOSTTY_ERROR;
    return GHOSTTY_SUCCESS;
}
```

**What it does**:
- Initializes global allocator
- Sets up resource limits (increases max file descriptors)
- Initializes crash reporting
- Prepares font libraries (FreeType, HarfBuzz)

### 3. NSApplicationMain Magic

`NSApplicationMain()` is Apple's app bootstrap function. It:

1. **Loads `MainMenu.xib`** - Interface Builder file that defines the app structure
2. **Finds the delegate class** - XIB specifies `AppDelegate` as the app delegate
3. **Instantiates AppDelegate** - Creates an instance by calling `AppDelegate.init()`
4. **Sets up the connection** - Sets `NSApp.delegate = appDelegateInstance`
5. **Calls lifecycle methods** - Triggers `applicationDidFinishLaunching`, etc.
6. **Runs event loop** - Processes events forever until app quits

**File**: `macos/Sources/App/macOS/MainMenu.xib` (lines 7-13)

```xml
<customObject id="-2" customClass="NSApplication">
    <connections>
        <outlet property="delegate" destination="bbz-4X-AYv"/>
    </connections>
</customObject>

<customObject id="bbz-4X-AYv" 
              customClass="AppDelegate"
              customModule="Ghostty">
```

This XIB configuration tells the system: "Create an `AppDelegate` instance and set it as `NSApplication`'s delegate."

### 4. AppDelegate Initialization

**File**: `macos/Sources/App/macOS/AppDelegate.swift` (line ~160)

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    let ghostty: Ghostty.App
    
    override init() {
        // Create the Ghostty.App wrapper
        ghostty = Ghostty.App()
        super.init()
        ghostty.delegate = self
    }
}
```

**Swift syntax note**: `Ghostty.App()` automatically calls `init()`. These are equivalent:
```swift
Ghostty.App()           // Shorthand (common)
Ghostty.App.init()      // Explicit (rarely written)
```

### 5. Ghostty.App Initialization

**File**: `macos/Sources/Ghostty/Ghostty.App.swift` (lines 48-100)

```swift
extension Ghostty {
    class App: ObservableObject {
        @Published var app: ghostty_app_t? = nil
        
        init(configPath: String? = nil) {
            // 1. Load Ghostty configuration
            self.config = Config(at: configPath)
            
            // 2. Set up callbacks for Zig → Swift communication
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in 
                    App.action(app!, target: target, action: action) 
                },
                read_clipboard_cb: { userdata, loc, state in 
                    App.readClipboard(userdata, location: loc, state: state) 
                },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, 
                                      content: content, len: len, confirm: confirm) 
                },
                close_surface_cb: { userdata, processAlive in 
                    App.closeSurface(userdata, processAlive: processAlive) 
                }
            )
            
            // 3. Create the Zig app instance via FFI
            guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
                readiness = .error
                return
            }
            self.app = app
            
            // 4. Set initial focus state
            ghostty_app_set_focus(app, NSApp.isActive)
            
            self.readiness = .ready
        }
    }
}
```

**Key concepts**:
- `ghostty_app_t` - Opaque pointer to Zig's app structure
- `runtime_cfg` - Callback functions Zig can call to interact with Swift
- `userdata` - Pointer to Swift's `App` instance, passed back in callbacks

### 6. Zig App Creation

**File**: `src/apprt/embedded.zig` (line 1373)

```zig
export fn ghostty_app_new(
    runtime_cfg: *const ghostty_runtime_config_s,
    config: ghostty_config_t,
) callconv(.C) ?*App {
    const app = App.create(alloc, runtime_cfg, config) catch |err| {
        log.err("failed to create app err={}", .{err});
        return null;
    };
    return app;
}
```

**What it creates**:
- Terminal state management
- PTY (pseudo-terminal) handling
- Font rendering system
- Renderer thread (Metal on macOS)
- Input handling

## Communication Patterns

### Swift → Zig (Direct FFI Calls)

Swift calls Zig functions directly through C FFI:

```swift
// File: macos/Sources/Ghostty/Ghostty.App.swift
func appTick() {
    guard let app = self.app else { return }
    ghostty_app_tick(app)  // Direct call to Zig
}
```

Common FFI calls:
- `ghostty_app_new()` - Create app instance
- `ghostty_app_tick()` - Update loop (called every frame)
- `ghostty_app_set_focus()` - Notify focus changes
- `ghostty_surface_new()` - Create a new terminal surface
- `ghostty_surface_write()` - Send input to terminal

### Zig → Swift (Callbacks)

Zig calls back to Swift through function pointers provided in `runtime_cfg`:

**Example: Wakeup callback**

When Zig needs to wake the main thread:

```zig
// File: src/apprt/embedded.zig
fn wakeup(self: *App) void {
    if (self.rt_config.wakeup_cb) |cb| {
        cb(self.rt_config.userdata);  // Calls Swift's wakeup function
    }
}
```

Swift receives the callback:

```swift
// File: macos/Sources/Ghostty/Ghostty.App.swift
static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata = userdata else { return }
    let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
    
    DispatchQueue.main.async {
        app.appTick()  // Update on main thread
    }
}
```

**Callback types**:
- `wakeup_cb` - Wake main thread for updates
- `action_cb` - Perform UI actions (new window, split, etc.)
- `read_clipboard_cb` - Read from clipboard
- `write_clipboard_cb` - Write to clipboard
- `close_surface_cb` - Close a terminal surface

## Key Components

### Terminal Surface

A "surface" is a single terminal instance (one tab or split pane).

**Creation flow**:
1. User action (new tab, split) → Swift UI
2. Swift calls `ghostty_surface_new(app, config)`
3. Zig creates terminal state, PTY, renderer
4. Returns surface pointer to Swift
5. Swift wraps it in `SurfaceView` (SwiftUI view)

**File**: `macos/Sources/Ghostty/Surface View/SurfaceView.swift`

### Rendering

Ghostty uses Metal (Apple's GPU API) for rendering:

1. **Zig side**: Prepares rendering commands, manages font atlas
2. **Swift side**: Provides Metal context (MTLDevice, MTLCommandQueue)
3. **Zig side**: Executes Metal shaders, draws to texture
4. **Swift side**: Displays the texture in SwiftUI view

**File**: `src/renderer/Metal.zig` - Metal renderer implementation

### Input Handling

1. User types in terminal → macOS sends key event
2. Swift's `SurfaceView` receives event
3. Swift calls `ghostty_surface_key_event(surface, key)`
4. Zig encodes key to terminal sequence (e.g., `\x1b[A` for up arrow)
5. Zig writes to PTY
6. Shell receives input

**File**: `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`

## Build Process

### Zig Build

**File**: `build.zig`

```zig
// Build libghostty as a static library
const lib = b.addStaticLibrary(.{
    .name = "ghostty",
    .root_source_file = .{ .path = "src/main_c.zig" },
    .target = target,
    .optimize = optimize,
});
```

This produces `libghostty.a` that Swift links against.

### Xcode Build

**File**: `macos/Ghostty.xcodeproj`

The Xcode project:
1. Runs `zig build` to create `libghostty.a`
2. Compiles Swift code
3. Links Swift code with `libghostty.a`
4. Packages into `Ghostty.app`

**Build command**: `zig build` (automatically builds macOS app)

## Platform Conditionals

Since Ghostty supports both macOS and iOS, the code uses platform checks:

```swift
#if os(macOS)
    // macOS-specific code
    ghostty_app_set_focus(app, NSApp.isActive)
    NSWindow, NSViewController, etc.
#elseif os(iOS)
    // iOS-specific code
    UIApplication, UIViewController, etc.
#endif
```

**Files with platform conditionals**:
- `macos/Sources/Ghostty/Ghostty.App.swift`
- `macos/Sources/Ghostty/Surface View/SurfaceView.swift`

## Debugging

### Enable Logging

```bash
# Set environment variable
export GHOSTTY_LOG=stderr

# Run from command line
zig build run
```

### Xcode Debugging

1. Open `macos/Ghostty.xcodeproj` in Xcode
2. Set breakpoints in Swift code
3. Run with Cmd+R
4. For Zig debugging, use `lldb` with debug symbols

### Common Issues

**Problem**: Changes to Zig code not reflected
- **Solution**: Run `zig build` to rebuild `libghostty.a`

**Problem**: Xcode can't find `libghostty.a`
- **Solution**: Ensure `zig build` completed successfully

**Problem**: Crash in FFI boundary
- **Solution**: Check pointer validity, ensure proper memory management

## Memory Management

### Swift Side

Swift uses ARC (Automatic Reference Counting):
```swift
let app = Ghostty.App()  // Retained
// ... use app ...
// Automatically released when no longer referenced
```

### Zig Side

Zig uses manual memory management:
```zig
const app = try App.create(alloc, ...);  // Allocated
defer app.destroy();  // Must manually free
```

### FFI Boundary

**Rule**: Whoever allocates, deallocates.

```swift
// Swift allocates, Swift frees
let config = Config()

// Zig allocates, Zig frees (via ghostty_app_free)
let app = ghostty_app_new(...)
ghostty_app_free(app)
```

## Threading Model

### Main Thread (Swift)

- UI updates
- Event handling
- Calls to Zig FFI functions

### Renderer Thread (Zig)

- Metal rendering
- Font rasterization
- Shader execution

### IO Thread (Zig)

- PTY reading/writing
- Process management

**Synchronization**: Zig uses callbacks to marshal work back to Swift's main thread via `wakeup_cb`.

## Further Reading

- **HACKING.md** - Development setup
- **READING_LIST.md** - Codebase study guide
- **src/apprt/embedded.zig** - Embedded runtime implementation
- **macos/Sources/Ghostty/** - Swift wrapper code
- **src/renderer/Metal.zig** - Metal renderer

## Glossary

- **FFI** - Foreign Function Interface (calling between languages)
- **PTY** - Pseudo-terminal (virtual terminal device)
- **Surface** - A single terminal instance (tab or split)
- **Runtime** - The application environment (embedded, GTK, etc.)
- **Delegate** - Design pattern where one object handles events for another
- **NS prefix** - NeXTSTEP (legacy naming for Apple's Cocoa classes)
- **XIB** - XML Interface Builder file (defines UI structure)

---

**Last Updated**: 2026-02-14
**Applies to**: macOS app architecture
