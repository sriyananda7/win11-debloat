# Win11-Debloat

A small, readable, **dry-run-by-default** script that cleans up a fresh Windows 11 install:

- Removes preinstalled bloatware apps (Clipchamp, Bing apps, Solitaire, OEM promo apps, etc.)
- Disables startup items that slow down boot (Teams, Edge auto-launch, and more)
- Turns off ads, suggestions, and some tracking toggles
- Clears temp files and Windows Update leftovers (never touches your Downloads folder)

Everything it touches is listed in [`config.json`](config.json). Fork the repo, edit the lists to match your PC, and run it.

## Quick start

1. Download or clone this repo.
2. Open **Windows PowerShell as administrator** in the repo folder.
3. **Preview first.** This changes nothing:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Debloat.ps1
   ```

4. When the preview looks right, apply it:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Debloat.ps1 -Apply
   ```

5. Restart your PC.

## Options

| Flag | What it does |
|---|---|
| `-Apply` | Actually make changes. Without it, the script only prints what it would do. |
| `-IncludeOptional` | Also process the `optional` apps and startup items (Outlook, To Do, Phone Link, Xbox app, OneDrive/Docker/AnyDesk autostart, etc.). Read the list first. |
| `-Deprovision` | Also remove apps from the Windows image so new user accounts don't get them. |
| `-SkipApps` `-SkipStartup` `-SkipPrivacy` `-SkipCleanup` | Skip a section. |
| `-SkipRestorePoint` | Don't create a restore point before applying. |
| `-Yes` | Skip the "type YES" confirmation. |
| `-ConfigPath` | Use a different config file. |

Example: apply only the safe app removals and the ads/privacy settings:

```powershell
.\Debloat.ps1 -Apply -SkipStartup -SkipCleanup
```

## Customizing (the point of forking)

Edit `config.json`:

- `apps.safe`: removed by default
- `apps.oem`: manufacturer promo apps (add your brand's; find names with `Get-AppxPackage | Select Name`)
- `apps.optional`: removed only with `-IncludeOptional`
- `startup.disable` / `startup.optional`: startup entries to turn off (wildcards allowed)
- `registry`: per-user settings to apply (ads, suggestions, tracking toggles)

To find what is installed or starting up on your own PC:

```powershell
Get-AppxPackage | Select Name | Sort Name
Get-CimInstance Win32_StartupCommand | Select Name, Command, Location | Format-List
```

## Safety

- **Preview by default.** Nothing changes without `-Apply`.
- **Restore point** is created before changes (Windows allows one per 24 hours by default).
- **Protected list.** Core components (Store, Windows Security, runtimes, Photos, Calculator, Notepad, Terminal, GPU/audio drivers and control panels, Xbox background services, codecs) are hard-blocked in the script and are skipped even if you add them to the config.
- **Log files** for every run are saved in `logs/`.
- Removed apps can be reinstalled from the Microsoft Store or with `winget install`.
- Startup items are only disabled, not uninstalled. Re-enable them in Task Manager → Startup apps.
- Registry changes are per-user toggles in Settings; flip them back in Settings → Privacy & security / Personalization.

## Not automated (do these by hand)

- Diagnostic data level ("Send optional diagnostic data") and "Delete diagnostic data": Settings → Privacy & security → Diagnostics & feedback
- Lock screen: set it to **Picture** instead of Windows Spotlight
- Notifications tips and suggestions: Settings → System → Notifications → Additional settings

These either need policy changes or vary too much between Windows builds to script reliably.

## Notes and limits

- Windows feature updates can reinstall some apps. Re-run the script afterwards.
- Run it on Windows PowerShell 5.1 (the default one) for best results.
- Review any script you run as administrator, including this one. It's short on purpose.

## Disclaimer

Provided as-is, with no warranty. Use at your own risk. Test on a non-critical machine first and keep the restore point.

## License

MIT
