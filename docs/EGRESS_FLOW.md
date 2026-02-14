# Egress Flow: PTY Output → Display

This document traces the complete flow of data from when a program writes to
the PTY (e.g., a chat app outputting text) to when it appears on screen in the
macOS app.

## Overview

The egress flow is **push-based**, not poll-based. When data arrives from the
PTY, Zig actively notifies Swift through callbacks, triggering a render cycle.

```
PTY Output
  ↓
Read Thread (Zig)
  ↓
Terminal Processing (Zig)
  ↓
Renderer Wakeup (Zig)
  ↓
Render Frame (Zig)
  ↓
App Mailbox Push (Zig)
  ↓
Wakeup Callback (Zig → Swift)
  ↓
Main Thread (Swift)
  ↓
Display (macOS)
```

## Detailed Flow with Actual Code

### 1. Read Thread Reads from PTY

**File**: `src/termio/Exec.zig` (lines 1242-1320)

The read thread runs continuously in a tight loop, blocking on `posix.read()` until data arrives from the PTY.

```zig
fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
    // Always close our end of the pipe when we exit.
    defer posix.close(quit);

    // Setup crash metadata
    crash.sentry.thread_state = .{
        .type = .io,
        .surface = io.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Set fd to non-blocking for performance
    if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
        _ = posix.fcntl(
            fd,
            posix.F.SETFL,
            flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
        ) catch |err| {
            log.warn("read thread failed to set flags err={}", .{err});
        };
    } else |err| {
        log.warn("read thread failed to get flags err={}", .{err});
    }

    // Build up the list of fds we're going to poll
    var pollfds: [2]posix.pollfd = .{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
        .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
    };

    var buf: [1024]u8 = undefined;
    while (true) {
        // Try to read as much as possible in a tight loop
        while (true) {
            const n = posix.read(fd, &buf) catch |err| {
                switch (err) {
                    error.NotOpenForReading,
                    error.InputOutput,
                    => {
                        log.info("io reader exiting", .{});
                        return;
                    },
                    
                    // No more data, fall back to poll
                    error.WouldBlock => break,
                    
                    else => {
                        log.err("io reader error err={}", .{err});
                        unreachable;
                    },
                }
            };

            // n == 0 means child process died on macOS
            if (n == 0) break;

            // Process the data immediately (inline for performance)
            @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
        }

        // Wait for more data
        _ = posix.poll(&pollfds, -1) catch |err| {
            log.warn("poll failed on read thread, exiting early err={}", .{err});
            return;
        };

        // Check if we should quit
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            log.info("read thread got quit signal", .{});
            return;
        }

        // Check if PTY is closed
        if (pollfds[0].revents & posix.POLL.HUP != 0) {
            log.info("pty fd closed, read thread exiting", .{});
            return;
        }
    }
}
```

**Key Points**:
- Runs in a dedicated thread named "io-reader"
- Uses non-blocking I/O with `poll()` for efficiency
- Reads in 1KB chunks
- Calls `processOutput()` inline for performance

**What actually calls `threadMainPosix`**:

**File**: `src/termio/Exec.zig` (lines 138-142)

```zig
// Start our read thread
const read_thread = try std.Thread.spawn(
    .{},
    if (builtin.os.tag == .windows) ReadThread.threadMainWindows else ReadThread.threadMainPosix,
    .{ pty_fds.read, io, pipe[0] },
);
read_thread.setName("io-reader") catch {};
```

This `read_thread` is then joined from within the function this is called. 

If you trace far back up enough, this is called from the following (which is a
c calling conv FFI that is called from swift):
Note that this is the code path for MacOS. The linux bin has a different code path. 

**File**: `src/apprt/embedded.zig` (line 1516)

```zig
/// Create a new surface as part of an app.
export fn ghostty_surface_new(
    app: *App,
    opts: *const apprt.Surface.Options,
) ?*Surface {
    return surface_new_(app, opts) catch |err| {
        log.err("error initializing surface err={}", .{err});
        return null;
    };
}
```

