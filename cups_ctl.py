#!/usr/bin/env python3
"""CUPS control and inspection helper for the ivanilton.printers Omarchy plugin.

All commands emit a single JSON object on stdout and exit 0 on success or 1 on
failure. Untrusted values are strictly validated and bounded, and subprocesses
are always invoked with argv lists (never shell=True).
"""

import argparse
import heapq
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
  import cups
except ImportError:
  cups = None


MAX_PRINTERS = 50
MAX_JOBS = 100
MAX_DISCOVERED = 50
MAX_OPTION_CHOICES = 64
MAX_STR_LEN = 200
MAX_URI_LEN = 512

QUEUE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$")
OPTION_KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
OPTION_VAL_RE = re.compile(r"^[A-Za-z0-9._:/+-]{1,128}$")
ALLOWED_URI_SCHEMES = (
  "ipp://",
  "ipps://",
  "dnssd://",
  "usb://",
  "socket://",
  "http://",
  "https://",
  "lpd://",
  "smb://",
  "hp://",
  "hpfax://",
  "serial://",
  "parallel://",
)
GENERIC_DEVICE_SCHEMES = {
  "beh",
  "cups-brf",
  "http",
  "https",
  "ipp",
  "ipps",
  "lpd",
  "parallel",
  "serial",
  "smb",
  "socket",
  "usb",
}
ALLOWED_ERROR_POLICIES = {"stop-printer", "retry-job", "abort-job"}
ALLOWED_SERVER_BOOL_KEYS = {"_share_printers", "_user_cancel_any", "WebInterface"}
ALLOWED_MAINTENANCE_ACTIONS = {
  "clean-heads",
  "nozzle-check",
  "print-alignment",
  "set-alignment",
  "report-levels",
  "auto-configure",
}
COMMANDTOESCPX_PATH = Path("/usr/lib/cups/filter/commandtoescpx")
PRINTABLE_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".webp", ".txt", ".ps"}
BENIGN_REASONS = {"none", "paused", "connecting-to-device"}
WARNING_REASON_HINTS = ("low", "empty", "almost", "warning", "report", "toner", "ink", "marker")
ERROR_REASON_HINTS = ("error", "jam", "open", "offline", "stopped", "fault", "fail", "media-empty", "cover-open")

PRINTER_STATE_MAP = {
  3: "idle",
  4: "printing",
  5: "stopped",
}

JOB_STATE_MAP = {
  3: "pending",
  4: "held",
  5: "processing",
  6: "stopped",
  7: "canceled",
  8: "aborted",
  9: "completed",
}


def clean_str(value, max_len=MAX_STR_LEN):
  if value is None:
    return ""
  text = str(value)
  text = re.sub(r"[\x00-\x1f\x7f]+", " ", text).strip()
  if len(text) > max_len:
    text = text[: max_len - 1] + "…"
  return text


def validate_printer_name(name):
  cleaned = str(name or "").strip()
  if not QUEUE_NAME_RE.match(cleaned):
    raise ValueError("Invalid printer queue name.")
  return cleaned


def validate_uri(uri):
  cleaned = str(uri or "").strip()
  if not cleaned or len(cleaned) > MAX_URI_LEN:
    raise ValueError("Invalid printer URI.")
  if re.search(r"[\x00-\x1f\x7f\s]", cleaned):
    raise ValueError("Printer URI must not contain whitespace or control characters.")
  lower = cleaned.lower()
  if not any(lower.startswith(scheme) for scheme in ALLOWED_URI_SCHEMES):
    raise ValueError("Unsupported printer URI scheme.")
  return cleaned


def validate_job_id(raw):
  try:
    jid = int(raw)
  except (TypeError, ValueError) as exc:
    raise ValueError("Invalid job id.") from exc
  if jid <= 0 or jid > 2_147_483_647:
    raise ValueError("Job id out of range.")
  return jid


def parse_bool_flag(raw):
  val = str(raw or "").strip().lower()
  if val in ("1", "true", "yes", "on"):
    return True
  if val in ("0", "false", "no", "off"):
    return False
  raise ValueError("Expected true or false.")


def sanitize_queue_name(raw):
  text = re.sub(r"[^A-Za-z0-9._-]+", "-", str(raw or "").strip())
  text = re.sub(r"-{2,}", "-", text).strip(".-_")
  if not text or not text[0].isalnum():
    text = "Printer-" + text
  return text[:64]


def emit(payload, exit_code=0):
  sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
  sys.exit(exit_code)


def run_cmd(argv, timeout=15):
  try:
    proc = subprocess.run(
      argv,
      check=False,
      capture_output=True,
      text=True,
      timeout=timeout,
      env={**os.environ, "LC_ALL": "C"},
    )
  except (OSError, subprocess.TimeoutExpired) as exc:
    return 1, "", clean_str(str(exc), 300)
  return proc.returncode, proc.stdout, proc.stderr


def connect_cups():
  if cups is None:
    raise RuntimeError("python-pycups is not installed.")
  return cups.Connection()


def parse_lpoptions_list(printer_name):
  rc, out, _ = run_cmd(["lpoptions", "-p", printer_name, "-l"], timeout=5)
  if rc != 0 or not out:
    return {}
  parsed = {}
  for line in out.splitlines():
    if ":" not in line:
      continue
    left, right = line.split(":", 1)
    if "/" in left:
      key, label = left.split("/", 1)
    else:
      key, label = left, left
    key = clean_str(key, 64)
    if not OPTION_KEY_RE.match(key):
      continue
    tokens = right.strip().split()
    choices = []
    current = ""
    for tok in tokens[:MAX_OPTION_CHOICES]:
      is_default = tok.startswith("*")
      val = tok[1:] if is_default else tok
      val = clean_str(val, 128)
      if not val:
        continue
      choices.append(val)
      if is_default:
        current = val
    if choices:
      parsed[key] = {
        "key": key,
        "label": clean_str(label, 80),
        "current": current or choices[0],
        "choices": choices,
      }
  return parsed


