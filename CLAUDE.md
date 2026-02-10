# CLAUDE.md - NexusPVR

## Project Overview

A native Apple client for NextPVR (network PVR/DVR software). Supports iOS, iPadOS, tvOS, and macOS from a single codebase using SwiftUI.

## Tech Stack

- **Language**: Swift 5.0
- **UI Framework**: SwiftUI (iOS 26+, tvOS 26+, macOS 26+)
- **Video Playback**: MPV (libmpv) via Metal rendering
- **Networking**: URLSession with async/await
- **Data Sync**: iCloud Key-Value Store (NSUbiquitousKeyValueStore)
- **Architecture**: MVVM with environment objects

## Project Structure

```
NexusPVR/
├── NexusPVRApp.swift    # App entry point (@main)
├── ContentView.swift    # Main content view with server config check
├── Core/
│   ├── Models/
│   │   ├── Channel.swift          # Channel model (id, name, number, hasIcon)
│   │   ├── Program.swift          # EPG program model with computed airing/progress
│   │   ├── Recording.swift        # Recording model + RecordingStatus enum
│   │   ├── Session.swift          # API response models + ServerConfig
│   │   └── UserPreferences.swift  # User preferences + PlayerStats
│   ├── Services/
│   │   ├── NextPVRClient.swift    # Main API client with authentication
│   │   ├── ImageCache.swift       # In-memory image cache
│   │   └── MD5Hasher.swift        # MD5 hashing for authentication
│   └── Extensions/
│       └── Notification+Extensions.swift  # Notification names (preferencesDidSync, recordingsDidChange)
├── Design/
│   └── Theme.swift      # Colors, spacing, typography, corner radius, animation, platform-specific styles
├── Features/
│   ├── Guide/           # EPG grid view (GuideView, GuideViewModel, ProgramCell, ProgramDetailView, GuideScrollHelper)
│   ├── LiveTV/          # Live TV channel list (LiveTVView, LiveTVViewModel)
│   ├── Player/          # MPV video player (PlayerView containing MPVPlayerCore + MPVContainerView)
│   ├── Recordings/      # Recording management (RecordingsListView, RecordingsViewModel, RecordingRow, RecordingDetailView)
│   ├── Settings/        # App settings (SettingsView, ServerConfigView, KeywordsEditorView)
│   └── Topics/          # Keyword-based program discovery (TopicsView, TopicsViewModel, TopicProgramRow)
└── Navigation/
    ├── AppState.swift   # Global app state (Tab enum: guide, recordings, topics, settings)
    └── NavigationRouter.swift  # Platform-adaptive navigation (iOS, tvOS, macOS variants)
```

## Key Patterns

### Environment Objects
- `NextPVRClient` - API client, injected via `.environmentObject()`
- `AppState` - Global state for playback, navigation

### View Models
- Use `@MainActor` and `ObservableObject` for view models
- All view models follow this pattern: `GuideViewModel`, `LiveTVViewModel`, `RecordingsViewModel`, `TopicsViewModel`

### Platform Conditionals
Use `#if os(tvOS)` / `#if os(macOS)` for platform-specific code:
```swift
#if os(tvOS)
// tvOS-specific UI
#else
// iOS/macOS UI
#endif
```

### Theme System
All styling goes through `Theme.*`:
- **Colors**: `accent`, `accentSecondary`, `background`, `surface`, `surfaceElevated`, `surfaceHighlight`, `textPrimary`, `textSecondary`, `textTertiary`, `success`, `warning`, `error`, `recording`, `guideNowPlaying`, `guidePast`, `guideScheduled`
- **Spacing**: `spacingXS` (4), `spacingSM` (8), `spacingMD` (16), `spacingLG` (24), `spacingXL` (32)
- **Corner Radius**: `cornerRadiusSM` (8), `cornerRadiusMD` (12), `cornerRadiusLG` (20)
- **Animation**: `animationDuration` (0.25), `springAnimation`
- **Platform sizes**: `cellHeight`, `channelColumnWidth`, `hourColumnWidth`, `iconSize` (all differ per platform)
- **Typography**: Font extensions (`displayLarge`, `displayMedium`, `headline`, `subheadline`, `body`, `caption`, `footnote`) + tvOS-specific (`tvTitle`, `tvHeadline`, `tvBody`, `tvCaption`)
- **View Modifiers**: `CardStyle`, `AccentButtonStyle`, `SecondaryButtonStyle`

## NextPVR API

The app communicates with NextPVR server via JSON API:

### Authentication
- Endpoint: `session.initiate` → `session.login`
- Uses PIN-based auth with MD5 hashing: `md5(":" + md5(PIN) + ":" + salt)`
- Stores SID in session, auto-reauthenticates on 401 responses

### Key Endpoints (via NextPVRClient)

**Channels & EPG:**
- `getChannels()` - List all channels
- `getListings(channelId:)` - EPG data for a channel
- `getAllListings(for channels:)` - Batch fetch EPG data for multiple channels
- `channelIconURL(channelId:)` - Get channel icon URL

**Recordings:**
- `getAllRecordings()` - Returns 3-tuple: `(completed: [Recording], recording: [Recording], scheduled: [Recording])`
- `getRecordings(filter:)` - Get recordings with filter ("ready", "recording", "pending")
- `scheduleRecording(eventId:)` - Schedule a recording
- `cancelRecording(recordingId:)` - Cancel a scheduled or in-progress recording
- `setRecordingPosition(recordingId:, positionSeconds:)` - Set resume position for playback