MacOS call chain (Embedded):
```
Swift UI Event (Cmd+T)
  ↓
ghostty_surface_new() [C FFI]
  ↓
CoreSurface.init()
  ↓
Termio.init()
  ↓
Exec.threadEnter()
  ↓
subprocess.start() → PTY created
  ↓
std.Thread.spawn(threadMainPosix)
```


Linux call chain (GTK):
```
GTK Widget Created (GhosttySurface)
  ↓
GTK realizes widget (shows on screen)
  ↓
GTK calls glareaResize() [first resize event]
  ↓
initSurface()
  ↓
CoreSurface.init()
  ↓
Termio.init()
  ↓
Exec.threadEnter()
  ↓
subprocess.start() → PTY created
  ↓
std.Thread.spawn(threadMainPosix)
```


### 2. Process Output and Queue Render

**File**: `src/termio/Termio.zig` (lines 658-672)

```zig
/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) void {
    // We are modifying terminal state from here on out and we need
    // the lock to grab our read data.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.processOutputLocked(buf);
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(self: *Termio, buf: []const u8) void {
    // Schedule a render. We can call this first because we have the lock.
    self.terminal_stream.handler.queueRender() catch unreachable;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    if (std.time.Instant.now()) |now| cursor_reset: {
        if (self.last_cursor_reset) |last| {
            if (now.since(last) <= (500 * std.time.ns_per_ms)) {
                break :cursor_reset;
            }
        }

        self.last_cursor_reset = now;
        _ = self.renderer_mailbox.push(.{
            .reset_cursor_blink = {},
        }, .{ .instant = {} });
    } else |err| {
        log.warn("failed to get current time err={}", .{err});
    }

    // ... parse VT sequences and update terminal state ...
}
```

**Key Points**:
- Acquires renderer state mutex for thread safety
- Queues a render **before** processing bytes (optimization)
- Throttles cursor blink resets to avoid spam under heavy load
- Parses VT sequences and updates terminal state

### 3. Queue Render Wakes Renderer

**File**: `src/termio/stream_handler.zig` (lines 104-106)

```zig
/// This queues a render operation with the renderer thread. The render
/// isn't guaranteed to happen immediately but it will happen as soon as
/// practical.
pub inline fn queueRender(self: *StreamHandler) !void {
    try self.renderer_wakeup.notify();
}
```

**Key Points**:
- `renderer_wakeup` is an `xev.Async` handle
- `notify()` wakes the renderer thread's event loop
- Inlined for performance

### 4. Renderer Wakeup Callback

**File**: `src/renderer/Thread.zig` (lines 515-545)

```zig
fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    const t = self_.?;

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});

    // Render immediately
    _ = renderCallback(t, undefined, undefined, {});

    // The below is not used anymore but if we ever want to introduce
    // a configuration to introduce a delay to coalesce renders, we can
    // use this.
    //
    // // If the timer is already active then we don't have to do anything.
    // if (t.render_c.state() == .active) return .rearm;
    //
    // // Timer is not active, let's start it
    // t.render_h.run(
    //     &t.loop,
    //     &t.render_c,
    //     10,
    //     Thread,
    //     t,
    //     renderCallback,
    // );

    return .rearm;
}
```

**Key Points**:
- Called by the renderer thread's event loop when woken
- Drains the mailbox for any pending messages
- Calls `renderCallback()` immediately (no delay)
- Returns `.rearm` to keep the callback active

### 5. Render Callback Updates Frame

**File**: `src/renderer/Thread.zig` (lines 598-622)

```zig
fn renderCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    // Update our frame data
    t.renderer.updateFrame(
        t.state,
        t.flags.cursor_blink_visible,
    ) catch |err|
        log.warn("error rendering err={}", .{err});

    // Draw
    t.drawFrame(false);

    return .disarm;
}
```

**Key Points**:
- `updateFrame()` prepares rendering data (cell positions, colors, etc.)
- `drawFrame()` triggers the actual draw
- Runs on the renderer thread

### 6. Draw Frame Pushes to App Mailbox

