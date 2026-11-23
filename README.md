# Omarchy Printers (`ivanilton.printers`)

A native Omarchy shell bar widget and keyboard-driven panel for CUPS printer management, print queue monitoring, `system-config-printer` task automation, and hardware maintenance.

## Features

- **Bar Indicator**: Shows printer status, active job badge count, urgent state on errors or stopped CUPS service, and localized tooltips.
  - Left-click: toggle panel · Right-click: refresh · Middle-click: open `system-config-printer`.
- **Print Queue (`1`)**: View active jobs and completed job history, hold/release, reprint, move jobs between printers, cancel individual jobs or clear the queue, print a test page, or send PDFs/images/text files (including recent files from Downloads, Documents, and Desktop).
- **Printers (`2`)**: Quick-action buttons (**Nozzles**, **Clean**, **Align**, **Test page**, **Options**), ink/toner level bars, set default printer, pause/resume, and inline options drawer (enabled/accepting/shared toggles, paper size, color mode, quality, duplex, error policy, description, location, remove printer).
- **Maintenance (`3`)**: Dedicated tab for **Nozzle check**, **Clean print heads**, **Print test page**, **Report ink levels**, **Auto-configure**, and a guided 2-step **Head alignment** workflow. Automatically supports:
  - `application/vnd.cups-command` drivers
  - Epson ESC/P-R printers via `commandtoescpx` (`application/vnd.cups-raw`)
  - HPLIP (`hp-clean`, `hp-align`, `hp-levels`)
- **Setup (`4`)**: Auto-discover network (IPP/IPPS/DNS-SD) and USB printers, add manually by URI, toggle CUPS server settings (shared printers, cancel any job, web UI), and start/restart `cups.service`.
- **Translations**: Live language switching for `en`, `pt-BR`, and `pt`.

## Requirements

- `python-pycups`
- `cups` (`lpadmin`, `lpoptions`)
- Optional: `system-config-printer`, `cups-filters` (`commandtoescpx` for Epson ESC/P-R maintenance)

## Installation

```bash
omarchy plugin add https://github.com/silvaivanilto/omarchy-printers --enable
```

## Keyboard Shortcuts (Panel Open)

- `1` / `2` / `3` / `4` or `←` / `→` (`h` / `l`): Switch tabs
- `↑` / `↓` (`j` / `k`): Navigate list items
- `Enter` / `Space`: Hold/release/reprint job, expand printer, or add discovered printer
- `x` / `Delete`: Cancel active job or remove printer
- `n`: Nozzle check · `c`: Clean heads · `t`: Test page · `p`: Pause/resume · `r`: Refresh · `a`: Scan printers · `o`: Open `system-config-printer`

## IPC Commands

```bash
omarchy-shell ivanilton.printers toggle
omarchy-shell ivanilton.printers openTab maintenance
omarchy-shell ivanilton.printers status
omarchy-shell ivanilton.printers testPage <printer>
omarchy-shell ivanilton.printers nozzleCheck <printer>
omarchy-shell ivanilton.printers cleanHeads <printer>
omarchy-shell ivanilton.printers printAlignment <printer> 1
omarchy-shell ivanilton.printers setAlignment <printer> 1 7
omarchy-shell ivanilton.printers togglePause <printer>
omarchy-shell ivanilton.printers setDefault <printer>
omarchy-shell ivanilton.printers cancelAll <printer>
omarchy-shell ivanilton.printers discover
```

## Testing

```bash
python3 -m unittest discover -s tests -v
omarchy plugin validate .
```
