"""Update installed WinDeck releases without blocking the dashboard or phone connection."""
import ctypes
import logging
import threading

import velopack

REPOSITORY = "https://github.com/master-x9/MacDeck"


def monitor_updates(stop: threading.Event, requested: threading.Event, host):
    declined = None
    manual = False
    while not stop.is_set():
        try:
            manager = velopack.UpdateManager(velopack.GithubSource(REPOSITORY))
            host.app_version = manager.get_current_version()
            if "-" in host.app_version:
                manager = velopack.UpdateManager(velopack.GithubSource(REPOSITORY, prerelease=True))
            update = manager.check_for_updates()
            if update and not stop.is_set():
                release = update.TargetFullRelease
                if manual or release.Version != declined:
                    message = f"WinDeck {release.Version} is available.\n\n{release.NotesMarkdown or ''}\n\nDownload the update and restart WinDeck?"
                    if ctypes.windll.user32.MessageBoxW(None, message, "WinDeck update", 0x10024) == 6:
                        try:
                            manager.download_updates(update)
                            if not stop.is_set():
                                manager.apply_updates_and_restart(update)
                        except Exception as error:
                            ctypes.windll.user32.MessageBoxW(None, str(error), "WinDeck update failed", 0x10)
                    else:
                        declined = release.Version
            elif manual and not stop.is_set():
                ctypes.windll.user32.MessageBoxW(None, f"WinDeck {host.app_version} is up to date.", "WinDeck updates", 0x10040)
        except Exception as error:
            if manual and not stop.is_set():
                ctypes.windll.user32.MessageBoxW(None, str(error), "Could not check for updates", 0x10010)
            logging.getLogger("WinDeck").info("Update check unavailable: %s", error)
        manual = requested.wait(4 * 60 * 60)
        requested.clear()