**File**: `src/renderer/Thread.zig` (lines 490-512)

```zig
/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) void {
    // If we're invisible, we do not draw.
    if (!self.flags.visible) return;

    // If the renderer is managing a vsync on its own, we only draw
    // when we're forced to via `now`.
    if (!now and self.renderer.hasVsync()) return;

    if (must_draw_from_app_thread) {
        _ = self.app_mailbox.push(
            .{ .redraw_surface = self.surface },
            .{ .instant = {} },
        );
    } else {
        self.renderer.drawFrame(false) catch |err|
            log.warn("error drawing err={}", .{err});
    }
}
```

**Key Points**:
- Checks if surface is visible (optimization)
- On macOS, `must_draw_from_app_thread` is true
- Pushes a message to the app mailbox
- The push triggers a wakeup (next step)

### 7. App Mailbox Push Calls Wakeup

**File**: `src/App.zig` (lines 577-584)

```zig
/// Send a message to the surface.
pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
    const result = self.mailbox.push(msg, timeout);

    // Wake up our app loop
    self.rt_app.wakeup();

    return result;
}
```

**Key Points**:
- Every message pushed to the app mailbox triggers a wakeup
- `rt_app` is the runtime app (embedded app for macOS)
- This is the bridge from Zig to Swift

### 8. Wakeup Calls Swift Callback

**File**: `src/apprt/embedded.zig` (lines 231-233)

```zig
pub fn wakeup(self: *const App) void {
    self.opts.wakeup(self.opts.userdata);
}
```

**Key Points**:
- `self.opts.wakeup` is a function pointer to Swift code
- `self.opts.userdata` is a pointer to the Swift `App` instance
- This crosses the C FFI boundary

**Where the callback is registered**:

**File**: `src/apprt/embedded.zig` (lines 28-50)

```zig
pub const App = struct {
    pub const Options = extern struct {
        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.c) void,
        
        // ... other callbacks
    };
```

### 9. Swift Receives Callback

**File**: `macos/Sources/Ghostty/Ghostty.App.swift` (line ~250)

```swift
static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata = userdata else { return }
    let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
    
    // IMPORTANT: Must switch to main thread for UI updates
    DispatchQueue.main.async {
        app.appTick()
    }
}
```

**Key Points**:
- Called from Zig's renderer thread (not main thread!)
- Must use `DispatchQueue.main.async` to switch to main thread
- Converts opaque pointer back to Swift `App` instance

### 10. Swift Calls Back to Zig on Main Thread

**File**: `macos/Sources/Ghostty/Ghostty.App.swift` (line ~240)

```swift
func appTick() {
    guard let app = self.app else { return }
    
    // Tell Zig to process any pending updates
    ghostty_app_tick(app)
}
```

### 11. Zig Processes App Tick

**File**: `src/apprt/embedded.zig` (line ~1500)

```zig
export fn ghostty_app_tick(app_: ghostty_app_t) callconv(.C) void {
    const app: *App = @ptrCast(@alignCast(app_));
    
    // Process mailbox messages
    app.drainMailbox();
    
    // This will trigger surface redraws as needed
}
```

### 12. Swift Draws the Surface

**File**: `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` (line ~800)

```swift
override func draw(_ dirtyRect: NSRect) {
    guard let surface = self.surface else { return }
    guard let drawable = metalLayer.nextDrawable() else { return }
    
    // Tell Zig to render to Metal texture
    ghostty_surface_draw(
        surface,
        drawable.texture,
        Int(bounds.width),
        Int(bounds.height)
    )
    
    // Present to screen
    drawable.present()
}
```

### 13. Zig Renders with Metal

**File**: `src/renderer/Metal.zig`

```zig
pub fn draw(self: *Renderer, texture: MTLTexture) void {
    // Create command buffer
    const commandBuffer = self.commandQueue.makeCommandBuffer();
    
    // Render cells with Metal shaders
    for (terminal.cells) |cell| {
        renderCell(cell, commandBuffer);
    }
    
    // Commit to GPU
    commandBuffer.commit();
}
```

## Threading Model