def extract_printer_options(printer_name, attrs):
  ppd_opts = parse_lpoptions_list(printer_name)
  result = {}

  def pick_opt(slot, candidates, ipp_default_key=None, ipp_supported_key=None):
    for key in candidates:
      if key in ppd_opts and len(ppd_opts[key]["choices"]) > 0:
        result[slot] = ppd_opts[key]
        return
    if ipp_default_key and ipp_supported_key:
      supported = attrs.get(ipp_supported_key)
      default_val = attrs.get(ipp_default_key)
      if isinstance(supported, (list, tuple)) and len(supported) > 0:
        choices = [clean_str(x, 128) for x in supported[:MAX_OPTION_CHOICES] if clean_str(x, 128)]
        if choices:
          cur = clean_str(default_val, 128) if default_val is not None else choices[0]
          result[slot] = {
            "key": ipp_default_key.replace("-default", ""),
            "label": slot,
            "current": cur if cur in choices else choices[0],
            "choices": choices,
          }

  pick_opt("paperSize", ("PageSize", "MediaSize"), "media-default", "media-supported")
  pick_opt("colorMode", ("Ink", "ColorModel", "CNColorMode", "BRMonoColor"), "print-color-mode-default", "print-color-mode-supported")
  pick_opt("quality", ("MediaType", "cupsPrintQuality", "PrintQuality", "Resolution"), "print-quality-default", "print-quality-supported")
  pick_opt("duplex", ("Duplex", "EFDuplex", "JCLDuplex"), "sides-default", "sides-supported")
  return result


def extract_markers(attrs):
  names = attrs.get("marker-names")
  levels = attrs.get("marker-levels")
  colors = attrs.get("marker-colors")
  types = attrs.get("marker-types")
  if not isinstance(names, (list, tuple)) or not isinstance(levels, (list, tuple)):
    return []
  markers = []
  for idx in range(min(len(names), len(levels), 12)):
    try:
      level = int(levels[idx])
    except (TypeError, ValueError):
      level = -1
    if level < -3 or level > 100:
      level = -1
    color = clean_str(colors[idx], 32) if isinstance(colors, (list, tuple)) and idx < len(colors) else ""
    if color and not re.match(r"^#[0-9A-Fa-f]{6}$", color):
      color = ""
    markers.append({
      "name": clean_str(names[idx], 64) or f"Marker {idx + 1}",
      "level": level,
      "color": color,
      "type": clean_str(types[idx], 40) if isinstance(types, (list, tuple)) and idx < len(types) else "",
    })
  return markers


def normalize_list(val):
  if isinstance(val, (list, tuple)):
    return [clean_str(x, 80) for x in val if clean_str(x, 80)]
  s = clean_str(val, 80)
  return [s] if s and s.lower() != "none" else []


def detect_maintenance_capabilities(attrs, info):
  formats = set(f.lower() for f in normalize_list(attrs.get("document-format-supported", [])))
  commands = set(c.lower() for c in normalize_list(attrs.get("printer-commands", [])))
  make_model = clean_str(attrs.get("printer-make-and-model", info.get("printer-make-and-model", "")), 160).lower()
  uri = clean_str(attrs.get("device-uri", info.get("device-uri", "")), MAX_URI_LEN).lower()
  p_info = clean_str(attrs.get("printer-info", info.get("printer-info", "")), 140).lower()

  supports_cups_cmd = "application/vnd.cups-command" in formats and len(commands) > 0
  if supports_cups_cmd:
    has_clean = "clean" in commands
    has_nozzle = "printselftestpage" in commands
    has_align = "printalignmentpage" in commands or "setalignment" in commands
    has_levels = "reportlevels" in commands
    has_auto = "autoconfigure" in commands
    if has_clean or has_nozzle or has_align or has_levels or has_auto:
      return {
        "backend": "cups-command",
        "cleanHeads": has_clean,
        "nozzleCheck": has_nozzle,
        "alignment": has_align,
        "reportLevels": has_levels,
        "autoConfigure": has_auto,
      }

  is_epson = any(tok in (make_model + " " + uri + " " + p_info) for tok in ("epson", "escpr", "esc/p"))
  supports_raw = "application/vnd.cups-raw" in formats or "application/octet-stream" in formats
  if is_epson and supports_raw and COMMANDTOESCPX_PATH.is_file() and os.access(COMMANDTOESCPX_PATH, os.X_OK):
    return {
      "backend": "escpx-raw",
      "cleanHeads": True,
      "nozzleCheck": True,
      "alignment": True,
      "reportLevels": True,
      "autoConfigure": False,
    }

  is_hp = any(tok in (make_model + " " + uri) for tok in ("hp", "hewlett-packard", "hplip"))
  if is_hp and (shutil.which("hp-clean") or shutil.which("hp-align") or shutil.which("hp-levels")):
    return {
      "backend": "hplip",
      "cleanHeads": shutil.which("hp-clean") is not None,
      "nozzleCheck": False,
      "alignment": shutil.which("hp-align") is not None,
      "reportLevels": shutil.which("hp-levels") is not None,
      "autoConfigure": False,
    }

  return {
    "backend": "none",
    "cleanHeads": False,
    "nozzleCheck": False,
    "alignment": False,
    "reportLevels": False,
    "autoConfigure": False,
  }


