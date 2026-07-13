# Manual acceptance — live checks

Everything machine-checkable is green (see STATUS.md). These six need a human at the
keyboard / real hardware, because they involve the `fn` key, the menu-bar pixels, sleep,
or pasting into a third-party app — none of which can be driven headless here.

**First deploy the new config** (the transcription worker is already deployed and verified;
only `init.lua` needs to land for the UI features):

```bash
./install.sh --yes            # backs up ~/.hammerspoon/init.lua, deploys the new one
# then: open Hammerspoon → Reload Config, grant Accessibility + Microphone if prompted
```

| # | What to do | Expected |
|---|---|---|
| 1 | **PTT dictation.** Hold `fn`, say *"проверка диктовки, this is a test"*, release. | The text is pasted into the active app — Russian in Cyrillic, English in Latin, punctuated, no *«Продолжение следует»* tail. |
| 2 | **Menu-bar icon + history.** Watch the menu-bar icon during a dictation, then click it. | Grey ring (idle) → red dot (holding `fn`) → orange dot (transcribing) → grey. The dropdown lists recent dictations as `HH:MM · preview… [engine]`; clicking one copies it to the clipboard (no auto-paste). |
| 3 | **Toggle mode.** Set `triggerMode = "toggle"` in `~/.hammerspoon/init.lua`, Reload. Tap `fn`, speak, tap `fn` again. | First tap starts (the dot stays lit without holding the key); second tap transcribes and pastes. Restore `"ptt"` after. |
| 4 | **Toggle auto-stop.** Temporarily set `toggleMaxSeconds = 5`, Reload, tap `fn`, wait > 5 s without a second tap. | The session auto-stops and pastes whatever was captured. Restore `300` after. |
| 5 | **Hotkey watchdog / sleep.** In the Hammerspoon console run `dictationFnTap:stop()`, wait ~3 s, then dictate. Separately: `pmset sleepnow`, wake, dictate. | Dictation works both times **without** a manual Reload (the watchdog re-armed the `fn` tap). |
| 6 | **Menu-bar off.** Set `menubarEnabled = false`, Reload. | The menu-bar icon disappears; PTT dictation still works and the on-screen dot still shows. Restore `true` after. |

If any of these fail, `skill/whisper-dictation/scripts/whisper-doctor.sh` and
[docs/known-issues.md](docs/known-issues.md) are the first stops.