### Threads Involved

1. **IO Thread** (`io-reader`)
   - Reads from PTY
   - Parses VT sequences
   - Updates terminal state
   - Owned by: Zig

2. **Renderer Thread** (`renderer`)
   - Prepares rendering data
   - Manages Metal resources
   - Runs at ~60 FPS
   - Owned by: Zig

3. **Main Thread** (macOS main thread)
   - Handles UI updates
   - Calls draw methods
   - Owned by: Swift/macOS

### Thread Transitions

```
IO Thread (Zig)
  ↓ xev.Async.notify()
Renderer Thread (Zig)
  ↓ app_mailbox.push() → wakeup()
Main Thread (Swift)
  ↓ ghostty_app_tick()
Back to Zig (on main thread)
  ↓ ghostty_surface_draw()
Metal GPU
```

## Performance Optimizations

### 1. Inline Processing

**File**: `src/termio/Exec.zig` (line 1318)

```zig
@call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
```

Forces inlining for hot path performance.

### 2. Non-blocking I/O

The read thread uses non-blocking I/O with `poll()` to read as much data as possible in a tight loop before checking for quit signals.

### 3. Immediate Render Queue

**File**: `src/termio/Termio.zig` (line 671)

```zig
// Schedule a render. We can call this first because we have the lock.
self.terminal_stream.handler.queueRender() catch unreachable;
```

Queues render **before** processing bytes to minimize latency.

### 4. Cursor Blink Throttling

**File**: `src/termio/Termio.zig` (lines 674-686)

```zig
if (std.time.Instant.now()) |now| cursor_reset: {
    if (self.last_cursor_reset) |last| {
        if (now.since(last) <= (500 * std.time.ns_per_ms)) {
            break :cursor_reset;
        }
    }
    // ... reset cursor blink
}
```

Prevents spamming cursor resets under heavy load.

### 5. Visibility Check

**File**: `src/renderer/Thread.zig` (line 492)

```zig
// If we're invisible, we do not draw.
if (!self.flags.visible) return;
```

Skips rendering when surface is not visible.

## Message Flow Summary

```
┌─────────────────────────────────────────────────────────────┐
│ PTY writes: "Hello\n"                                       │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ IO Thread (Zig)                                             │
│ - posix.read() returns 6 bytes                              │
│ - processOutput(buf)                                        │
│ - Parse VT sequences                                        │
│ - Update terminal state                                     │
│ - queueRender()                                             │
└────────────────────┬────────────────────────────────────────┘
                     ↓ xev.Async.notify()
┌─────────────────────────────────────────────────────────────┐
│ Renderer Thread (Zig)                                       │
│ - wakeupCallback()                                          │
│ - renderCallback()                                          │
│ - updateFrame() - prepare rendering data                    │
│ - drawFrame()                                               │
│ - app_mailbox.push(.redraw_surface)                        │
└────────────────────┬────────────────────────────────────────┘
                     ↓ wakeup callback (C FFI)
┌─────────────────────────────────────────────────────────────┐
│ Swift Callback (any thread)                                 │
│ - App.wakeup(userdata)                                      │
│ - DispatchQueue.main.async { appTick() }                   │
└────────────────────┬────────────────────────────────────────┘
                     ↓ switch to main thread
┌─────────────────────────────────────────────────────────────┐
│ Main Thread (Swift)                                         │
│ - appTick()                                                 │
│ - ghostty_app_tick() (C FFI)                               │
└────────────────────┬────────────────────────────────────────┘
                     ↓ process mailbox
┌─────────────────────────────────────────────────────────────┐
│ Zig (on main thread)                                        │
│ - Process .redraw_surface message                           │
│ - Trigger NSView.setNeedsDisplay()                         │
└────────────────────┬────────────────────────────────────────┘
                     ↓ macOS calls draw
┌─────────────────────────────────────────────────────────────┐
│ Swift Draw (main thread)                                    │
│ - SurfaceView.draw()                                        │
│ - ghostty_surface_draw() (C FFI)                           │
└────────────────────┬────────────────────────────────────────┘
                     ↓ render to Metal
┌─────────────────────────────────────────────────────────────┐
│ Zig Metal Renderer (main thread)                            │
│ - Create command buffer                                     │
│ - Execute Metal shaders                                     │
│ - Render cells to texture                                   │
│ - drawable.present()                                        │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ GPU displays "Hello" on screen                              │
└─────────────────────────────────────────────────────────────┘
```