def classify_reasons(reasons, state_num):
  cleaned = []
  for item in (reasons or []):
    r = clean_str(item, 80)
    if r and r.lower() != "none":
      cleaned.append(r)
  has_error = state_num == 5
  has_warning = False
  for reason in cleaned:
    low = reason.lower()
    if low in BENIGN_REASONS:
      continue
    if any(h in low for h in ERROR_REASON_HINTS) or low.endswith("-error"):
      has_error = True
    elif any(h in low for h in WARNING_REASON_HINTS) or low.endswith("-warning"):
      has_warning = True
  return cleaned[:10], has_error, has_warning


def printer_name_from_uri(uri):
  text = str(uri or "").rstrip("/")
  if "/" in text:
    return clean_str(text.rsplit("/", 1)[-1], 128)
  return clean_str(text, 128)


def build_job_record(jid, attrs):
  state_num = int(attrs.get("job-state", 0) or 0)
  state_key = JOB_STATE_MAP.get(state_num, "unknown")
  is_active = state_num in (3, 4, 5, 6)
  reasons_raw = attrs.get("job-state-reasons", "")
  if isinstance(reasons_raw, (list, tuple)):
    reasons = [clean_str(r, 80) for r in reasons_raw[:6] if clean_str(r, 80)]
  else:
    r = clean_str(reasons_raw, 80)
    reasons = [r] if r and r != "none" else []
  copies = int(attrs.get("copies", 1) or 1)
  if copies < 1 or copies > 9999:
    copies = 1
  size_kb = int(attrs.get("job-k-octets", 0) or 0)
  if size_kb < 0:
    size_kb = 0
  return {
    "id": int(jid),
    "title": clean_str(attrs.get("job-name", ""), 140),
    "printer": printer_name_from_uri(attrs.get("job-printer-uri", "")),
    "user": clean_str(attrs.get("job-originating-user-name", ""), 64),
    "state": state_num,
    "stateKey": state_key,
    "stateReasons": reasons,
    "copies": copies,
    "sizeKb": size_kb,
    "pagesCompleted": max(0, int(attrs.get("job-impressions-completed", 0) or 0)),
    "createdAt": max(0, int(attrs.get("time-at-creation", 0) or 0)),
    "completedAt": max(0, int(attrs.get("time-at-completed", 0) or 0)),
    "documentFormat": clean_str(attrs.get("document-format", ""), 64),
    "isActive": is_active,
    "canHold": state_num in (3, 5),
    "canRelease": state_num == 4,
    "canRestart": state_num in (6, 7, 8, 9),
  }


def cmd_status(args):
  max_history = max(5, min(50, int(args.max_history or 20)))
  system_config_installed = shutil.which("system-config-printer") is not None

  try:
    conn = connect_cups()
    raw_printers = conn.getPrinters()
    default_printer = clean_str(conn.getDefault() or "", 128)
    raw_active_jobs = conn.getJobs(which_jobs="not-completed", my_jobs=False)
    raw_completed_jobs = (
      conn.getJobs(which_jobs="completed", my_jobs=False)
      if args.include_completed and not args.status_only
      else {}
    )
    try:
      raw_server = conn.adminGetServerSettings()
    except Exception:
      raw_server = {}
  except Exception as exc:
    emit({
      "ok": True,
      "cupsRunning": False,
      "systemConfigInstalled": system_config_installed,
      "defaultPrinter": "",
      "printers": [],
      "jobs": [],
      "completedJobs": [],
      "activeJobCount": 0,
      "serverSettings": {
        "sharePrinters": False,
        "userCancelAny": False,
        "webInterface": True,
      },
      "statusOnly": bool(args.status_only),
      "warning": clean_str(str(exc), 200),
    })

  active_jobs = []
  active_count_by_printer = {}
  for jid in sorted(raw_active_jobs.keys(), reverse=True)[:MAX_JOBS]:
    try:
      j_attrs = conn.getJobAttributes(jid)
    except Exception:
      j_attrs = raw_active_jobs.get(jid) or {}
    rec = build_job_record(jid, j_attrs)
    active_jobs.append(rec)
    p = rec["printer"]
    if p:
      active_count_by_printer[p] = active_count_by_printer.get(p, 0) + 1

  completed_jobs = []
  if raw_completed_jobs:
    for jid in sorted(raw_completed_jobs.keys(), reverse=True)[:max_history]:
      try:
        j_attrs = conn.getJobAttributes(jid)
      except Exception:
        j_attrs = raw_completed_jobs.get(jid) or {}
      completed_jobs.append(build_job_record(jid, j_attrs))

  printers = []
  for name in sorted(raw_printers.keys(), key=lambda n: (n != default_printer, n.lower()))[:MAX_PRINTERS]:
    info = raw_printers.get(name) or {}
    try:
      attrs = conn.getPrinterAttributes(name)
    except Exception:
      attrs = {}
    state_num = int(attrs.get("printer-state", info.get("printer-state", 0)) or 0)
    state_key = PRINTER_STATE_MAP.get(state_num, "unknown")
    reasons, has_error, has_warning = classify_reasons(
      attrs.get("printer-state-reasons", info.get("printer-state-reasons", [])),
      state_num,
    )
    accepting = bool(attrs.get("printer-is-accepting-jobs", True))
    if not accepting:
      has_warning = True
    error_policy = clean_str(attrs.get("printer-error-policy", "stop-printer"), 40)
    if error_policy not in ALLOWED_ERROR_POLICIES:
      error_policy = "stop-printer"
    printers.append({
      "name": clean_str(name, 128),
      "info": clean_str(attrs.get("printer-info", info.get("printer-info", name)), 140) or clean_str(name, 128),
      "location": clean_str(attrs.get("printer-location", info.get("printer-location", "")), 140),
      "makeModel": clean_str(attrs.get("printer-make-and-model", info.get("printer-make-and-model", "")), 160),
      "deviceUri": clean_str(attrs.get("device-uri", info.get("device-uri", "")), MAX_URI_LEN),
      "isDefault": name == default_printer,
      "state": state_num,
      "stateKey": state_key,
      "stateMessage": clean_str(attrs.get("printer-state-message", info.get("printer-state-message", "")), 200),
      "stateReasons": reasons,
      "hasError": has_error,
      "hasWarning": has_warning,
      "acceptingJobs": accepting,
      "shared": bool(attrs.get("printer-is-shared", info.get("printer-is-shared", False))),
      "errorPolicy": error_policy,
      "activeJobCount": active_count_by_printer.get(name, 0),
      "markers": extract_markers(attrs),
      "options": {} if args.status_only else extract_printer_options(name, attrs),
      "maintenance": detect_maintenance_capabilities(attrs, info),
    })

  def server_bool(key, default=False):
    val = str(raw_server.get(key, "")).strip().lower()
    if val in ("1", "yes", "true", "on"):
      return True
    if val in ("0", "no", "false", "off"):
      return False
    return default

  emit({
    "ok": True,
    "cupsRunning": True,
    "systemConfigInstalled": system_config_installed,
    "defaultPrinter": default_printer,
    "printers": printers,
    "jobs": active_jobs,
    "completedJobs": completed_jobs,
    "activeJobCount": len(active_jobs),
    "serverSettings": {
      "sharePrinters": server_bool("_share_printers", False),
      "userCancelAny": server_bool("_user_cancel_any", False),
      "webInterface": server_bool("WebInterface", True),
    },
    "statusOnly": bool(args.status_only),
    "warning": "",
  })


