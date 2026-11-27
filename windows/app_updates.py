"""Update installed WinDeck releases without blocking the dashboard or phone connection."""
import ctypes
import logging
import threading

import velopack

REPOSITORY = "https://github.com/master-x9/MacDeck"


def monitor_updates(stop: threading.Event):
    declined = None
    while not stop.is_set():
        try:
            manager = velopack.UpdateManager(velopack.GithubSource(REPOSITORY))
            update = manager.check_for_updates()
            if update and not stop.is_set():
                release = update.TargetFullRelease
                if release.Version != declined:
                    message = f"WinDeck {release.Version} is available.\n\n{release.NotesMarkdown or ''}\n\nDownload the update and restart WinDeck?"
                    if ctypes.windll.user32.MessageBoxW(None, message, "WinDeck update", 0x24) == 6:
                        try:
                            manager.download_updates(update)
                            if not stop.is_set():
                                manager.apply_updates_and_restart(update)
                        except Exception as error:
                            ctypes.windll.user32.MessageBoxW(None, str(error), "WinDeck update failed", 0x10)
                    else:
                        declined = release.Version
        except Exception as error:
            logging.getLogger("WinDeck").info("Update check unavailable: %s", error)
        stop.wait(4 * 60 * 60)