## Key Takeaways

1. **Push-based**: Zig actively notifies Swift when data arrives, not poll-based
2. **Multi-threaded**: IO thread → Renderer thread → Main thread
3. **Callback-driven**: Zig calls Swift via function pointers registered at init
4. **Thread-safe**: Uses mutexes and message queues for synchronization
5. **Optimized**: Inline calls, non-blocking I/O, throttling, visibility checks

## How PTY Output Relates to Critical Components

The egress flow touches every major component in Ghostty. Here's how PTY output flows through the architecture:

### Component Hierarchy

```
App (1 instance)
  ├─ Surface (N instances - tabs/splits)
  │   ├─ Termio (terminal I/O)
  │   │   ├─ Terminal (grid state)
  │   │   └─ Exec (PTY + subprocess)
  │   └─ Renderer Thread
  │       └─ Renderer (Metal/OpenGL)
  └─ Font Grid Set (shared fonts)
```

### 1. App (`src/App.zig`)

**Role**: Top-level application coordinator

**Relationship to PTY Output**:
- Receives `.redraw_surface` messages in its mailbox when PTY data triggers a render
- Coordinates multiple surfaces (tabs/splits)
- Manages the wakeup callback that bridges Zig → Swift

**File**: `src/App.zig` (lines 1-50)

```zig
const App = @This();

/// General purpose allocator
alloc: Allocator,

/// The list of surfaces that are currently active.
surfaces: SurfaceList,

/// The mailbox that can be used to send this thread messages.
mailbox: Mailbox.Queue,

/// The set of font GroupCache instances shared by surfaces
font_grid_set: font.SharedGridSet,
```

**Key Point**: The App doesn't directly handle PTY data. It receives notifications **after** the renderer has prepared a frame and needs the main thread to trigger a draw.

### 2. Surface (`src/Surface.zig`)

**Role**: Single terminal instance (tab or split)

**Relationship to PTY Output**:
- Owns the Termio instance that reads from PTY
- Owns the Renderer Thread that draws the terminal
- Each surface has its own PTY and subprocess

**File**: `src/Surface.zig` (lines 1-100)

```zig
//! Surface represents a single terminal "surface". A terminal surface is
//! a minimal "widget" where the terminal is drawn and responds to events
//! such as keyboard and mouse. Each surface also creates and owns its pty
//! session.

/// The app that this surface is attached to.
app: *App,

/// The windowing system surface and app.
rt_app: *apprt.runtime.App,
rt_surface: *apprt.runtime.Surface,

/// The font structures
font_grid_key: font.SharedGridSet.Key,
font_size: font.face.DesiredSize,
font_metrics: font.Metrics,

/// The renderer for this surface.
renderer: Renderer,

/// The render state
renderer_state: rendererpkg.State,

/// The renderer thread manager
renderer_thread: rendererpkg.Thread,

/// The actual thread
renderer_thr: std.Thread,
```

**Key Point**: A Surface is what you see as a "terminal window" or "tab". When you open a new tab, you create a new Surface with its own PTY.

### 3. Termio (`src/termio/Termio.zig`)

**Role**: Terminal I/O coordinator

**Relationship to PTY Output**:
- **This is where PTY data enters the system**
- Owns the Terminal state (grid of characters)
- Parses VT escape sequences
- Triggers renderer wakeups

**File**: `src/termio/Termio.zig` (lines 1-100)

```zig
//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc.

/// The implementation responsible for io (PTY, subprocess, etc.)
backend: termio.Backend,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc.
terminal: terminalpkg.Terminal,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer.
renderer_wakeup: xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// The stream parser. This parses the stream of escape codes.
terminal_stream: StreamHandler.Stream,
```

