#!/usr/bin/env python3
"""Generate EmojiData.swift from unicode.org emoji-test.txt.

Rules:
- fully-qualified entries only
- skip skin-tone variants (1F3FB..1F3FF) and the Component group
- cap at Emoji 15.1 (max version rendered by iOS 18.0, the extension's target)
- merge "Smileys & Emotion" + "People & Body" into one category like native iOS
"""
import re
from pathlib import Path

# Download https://unicode.org/Public/emoji/latest/emoji-test.txt next to
# this script first; it is not checked in.
SRC = Path(__file__).parent / "emoji-test.txt"
OUT = Path(__file__).parent.parent / "Sources" / "GeneralKeyboard" / "Emoji" / "EmojiData.swift"

MAX_VERSION = 15.1
SKIN_TONES = {0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF}

# unicode group -> (category key, order)
GROUP_MAP = {
    "Smileys & Emotion": "smileys",
    "People & Body": "smileys",
    "Animals & Nature": "nature",
    "Food & Drink": "food",
    "Activities": "activity",
    "Travel & Places": "travel",
    "Objects": "objects",
    "Symbols": "symbols",
    "Flags": "flags",
}

# category key -> SF Symbol icon. Section titles are language data and live
# in each keyboard's definition (KeyboardStrings.emojiCategoryTitles),
# keyed by these ids.
CATEGORIES = [
    ("smileys",  "face.smiling"),
    ("nature",   "pawprint"),
    ("food",     "fork.knife"),
    ("activity", "soccerball"),
    ("travel",   "car"),
    ("objects",  "lightbulb"),
    ("symbols",  "heart"),
    ("flags",    "flag"),
]

buckets = {key: [] for key, _ in CATEGORIES}
group = None
line_re = re.compile(
    r"^([0-9A-F ]+?)\s*;\s*fully-qualified\s*#\s*(\S+)\s+E(\d+\.\d+)\s"
)

for line in SRC.read_text(encoding="utf-8").splitlines():
    if line.startswith("# group:"):
        group = line.split(":", 1)[1].strip()
        continue
    m = line_re.match(line)
    if not m or group not in GROUP_MAP:
        continue
    codepoints = [int(cp, 16) for cp in m.group(1).split()]
    if SKIN_TONES & set(codepoints):
        continue
    if float(m.group(3)) > MAX_VERSION:
        continue
    buckets[GROUP_MAP[group]].append(m.group(2))

lines = [
    "//",
    "//  EmojiData.swift",
    "//  GeneralKeyboard",
    "//",
    "//  Generated from unicode.org emoji-test.txt (fully-qualified, no skin",
    "//  tones, capped at Emoji 15.1 = max rendered by iOS 18.0).",
    "//  Regenerate with scripts/gen_emoji.py rather than editing by hand.",
    "//",
    "",
    "struct EmojiCategory {",
    "    let id: String      // stable key; the keyboard definition supplies the section title",
    "    let icon: String    // SF Symbol shown in the bottom category bar",
    "    let emojis: [String]",
    "}",
    "",
    "enum EmojiData {",
    "",
    "    static let categories: [EmojiCategory] = [",
]

for key, icon in CATEGORIES:
    emojis = buckets[key]
    lines.append(f'        EmojiCategory(id: "{key}", icon: "{icon}", emojis: [')
    for i in range(0, len(emojis), 16):
        chunk = ",".join(f'"{e}"' for e in emojis[i:i + 16])
        lines.append(f"            {chunk},")
    lines.append("        ]),")

lines += ["    ]", "}", ""]
OUT.write_text("\n".join(lines), encoding="utf-8")

total = sum(len(v) for v in buckets.values())
for key, _ in CATEGORIES:
    print(f"{key:10} {len(buckets[key]):5}")
print(f"{'total':10} {total:5}")