def uri_priority(uri):
  low = uri.lower()
  if low.startswith("ipps://"):
    return 0
  if low.startswith("ipp://"):
    return 1
  if low.startswith("usb://"):
    return 2
  if low.startswith("dnssd://"):
    return 3
  if low.startswith("socket://"):
    return 4
  return 5


def is_driverless_device(uri, dev):
  low = uri.lower()
  info = str(dev.get("device-info", "")).lower()
  dev_id = str(dev.get("device-id", "")).upper()
  if low.startswith(("ipps://", "ipp://")):
    return True
  if "driverless" in info:
    return True
  if any(tok in dev_id for tok in ("PWGRaster".upper(), "URF", "APPLERASTER", "PDF")):
    return True
  return False


def cmd_discover(args):
  timeout = max(1, min(10, int(args.timeout or 4)))
  try:
    conn = connect_cups()
    existing = conn.getPrinters()
    existing_uris = {str(p.get("device-uri", "")).strip() for p in existing.values()}
    existing_names = set(existing.keys())
    raw_devices = conn.getDevices(timeout=timeout)
  except Exception as exc:
    emit({"ok": False, "error": clean_str(str(exc), 200), "devices": []}, 1)

  # Deduplicate network advertisements of the same physical printer (preferring ipps/ipp driverless).
  grouped = {}
  for uri, dev in raw_devices.items():
    uri_clean = clean_str(uri, MAX_URI_LEN)
    if not uri_clean or uri_clean.lower() in GENERIC_DEVICE_SCHEMES or "://" not in uri_clean:
      continue
    if not any(uri_clean.lower().startswith(s) for s in ALLOWED_URI_SCHEMES):
      continue
    info = clean_str(dev.get("device-info", ""), 140)
    model = clean_str(dev.get("device-make-and-model", ""), 160)
    dev_class = clean_str(dev.get("device-class", "network"), 32)
    base_title = re.sub(r"\s*\(driverless\)\s*$", "", info, flags=re.IGNORECASE).strip() or model or uri_clean
    dedupe_key = (dev_class.lower(), base_title.lower())
    candidate = {
      "uri": uri_clean,
      "info": base_title,
      "makeModel": model if model.lower() != "unknown" else base_title,
      "deviceClass": dev_class,
      "driverless": is_driverless_device(uri_clean, dev),
      "alreadyConfigured": uri_clean in existing_uris,
      "suggestedName": sanitize_queue_name(base_title),
      "_prio": uri_priority(uri_clean),
    }
    prev = grouped.get(dedupe_key)
    if prev is None or (candidate["alreadyConfigured"] and not prev["alreadyConfigured"]) or (
      candidate["alreadyConfigured"] == prev["alreadyConfigured"] and candidate["_prio"] < prev["_prio"]
    ):
      grouped[dedupe_key] = candidate

  devices = []
  for item in sorted(grouped.values(), key=lambda d: (d["alreadyConfigured"], d["_prio"], d["info"].lower()))[:MAX_DISCOVERED]:
    suggested = item["suggestedName"]
    if not item["alreadyConfigured"] and suggested in existing_names:
      suffix = 2
      while f"{suggested}-{suffix}" in existing_names and suffix < 99:
        suffix += 1
      suggested = f"{suggested}-{suffix}"
    item["suggestedName"] = suggested
    item.pop("_prio", None)
    devices.append(item)

  emit({"ok": True, "devices": devices})


