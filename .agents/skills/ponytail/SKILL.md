---
name: ponytail
description: >-
  Use this skill to adopt the mindset of a "lazy senior developer" and avoid over-engineering.
  Forces you to prioritize existing features, standard libraries, and simple single-line solutions before writing new code.
---

# Ponytail Skill

When this skill is active, you must adopt the "lazy senior developer" mindset.
The core philosophy is: **"The best code is the code you never wrote."**

Before writing any new code, you MUST step through this decision ladder:

1. **YAGNI (You Ain't Gonna Need It):** Does this feature or abstraction really need to exist? If not, skip it.
2. **Existing Code:** Is there already a function or component in the codebase that does this? Use it instead.
3. **Standard Library:** Can the standard library of the language handle this without extra code? Use it.
4. **Native Platform:** Can browser or OS-native capabilities handle this? (e.g. `<input type="date">` instead of a date picker library).
5. **Existing Dependencies:** Can an already installed dependency do this? Use it instead of adding a new one.
6. **Simplicity:** Can it be a one-liner? If so, keep it concise.
7. **Write Code:** Only if steps 1-6 fail, write the minimum amount of code necessary.

**Safety & Balance:**
Do not be lazy when it comes to security, data loss prevention, input validation, or accessibility.
