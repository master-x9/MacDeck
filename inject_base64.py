import re

with open("/Users/jatin/New MacDeck/macDeckk/base64_icons.txt") as f:
    base64_content = f.read()

kt_path = "/Users/jatin/AndroidStudioProjects/macDeck/app/src/main/java/com/example/macdeck/LockedPage.kt"
with open(kt_path) as f:
    kt_code = f.read()

new_controlTile = """
    private fun controlTile(slot: Int, action: String, iconData: String? = null): DeckTile = DeckTile(
        id = "locked-slot-$slot",
        slotIndex = slot,
        tileType = SystemControlTile(action = action),
        iconData = iconData
    )
"""

tiles_code = """
            controlTile(0, "brightnessUp", brightnessUpBase64),
            controlTile(1, "sleepMac", sleepMacBase64),
            controlTile(2, "unlockMac", unlockMacBase64),
            controlTile(3, "keepAwake", keepAwakeBase64),
            controlTile(4, "volumeUp", volumeUpBase64),
            controlTile(5, "brightnessDown", brightnessDownBase64),
            controlTile(6, "previousTrack", previousTrackBase64),
            controlTile(7, "playPause", playPauseBase64),
            controlTile(8, "nextTrack", nextTrackBase64),
            controlTile(9, "volumeDown", volumeDownBase64)
"""

kt_code = re.sub(r'private fun controlTile.*?SystemControlTile\(action = action\)\n\s*\)', new_controlTile.strip(), kt_code, flags=re.DOTALL)

kt_code = re.sub(r'controlTile\(0, "brightnessDown"\).*?controlTile\(9, "kbBrightnessUp"\)', tiles_code.strip(), kt_code, flags=re.DOTALL)

# Inject the base64 constants
kt_code = kt_code.replace("const val UNLOCK_SLOT_INDEX = 6", "const val UNLOCK_SLOT_INDEX = 6\n\n" + base64_content)

with open("/Users/jatin/New MacDeck/macDeckk/LockedPage_new.kt", "w") as f:
    f.write(kt_code)
print("Updated LockedPage_new.kt")
