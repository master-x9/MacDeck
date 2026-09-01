# PhoneDeck Android Implementation Plan

Implement the full stack for PhoneDeck Android: from network discovery and WebSocket connection to the pairing handshake and the grid UI.

## User Review Required

> [!IMPORTANT]
> - The app will require **Internet** and **Access Network State** permissions for WebSocket and NSD.
> - **Landscape locking** and **Immersive mode** will be implemented for the main grid.
> - A `clientID` (UUID) will be generated on first launch and persisted in `SharedPreferences`.

## Proposed Changes

### Dependencies & Setup

#### [MODIFY] [libs.versions.toml](file:///Users/jatin/AndroidStudioProjects/macDeck/gradle/libs.versions.toml)
Add OkHttp, Kotlinx Serialization, and Coroutines dependencies.

#### [MODIFY] [app/build.gradle.kts](file:///Users/jatin/AndroidStudioProjects/macDeck/app/build.gradle.kts)
Apply the serialization plugin and add the new dependencies.

#### [MODIFY] [AndroidManifest.xml](file:///Users/jatin/AndroidStudioProjects/macDeck/app/src/main/AndroidManifest.xml)
Add necessary permissions and lock `MainActivity` to landscape.

---

### Data Models

#### [NEW] [Models.kt](file:///Users/jatin/AndroidStudioProjects/macDeck/app/src/main/java/com/example/macdeck/Models.kt)
Define `DeckPage`, `DeckTile`, and command models for the wire protocol.

---

### Network & Logic

#### [NEW] [DiscoveryManager.kt](file:///Users/jatin/AndroidStudioProjects/macDeck/app/src/main/java/com/example/macdeck/DiscoveryManager.kt)
Handle NSD (Network Service Discovery) to find the Mac host.

#### [NEW] [WebSocketManager.kt](file:///Users/jatin/AndroidStudioProjects/macDeck/app/src/main/java/com/example/macdeck/WebSocketManager.kt)
Handle the WebSocket connection and the `HELLO` pairing handshake.

#### [NEW] [AppState.kt](file:///Users/jatin/AndroidStudioProjects/macDeck/app/src/main/java/com/example/macdeck/AppState.kt)
A ViewModel to manage the application state (Searching, Connecting, Paired, etc.) and coordinate network logic.

---

### UI Components

#### [NEW] [UiComponents.kt](file:///Users/jatin/AndroidStudioProjects/macDeck/app/src/main/java/com/example/macdeck/UiComponents.kt)
Reusable UI elements like the Grid Tile, Status Indicators, etc.

#### [MODIFY] [MainActivity.kt](file:///Users/jatin/AndroidStudioProjects/macDeck/app/src/main/java/com/example/macdeck/MainActivity.kt)
Implement the main UI entry point, handling different states and the immersive grid.

## Verification Plan

### Automated Tests
- Unit tests for JSON serialization/deserialization.
- Mocking WebSocket responses to verify the state machine.

### Manual Verification
- Deploy to an Android device/emulator.
- Verify discovery of a simulated Mac service (or real Mac if available).
- Verify pairing handshake flow.
- Verify 2x4 grid layout and haptic feedback on tap.
- Verify settings screen (device name change and pairing reset).