**Streaming:**
- `liveStreamURL(channelId:)` - Get stream URL for live TV
- `recordingStreamURL(recordingId:)` - Get stream URL for recording

**Configuration:**
- `updateConfig(_:)` - Update server configuration

### Response Models
All API responses use `Codable` structs in `Core/Models/`:
- `Channel` - Channel with id, name, number, hasIcon, streamURL
- `Program` - EPG program with computed properties (startDate, endDate, duration, isCurrentlyAiring, progress)
- `Recording` - Recording with playbackPosition; `RecordingStatus` enum (pending, recording, ready, failed, conflict, deleted)
- `SessionInitiateResponse`, `SessionLoginResponse`, `APIResponse` - Auth flow responses
- `ServerConfig` - Server connection settings (synced via iCloud)
- `UserPreferences` - Keywords and seek times (synced via iCloud)
- `PlayerStats` - MPV playback statistics (avgFps, avgBitrate, droppedFrames)

## tvOS Considerations

- **Focus Management**: Use `@FocusState`, `.focusSection()`, `.prefersDefaultFocus()`
- **Button Styles**: Custom `TVGuideButtonStyle`, `TVChannelButtonStyle`, `TVNavigationButtonStyle`
- **Input Components**: `TVTextField`, `TVNumberField` (alert-based input), `TVSettingsSection`
- **Remote Control**: MPV player handles play/pause, seek via Siri Remote
- **Larger UI**: Theme provides larger sizes for tvOS (e.g., `cellHeight: 100` vs `60`, `iconSize: 80` vs `48`)

## Video Player (MPV)

All player code lives in `Features/Player/PlayerView.swift`:
- Uses libmpv compiled for each platform (`import Libmpv`)
- Metal-based rendering via `CAMetalLayer`
- `MPVPlayerCore` class - Core player logic (defined inside PlayerView.swift)
- `MPVContainerView` struct - Platform wrapper (NSViewRepresentable on macOS, UIViewRepresentable on iOS/tvOS)
- `PlayerView` - Main SwiftUI view wrapping the player
- Seek times configurable in settings (separate backward/forward)

## User Preferences

Stored in `UserPreferences` struct (Core/Models/UserPreferences.swift), synced via iCloud:
- `keywords` - Topic keywords for program matching
- `seekBackwardSeconds` - Default 10
- `seekForwardSeconds` - Default 30

Also defines `PlayerStats` struct for MPV playback statistics.

Server config stored separately in `ServerConfig` (Core/Models/Session.swift).

## Build Instructions

1. Open `NexusPVR.xcodeproj` in Xcode
2. Select target (iOS, tvOS, or macOS)
3. Build and run

Note: MPV framework must be properly linked for video playback.

## Code Style

- Use `Theme.*` for all colors, spacing, and sizing
- Prefer `async/await` over completion handlers
- Use `@ViewBuilder` for conditional view composition
- Keep views small, extract reusable components
- Use `#if DEBUG` for debug-only code

## Image Generation

App icons and assets are generated using Python with Pillow. Setup:

```bash
python3 -m venv /private/tmp/imgvenv
source /private/tmp/imgvenv/bin/activate
pip install Pillow
```

### tvOS App Icon Structure

tvOS uses layered icons with parallax effect:
- **Back layer**: Background gradient
- **Middle layer**: Transparent (depth layer)
- **Front layer**: Foreground elements (play button, recording dot)

Sizes required:
- App Icon: `400x240` (1x), `800x480` (2x)
- App Store: `1280x768`

Location: `Assets.xcassets/tv.brandassets/App Icon.imagestack/`

### Generate tvOS Icon Layers
Use python3 to generate images

```python
from PIL import Image, ImageDraw
import math

def create_radial_gradient(width, height, center_color, edge_color):
    img = Image.new('RGB', (width, height))
    pixels = img.load()
    cx, cy = width / 2, height / 2
    max_dist = math.sqrt((width/2)**2 + (height/2)**2)

    for y in range(height):
        for x in range(width):
            dist = math.sqrt((x - cx)**2 + (y - cy)**2)
            ratio = min(dist / max_dist, 1.0)
            r = int(center_color[0] + (edge_color[0] - center_color[0]) * ratio)
            g = int(center_color[1] + (edge_color[1] - center_color[1]) * ratio)
            b = int(center_color[2] + (edge_color[2] - center_color[2]) * ratio)
            pixels[x, y] = (r, g, b)
    return img

def create_front_layer(width, height):
    img = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx, cy = width / 2, height / 2
    scale = width / 400

    # Play button triangle
    triangle_size = 70 * scale
    play_x = cx - triangle_size * 0.3
    points = [
        (play_x - triangle_size * 0.4, cy - triangle_size * 0.6),
        (play_x - triangle_size * 0.4, cy + triangle_size * 0.6),
        (play_x + triangle_size * 0.6, cy)
    ]
    draw.polygon(points, fill=(255, 255, 255, 255))

    # Recording dot
    dot_radius = 12 * scale
    dot_x, dot_y = cx + 55 * scale, cy - 45 * scale
    draw.ellipse([dot_x - dot_radius, dot_y - dot_radius,
                  dot_x + dot_radius, dot_y + dot_radius],
                 fill=(236, 51, 7, 255))
    return img

# Theme colors
center_color = (42, 107, 153)  # Light blue
edge_color = (15, 35, 60)      # Dark blue

# Generate layers
back = create_radial_gradient(400, 240, center_color, edge_color)
front = create_front_layer(400, 240)
middle = Image.new('RGBA', (400, 240), (0, 0, 0, 0))
```