def cmd_recent_files(args):
  limit = max(1, min(20, int(args.limit or 10)))
  home = Path.home()
  roots = [
    home / "Downloads",
    home / "Documents",
    home / "Documentos",
    home / "Desktop",
    home / "Área de trabalho",
  ]
  seen_dirs = set()
  heap = []
  counter = 0
  scanned = 0
  for base in roots:
    try:
      resolved = base.resolve()
    except OSError:
      continue
    if not resolved.is_dir() or str(resolved) in seen_dirs:
      continue
    seen_dirs.add(str(resolved))
    for root, dirs, files in os.walk(resolved):
      rel_depth = Path(root).relative_to(resolved).parts
      if len(rel_depth) >= 1:
        dirs[:] = []
      else:
        dirs[:] = [d for d in dirs if not d.startswith(".") and not os.path.islink(os.path.join(root, d))][:20]
      for fname in files:
        if scanned >= 400:
          break
        scanned += 1
        if fname.startswith("."):
          continue
        ext = Path(fname).suffix.lower()
        if ext not in PRINTABLE_EXTENSIONS:
          continue
        full = os.path.join(root, fname)
        if os.path.islink(full):
          continue
        try:
          st = os.stat(full)
        except OSError:
          continue
        if not os.path.isfile(full) or st.st_size <= 0 or st.st_size > 200 * 1024 * 1024:
          continue
        counter += 1
        entry = (
          int(st.st_mtime),
          counter,
          {
            "name": clean_str(fname, 120),
            "path": clean_str(full, 400),
            "folder": clean_str(base.name, 48),
            "sizeKb": max(1, int((st.st_size + 1023) // 1024)),
            "modifiedAt": int(st.st_mtime),
          },
        )
        if len(heap) < limit:
          heapq.heappush(heap, entry)
        else:
          heapq.heappushpop(heap, entry)

  files_out = [entry[2] for entry in sorted(heap, reverse=True)]
  emit({"ok": True, "files": files_out})


def cmd_printer_simple(args, op):
  try:
    printer = validate_printer_name(args.printer)
    conn = connect_cups()
    if op == "set-default":
      conn.setDefault(printer)
    elif op == "enable":
      conn.enablePrinter(printer)
    elif op == "disable":
      reason = clean_str(getattr(args, "reason", ""), 140)
      if reason:
        conn.disablePrinter(printer, reason=reason)
      else:
        conn.disablePrinter(printer)
    elif op == "accept":
      conn.acceptJobs(printer)
    elif op == "reject":
      reason = clean_str(getattr(args, "reason", ""), 140)
      if reason:
        conn.rejectJobs(printer, reason=reason)
      else:
        conn.rejectJobs(printer)
    elif op == "set-shared":
      shared = parse_bool_flag(args.value)
      conn.setPrinterShared(printer, shared)
    elif op == "delete-printer":
      conn.deletePrinter(printer)
    elif op == "cancel-all":
      conn.cancelAllJobs(printer)
    emit({"ok": True, "action": op, "printer": printer})
  except Exception as exc:
    emit({"ok": False, "action": op, "error": clean_str(str(exc), 200)}, 1)


def cmd_cancel_all_global(_args):
  try:
    conn = connect_cups()
    printers = conn.getPrinters()
    for name in printers:
      try:
        conn.cancelAllJobs(name)
      except Exception:
        pass
    emit({"ok": True, "action": "cancel-all"})
  except Exception as exc:
    emit({"ok": False, "action": "cancel-all", "error": clean_str(str(exc), 200)}, 1)


def cmd_test_page(args):
  try:
    printer = validate_printer_name(args.printer)
    conn = connect_cups()
    testprint = Path("/usr/share/cups/data/testprint")
    bannertopdf = Path("/usr/lib/cups/filter/bannertopdf")
    default_pdf = Path("/usr/share/cups/data/default-testpage.pdf")
    if testprint.is_file() and bannertopdf.is_file():
      job_id = conn.printFile(printer, str(testprint), "Test Page", {})
    elif default_pdf.is_file():
      job_id = conn.printFile(printer, str(default_pdf), "Test Page", {})
    else:
      job_id = conn.printTestPage(printer)
    emit({"ok": True, "action": "test-page", "printer": printer, "jobId": int(job_id or 0)})
  except Exception as exc:
    emit({"ok": False, "action": "test-page", "error": clean_str(str(exc), 200)}, 1)


def cmd_print_file(args):
  try:
    printer = validate_printer_name(args.printer)
    raw_path = os.path.expanduser(str(args.path or "").strip())
    if not raw_path:
      raise ValueError("File path is required.")
    file_path = Path(raw_path).resolve()
    if not file_path.is_file():
      raise ValueError("File not found.")
    if not os.access(file_path, os.R_OK):
      raise ValueError("File is not readable.")
    copies = max(1, min(99, int(args.copies or 1)))
    title = clean_str(args.title or file_path.name, 140) or "Document"
    conn = connect_cups()
    options = {"copies": str(copies)} if copies > 1 else {}
    job_id = conn.printFile(printer, str(file_path), title, options)
    emit({
      "ok": True,
      "action": "print-file",
      "printer": printer,
      "title": title,
      "jobId": int(job_id or 0),
    })
  except Exception as exc:
    emit({"ok": False, "action": "print-file", "error": clean_str(str(exc), 200)}, 1)


def cmd_set_option(args):
  try:
    printer = validate_printer_name(args.printer)
    key = str(args.key or "").strip()
    val = str(args.value or "").strip()
    if not OPTION_KEY_RE.match(key):
      raise ValueError("Invalid option key.")
    if not OPTION_VAL_RE.match(val):
      raise ValueError("Invalid option value.")
    rc, _, err = run_cmd(["lpadmin", "-p", printer, "-o", f"{key}-default={val}"], timeout=10)
    if rc != 0:
      conn = connect_cups()
      conn.addPrinterOptionDefault(printer, key, val)
    emit({"ok": True, "action": "set-option", "printer": printer, "key": key, "value": val})
  except Exception as exc:
    emit({"ok": False, "action": "set-option", "error": clean_str(str(exc), 200)}, 1)


def cmd_update_printer(args):
  try:
    printer = validate_printer_name(args.printer)
    conn = connect_cups()
    if args.info is not None:
      conn.setPrinterInfo(printer, clean_str(args.info, 140))
    if args.location is not None:
      conn.setPrinterLocation(printer, clean_str(args.location, 140))
    if args.error_policy is not None:
      policy = str(args.error_policy).strip()
      if policy not in ALLOWED_ERROR_POLICIES:
        raise ValueError("Unsupported error policy.")
      conn.setPrinterErrorPolicy(printer, policy)
    emit({"ok": True, "action": "update-printer", "printer": printer})
  except Exception as exc:
    emit({"ok": False, "action": "update-printer", "error": clean_str(str(exc), 200)}, 1)


def pick_best_ppd(conn, make_model):
  query = clean_str(make_model, 120)
  if not query:
    return ""
  try:
    ppds = conn.getPPDs(ppd_make_and_model=query)
    if ppds:
      return sorted(ppds.keys())[0]
  except Exception:
    pass
  parts = query.split()
  if parts:
    try:
      ppds = conn.getPPDs(ppd_make=parts[0])
      for ppd_name, meta in ppds.items():
        mm = str(meta.get("ppd-make-and-model", "")).lower()
        if all(tok.lower() in mm for tok in parts[:2]):
          return ppd_name
    except Exception:
      pass
  return ""


def cmd_add_printer(args):
  try:
    name = validate_printer_name(args.name)
    uri = validate_uri(args.uri)
    info = clean_str(args.info or name, 140)
    location = clean_str(args.location or "", 140)
    model_mode = str(args.model or "auto").strip().lower()
    conn = connect_cups()

    use_everywhere = model_mode == "everywhere" or (
      model_mode == "auto" and uri.lower().startswith(("ipp://", "ipps://"))
    )

    if use_everywhere:
      cmd = ["lpadmin", "-p", name, "-E", "-v", uri, "-m", "everywhere", "-D", info]
      if location:
        cmd.extend(["-L", location])
      rc, _, err = run_cmd(cmd, timeout=20)
      if rc != 0:
        raise RuntimeError(clean_str(err or "lpadmin failed to configure IPP Everywhere printer.", 200))
    else:
      ppd = pick_best_ppd(conn, args.make_model or info) if model_mode == "auto" else ""
      if ppd:
        conn.addPrinter(name, device=uri, ppdname=ppd, info=info, location=location)
      else:
        # Try IPP Everywhere first, then fall back to generic IPP/PDF PPD via lpadmin.
        cmd = ["lpadmin", "-p", name, "-E", "-v", uri, "-m", "everywhere", "-D", info]
        if location:
          cmd.extend(["-L", location])
        rc, _, err = run_cmd(cmd, timeout=20)
        if rc != 0:
          conn.addPrinter(name, device=uri, info=info, location=location)
      conn.enablePrinter(name)
      conn.acceptJobs(name)

    if args.set_default:
      conn.setDefault(name)

    emit({"ok": True, "action": "add-printer", "printer": name})
  except Exception as exc:
    emit({"ok": False, "action": "add-printer", "error": clean_str(str(exc), 200)}, 1)


def cmd_job_action(args, op):
  try:
    jid = validate_job_id(args.job_id)
    conn = connect_cups()
    if op == "cancel-job":
      conn.cancelJob(jid)
    elif op == "hold-job":
      conn.setJobHoldUntil(jid, "indefinite")
    elif op == "release-job":
      conn.setJobHoldUntil(jid, "no-hold")
    elif op == "restart-job":
      conn.restartJob(jid)
    elif op == "move-job":
      dest = validate_printer_name(args.dest)
      conn.moveJob(job_id=jid, printer_uri=f"ipp://localhost/printers/{dest}")
      emit({"ok": True, "action": op, "jobId": jid, "dest": dest})
    emit({"ok": True, "action": op, "jobId": jid})
  except Exception as exc:
    emit({"ok": False, "action": op, "error": clean_str(str(exc), 200)}, 1)


def cmd_server_setting(args):
  try:
    key = str(args.key or "").strip()
    if key not in ALLOWED_SERVER_BOOL_KEYS:
      raise ValueError("Unsupported server setting key.")
    enabled = parse_bool_flag(args.value)
    conn = connect_cups()
    settings = conn.adminGetServerSettings()
    if key == "WebInterface":
      settings[key] = "Yes" if enabled else "No"
    else:
      settings[key] = "1" if enabled else "0"
    conn.adminSetServerSettings(settings)
    emit({"ok": True, "action": "set-server-setting", "key": key, "value": enabled})
  except Exception as exc:
    emit({"ok": False, "action": "set-server-setting", "error": clean_str(str(exc), 200)}, 1)


def build_cups_command_text(action, align_pass=0, align_value=0):
  if action == "clean-heads":
    return "Clean all", "Clean Print Heads"
  if action == "nozzle-check":
    return "PrintSelfTestPage", "Nozzle Check"
  if action == "print-alignment":
    if align_pass > 0:
      return f"PrintAlignmentPage {align_pass}", f"Head Alignment Pass {align_pass}"
    return "PrintAlignmentPage", "Head Alignment Page"
  if action == "set-alignment":
    return f"SetAlignment {align_pass} {align_value}", f"Set Alignment {align_pass}={align_value}"
  if action == "report-levels":
    return "ReportLevels", "Report Ink Levels"
  if action == "auto-configure":
    return "AutoConfigure", "Auto Configure Printer"
  raise ValueError("Unsupported maintenance action.")


def synthesize_escpx_payload(conn, printer, cmd_line):
  if not COMMANDTOESCPX_PATH.is_file() or not os.access(COMMANDTOESCPX_PATH, os.X_OK):
    raise RuntimeError("CUPS commandtoescpx filter is not installed.")
  ppd_path = None
  try:
    ppd_path = conn.getPPD(printer)
    env = {**os.environ, "PPD": ppd_path, "LC_ALL": "C"}
    proc = subprocess.run(
      [str(COMMANDTOESCPX_PATH), "1", cups.getUser() or "user", "Maintenance", "1", ""],
      input=f"#CUPS-COMMAND\n{cmd_line}\n".encode("ascii"),
      capture_output=True,
      timeout=10,
      check=False,
      env=env,
    )
    if proc.returncode != 0 or not proc.stdout:
      err = clean_str(proc.stderr.decode("utf-8", errors="replace"), 180)
      raise RuntimeError(err or "Failed to generate ESC/P-X maintenance command.")
    return proc.stdout
  finally:
    if ppd_path and os.path.exists(ppd_path):
      try:
        os.unlink(ppd_path)
      except OSError:
        pass


def cmd_maintenance(args):
  try:
    printer = validate_printer_name(args.printer)
    action = str(args.action or "").strip().lower()
    if action not in ALLOWED_MAINTENANCE_ACTIONS:
      raise ValueError("Unsupported maintenance action.")

    align_pass = int(args.align_pass or 0)
    align_value = int(args.align_value or 0)
    if action == "print-alignment" and (align_pass < 0 or align_pass > 4):
      raise ValueError("Alignment pass must be between 0 and 4.")
    if action == "set-alignment":
      if align_pass < 1 or align_pass > 4:
        raise ValueError("Alignment pass must be between 1 and 4.")
      if align_value < 1 or align_value > 15:
        raise ValueError("Alignment value must be between 1 and 15.")

    conn = connect_cups()
    printers = conn.getPrinters()
    if printer not in printers:
      raise ValueError("Printer not found.")
    info = printers[printer] or {}
    attrs = conn.getPrinterAttributes(printer)
    caps = detect_maintenance_capabilities(attrs, info)
    backend = caps["backend"]

    cap_map = {
      "clean-heads": "cleanHeads",
      "nozzle-check": "nozzleCheck",
      "print-alignment": "alignment",
      "set-alignment": "alignment",
      "report-levels": "reportLevels",
      "auto-configure": "autoConfigure",
    }
    if backend == "none" or not caps.get(cap_map[action], False):
      raise RuntimeError("This printer driver does not support the requested maintenance command.")

    cmd_line, title = build_cups_command_text(action, align_pass, align_value)

    if backend == "cups-command":
      payload = f"#CUPS-COMMAND\n{cmd_line}\n".encode("ascii")
      if args.dry_run:
        emit({
          "ok": True,
          "action": "maintenance",
          "maintenanceAction": action,
          "printer": printer,
          "backend": backend,
          "dryRun": True,
          "bytes": len(payload),
        })
      tmp_path = None
      try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix="cups-maint-", delete=False) as tf:
          tf.write(payload)
          tmp_path = tf.name
        job_id = conn.printFile(printer, tmp_path, title, {"document-format": "application/vnd.cups-command"})
      finally:
        if tmp_path and os.path.exists(tmp_path):
          os.unlink(tmp_path)
      emit({
        "ok": True,
        "action": "maintenance",
        "maintenanceAction": action,
        "printer": printer,
        "backend": backend,
        "jobId": int(job_id or 0),
      })

    if backend == "escpx-raw":
      payload = synthesize_escpx_payload(conn, printer, cmd_line)
      if args.dry_run:
        emit({
          "ok": True,
          "action": "maintenance",
          "maintenanceAction": action,
          "printer": printer,
          "backend": backend,
          "dryRun": True,
          "bytes": len(payload),
        })
      tmp_path = None
      try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix="escpx-maint-", delete=False) as tf:
          tf.write(payload)
          tmp_path = tf.name
        job_id = conn.printFile(printer, tmp_path, title, {"document-format": "application/vnd.cups-raw"})
      finally:
        if tmp_path and os.path.exists(tmp_path):
          os.unlink(tmp_path)
      emit({
        "ok": True,
        "action": "maintenance",
        "maintenanceAction": action,
        "printer": printer,
        "backend": backend,
        "jobId": int(job_id or 0),
      })

    if backend == "hplip":
      tool_map = {
        "clean-heads": ["hp-clean", "-p", printer, "-n"],
        "print-alignment": ["hp-align", "-p", printer, "-n"],
        "report-levels": ["hp-levels", "-p", printer],
      }
      argv = tool_map.get(action)
      if not argv or not shutil.which(argv[0]):
        raise RuntimeError("HPLIP tool not available for this action.")
      if args.dry_run:
        emit({
          "ok": True,
          "action": "maintenance",
          "maintenanceAction": action,
          "printer": printer,
          "backend": backend,
          "dryRun": True,
        })
      rc, _, err = run_cmd(argv, timeout=30)
      if rc != 0:
        raise RuntimeError(clean_str(err or "HPLIP maintenance command failed.", 180))
      emit({
        "ok": True,
        "action": "maintenance",
        "maintenanceAction": action,
        "printer": printer,
        "backend": backend,
        "jobId": 0,
      })

    raise RuntimeError("Unsupported maintenance backend.")
  except Exception as exc:
    emit({"ok": False, "action": "maintenance", "error": clean_str(str(exc), 200)}, 1)