**Key Point**: Termio is the bridge between raw PTY bytes and structured terminal state. It calls `terminal.write()` to update the grid.

### 4. Terminal (`src/terminal/Terminal.zig`)

**Role**: Terminal emulation state (the grid)

**Relationship to PTY Output**:
- Stores the character grid (what you see on screen)
- Maintains cursor position, colors, modes
- Updated by VT sequence parser in Termio

**File**: `src/terminal/Terminal.zig` (lines 1-100)

```zig
//! The primary terminal emulation structure. This represents a single
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.

/// The set of screens behind this terminal (e.g. primary vs alternate).
screens: ScreenSet,

/// The size of the terminal.
rows: size.CellCountInt,
cols: size.CellCountInt,

/// The current scrolling region.
scrolling_region: ScrollingRegion,

/// The color state for this terminal.
colors: Colors,

/// The modes that this terminal currently has active.
modes: modespkg.ModeState = .{},
```

**Key Point**: This is the "model" in MVC. It's renderer-agnostic and just stores state. When PTY data arrives, this grid is updated.

### 5. Exec (`src/termio/Exec.zig`)

**Role**: PTY and subprocess management

**Relationship to PTY Output**:
- **This is the source of PTY data**
- Spawns the shell subprocess (bash, zsh, etc.)
- Creates the PTY (pseudo-terminal)
- Runs the read thread that blocks on `posix.read()`

**File**: `src/termio/Exec.zig` (lines 1-100)

```zig
//! Exec manages a subprocess execution with a pty. This is the primary
//! way that Ghostty runs shells and other programs.

/// The pty file descriptor
pty: posix.fd_t,

/// The subprocess
child: std.process.Child,

/// The read thread
read_thread: std.Thread,
```

**Key Point**: This is where `cat file.txt` or `ls` output comes from. The read thread here is the entry point for all PTY data.

### 6. Renderer Thread (`src/renderer/Thread.zig`)

**Role**: Rendering coordinator

**Relationship to PTY Output**:
- Woken up when PTY data arrives (via `xev.Async`)
- Prepares rendering data (cell positions, colors)
- Triggers app mailbox push to request main thread draw

**File**: `src/renderer/Thread.zig` (lines 1-100)

```zig
//! The renderer thread manages the rendering loop for a single surface.

/// The event loop for this thread
loop: xev.Loop,

/// The renderer implementation (Metal, OpenGL, etc.)
renderer: *Renderer,

/// The terminal state to render
state: *renderer.State,

/// The app mailbox for sending messages to the main thread
app_mailbox: *App.Mailbox,

/// The surface this renderer is for
surface: *Surface,
```

**Key Point**: This thread doesn't draw directly on macOS. It prepares data and asks the main thread to draw.

### 7. Renderer (`src/renderer/Metal.zig` or `OpenGL.zig`)

**Role**: Actual rendering implementation

**Relationship to PTY Output**:
- Receives prepared frame data from Renderer Thread
- Executes Metal/OpenGL commands to draw cells
- Runs on main thread (macOS) or renderer thread (Linux)

**File**: `src/renderer/Metal.zig` (lines 1-50)

```zig
//! Metal renderer implementation for macOS

/// Metal device
device: *MTLDevice,

/// Command queue for submitting GPU work
command_queue: *MTLCommandQueue,

/// Render pipeline state
pipeline_state: *MTLRenderPipelineState,

/// Cell buffer (vertex data)
cell_buffer: *MTLBuffer,
```

**Key Point**: This is the final step. It converts terminal grid state into GPU commands that draw pixels on screen.

### Data Flow Through Components

