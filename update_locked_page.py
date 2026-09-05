import re

with open("/Users/jatin/New MacDeck/macDeckk/base64_icons.txt") as f:
    base64_content = f.read()

kt_path = "/Users/jatin/AndroidStudioProjects/macDeck/app/src/main/java/com/example/macdeck/LockedPage.kt"
with open(kt_path) as f:
    kt_code = f.read()

# Replace UNLOCK_SLOT_INDEX and all old base64 constants up to 'private fun controlTile'
pattern = re.compile(r'const val UNLOCK_SLOT_INDEX = 2.*?private fun controlTile', re.DOTALL)
new_section = f"const val UNLOCK_SLOT_INDEX = 2\n\n{base64_content}\n\n    private fun controlTile"
kt_code = pattern.sub(new_section, kt_code)

# Tiles are already up-to-date, so we don't need to replace them.

with open(kt_path, "w") as f:
    f.write(kt_code)

print("Updated LockedPage.kt")