def cmd_service_control(action):
  if action not in ("start", "restart"):
    emit({"ok": False, "error": "Unsupported service action."}, 1)
  pkexec = shutil.which("pkexec")
  systemctl = shutil.which("systemctl")
  if not systemctl:
    emit({"ok": False, "error": "systemctl not found."}, 1)
  argv = [pkexec, systemctl, action, "cups.service"] if pkexec else [systemctl, action, "cups.service"]
  rc, _, err = run_cmd(argv, timeout=30)
  if rc != 0:
    emit({"ok": False, "action": f"{action}-cups", "error": clean_str(err or "Failed to control cups.service.", 200)}, 1)
  emit({"ok": True, "action": f"{action}-cups"})


def build_parser():
  parser = argparse.ArgumentParser(prog="cups_ctl.py")
  sub = parser.add_subparsers(dest="command", required=True)

  p_status = sub.add_parser("status")
  p_status.add_argument("--include-completed", action="store_true")
  p_status.add_argument("--max-history", type=int, default=20)
  p_status.add_argument("--status-only", action="store_true")

  p_discover = sub.add_parser("discover")
  p_discover.add_argument("--timeout", type=int, default=4)

  p_recent = sub.add_parser("recent-files")
  p_recent.add_argument("--limit", type=int, default=10)

  for name in ("set-default", "enable", "accept", "delete-printer", "test-page"):
    p = sub.add_parser(name)
    p.add_argument("printer")

  for name in ("disable", "reject"):
    p = sub.add_parser(name)
    p.add_argument("printer")
    p.add_argument("--reason", default="")

  p_shared = sub.add_parser("set-shared")
  p_shared.add_argument("printer")
  p_shared.add_argument("value")

  p_cancel_all = sub.add_parser("cancel-all")
  p_cancel_all.add_argument("printer", nargs="?", default="")

  p_print = sub.add_parser("print-file")
  p_print.add_argument("printer")
  p_print.add_argument("path")
  p_print.add_argument("--copies", type=int, default=1)
  p_print.add_argument("--title", default="")

  p_opt = sub.add_parser("set-option")
  p_opt.add_argument("printer")
  p_opt.add_argument("key")
  p_opt.add_argument("value")

  p_upd = sub.add_parser("update-printer")
  p_upd.add_argument("printer")
  p_upd.add_argument("--info", default=None)
  p_upd.add_argument("--location", default=None)
  p_upd.add_argument("--error-policy", default=None)

  p_add = sub.add_parser("add-printer")
  p_add.add_argument("name")
  p_add.add_argument("uri")
  p_add.add_argument("--info", default="")
  p_add.add_argument("--location", default="")
  p_add.add_argument("--make-model", default="")
  p_add.add_argument("--model", default="auto", choices=["auto", "everywhere", "raw"])
  p_add.add_argument("--set-default", action="store_true")

  for name in ("cancel-job", "hold-job", "release-job", "restart-job"):
    p = sub.add_parser(name)
    p.add_argument("job_id")

  p_move = sub.add_parser("move-job")
  p_move.add_argument("job_id")
  p_move.add_argument("dest")

  p_srv = sub.add_parser("set-server-setting")
  p_srv.add_argument("key")
  p_srv.add_argument("value")

  p_maint = sub.add_parser("maintenance")
  p_maint.add_argument("printer")
  p_maint.add_argument("action")
  p_maint.add_argument("--align-pass", type=int, default=0)
  p_maint.add_argument("--align-value", type=int, default=0)
  p_maint.add_argument("--dry-run", action="store_true")

  sub.add_parser("start-cups")
  sub.add_parser("restart-cups")
  return parser