```
┌─────────────────────────────────────────────────────────────┐
│ Exec (PTY + subprocess)                                     │
│ - Reads raw bytes from PTY                                  │
│ - "Hello\n" arrives                                         │
└────────────────────┬────────────────────────────────────────┘
                     ↓ processOutput()
┌─────────────────────────────────────────────────────────────┐
│ Termio (I/O coordinator)                                    │
│ - Parses VT sequences                                       │
│ - Calls terminal.write()                                    │
│ - Queues render                                             │
└────────────────────┬────────────────────────────────────────┘
                     ↓ terminal.write()
┌─────────────────────────────────────────────────────────────┐
│ Terminal (grid state)                                       │
│ - Updates character grid                                    │
│ - Moves cursor                                              │
│ - Applies colors                                            │
└─────────────────────────────────────────────────────────────┘
                     ↓ queueRender()
┌─────────────────────────────────────────────────────────────┐
│ Renderer Thread                                             │
│ - Wakes up                                                  │
│ - Calls renderer.updateFrame()                             │
│ - Prepares cell positions, colors                          │
│ - Pushes to app mailbox                                    │
└────────────────────┬────────────────────────────────────────┘
                     ↓ app_mailbox.push()
┌─────────────────────────────────────────────────────────────┐
│ App (main coordinator)                                      │
│ - Receives .redraw_surface message                          │
│ - Calls wakeup() → Swift                                    │
└────────────────────┬────────────────────────────────────────┘
                     ↓ Swift callback
┌─────────────────────────────────────────────────────────────┐
│ Surface (terminal instance)                                 │
│ - Triggers NSView.setNeedsDisplay()                        │
│ - macOS calls draw()                                        │
└────────────────────┬────────────────────────────────────────┘
                     ↓ ghostty_surface_draw()
┌─────────────────────────────────────────────────────────────┐
│ Renderer (Metal/OpenGL)                                     │
│ - Executes GPU commands                                     │
│ - Draws cells to texture                                    │
│ - Presents to screen                                        │
└─────────────────────────────────────────────────────────────┘
```

### Component Ownership

```
App owns:
  ├─ Multiple Surfaces
  └─ Font Grid Set (shared)

Surface owns:
  ├─ Termio
  ├─ Renderer Thread
  └─ Renderer

Termio owns:
  ├─ Terminal (grid state)
  └─ Exec (PTY + subprocess)

Exec owns:
  ├─ PTY file descriptor
  ├─ Child process
  └─ Read thread
```

### Why This Architecture?

1. **Separation of Concerns**:
   - Terminal state (Terminal) is separate from I/O (Termio)
   - Rendering (Renderer) is separate from state
   - Each component has a single responsibility

2. **Performance**:
   - Dedicated threads for I/O and rendering
   - Main thread only handles UI events and final draw
   - Non-blocking I/O prevents UI freezes

3. **Multi-Surface Support**:
   - Each Surface is independent
   - Can have multiple tabs/splits without interference
   - Shared font cache for efficiency

4. **Platform Abstraction**:
   - Terminal and Termio are platform-agnostic
   - Only Renderer and apprt are platform-specific
   - Same core logic for macOS, Linux, Windows

### Example: Opening a New Tab

When you press `Cmd+T` to open a new tab:

1. Swift receives the keyboard event
2. Swift calls `ghostty_app_new_surface()`
3. Zig creates a new Surface
4. Surface creates a new Termio
5. Termio creates a new Exec
6. Exec spawns a new shell subprocess with its own PTY
7. Exec starts a new read thread for that PTY
8. Surface creates a new Renderer Thread
9. Now you have two independent terminal instances

Each tab has its own:
- PTY (separate file descriptor)
- Subprocess (separate shell process)
- Read thread (separate I/O thread)
- Renderer thread (separate rendering thread)
- Terminal state (separate character grid)

But they share:
- Font cache (via App.font_grid_set)
- App mailbox (for coordinating with Swift)
- Main thread (for final drawing)

## Related Documentation

- **MACOS_ARCHITECTURE.md** - Overall Swift-Zig integration
- **READING_LIST.md** - Codebase study guide
- **src/apprt/embedded.zig** - Embedded runtime implementation
- **src/termio/Exec.zig** - PTY execution and reading
- **src/renderer/Thread.zig** - Renderer thread implementation

---

**Last Updated**: 2026-02-15
**Applies to**: macOS egress flow (PTY → Display)