def main():
  parser = build_parser()
  args = parser.parse_args()
  cmd = args.command

  if cmd == "status":
    cmd_status(args)
  elif cmd == "discover":
    cmd_discover(args)
  elif cmd == "recent-files":
    cmd_recent_files(args)
  elif cmd in ("set-default", "enable", "disable", "accept", "reject", "set-shared", "delete-printer"):
    cmd_printer_simple(args, cmd)
  elif cmd == "cancel-all":
    if args.printer:
      cmd_printer_simple(args, "cancel-all")
    else:
      cmd_cancel_all_global(args)
  elif cmd == "test-page":
    cmd_test_page(args)
  elif cmd == "print-file":
    cmd_print_file(args)
  elif cmd == "set-option":
    cmd_set_option(args)
  elif cmd == "update-printer":
    cmd_update_printer(args)
  elif cmd == "add-printer":
    cmd_add_printer(args)
  elif cmd in ("cancel-job", "hold-job", "release-job", "restart-job", "move-job"):
    cmd_job_action(args, cmd)
  elif cmd == "set-server-setting":
    cmd_server_setting(args)
  elif cmd == "maintenance":
    cmd_maintenance(args)
  elif cmd == "start-cups":
    cmd_service_control("start")
  elif cmd == "restart-cups":
    cmd_service_control("restart")
  else:
    emit({"ok": False, "error": "Unknown command."}, 1)


if __name__ == "__main__":
  main()
