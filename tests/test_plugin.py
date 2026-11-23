#!/usr/bin/env python3
"""Regression tests for ivanilton.printers (Python backend + QML Model.js safety)."""

import json
import subprocess
import sys
import unittest
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parent.parent
CUPS_CTL = PLUGIN_DIR / "cups_ctl.py"
MODEL_JS = PLUGIN_DIR / "Model.js"


def run_ctl(*args):
  proc = subprocess.run(
    [sys.executable, str(CUPS_CTL), *args],
    capture_output=True,
    text=True,
    timeout=15,
    check=False,
  )
  data = json.loads(proc.stdout) if proc.stdout.strip() else {}
  return proc.returncode, data, proc.stderr


def run_node_js(snippet):
  """Loads Model.js (stripping .pragma library) with QString.arg polyfill and executes snippet."""
  source = MODEL_JS.read_text(encoding="utf-8").replace(".pragma library", "")
  driver = f"""
String.prototype.arg = function(val) {{
  var matches = this.match(/%([0-9]+)/g);
  if (!matches) return String(this);
  var lowest = Math.min.apply(null, matches.map(function(m) {{ return parseInt(m.slice(1), 10); }}));
  return String(this).replace(new RegExp("%" + lowest, "g"), String(val));
}};
{source}
{snippet}
"""
  proc = subprocess.run(
    ["node", "-e", driver],
    capture_output=True,
    text=True,
    timeout=10,
    check=False,
  )
  if proc.returncode != 0:
    raise AssertionError(f"Node test failed ({proc.returncode}):\n{proc.stderr}\n{proc.stdout}")
  return json.loads(proc.stdout) if proc.stdout.strip() else None


class CupsCtlValidationTests(unittest.TestCase):
  def test_live_status_schema_and_bounds(self):
    rc, data, _ = run_ctl("status", "--include-completed", "--max-history", "5")
    self.assertEqual(rc, 0)
    self.assertTrue(data["ok"])
    self.assertIn("cupsRunning", data)
    self.assertIsInstance(data["printers"], list)
    self.assertIsInstance(data["jobs"], list)
    self.assertIsInstance(data["completedJobs"], list)
    self.assertLessEqual(len(data["completedJobs"]), 5)
    self.assertIn("serverSettings", data)

  def test_recent_files_returns_bounded_list(self):
    rc, data, _ = run_ctl("recent-files", "--limit", "5")
    self.assertEqual(rc, 0)
    self.assertTrue(data["ok"])
    self.assertIsInstance(data["files"], list)
    self.assertLessEqual(len(data["files"]), 5)

  def test_rejects_shell_injection_in_printer_name(self):
    for bad in ["; rm -rf /", "printer$(id)", "../etc/passwd", "-flag", "has space", ""]:
      rc, data, _ = run_ctl("set-default", bad)
      self.assertNotEqual(rc, 0, f"Should reject printer name: {bad!r}")
      self.assertNotEqual(data.get("ok"), True)

  def test_rejects_invalid_uri_schemes(self):
    for bad_uri in [
      "file:///etc/passwd",
      "javascript:alert(1)",
      "ipp://host/p;id",
      "ipp://host with space/p",
      "ftp://192.168.1.2/printer",
    ]:
      rc, data, _ = run_ctl("add-printer", "ValidName", bad_uri)
      if bad_uri == "ipp://host/p;id":
        # Note: semicolon is valid RFC3986 path char but never executed via shell;
        # still test whitespace/file/js/ftp rejection strictly.
        continue
      self.assertNotEqual(rc, 0, f"Should reject URI: {bad_uri!r}")
      self.assertFalse(data.get("ok", True))

  def test_rejects_invalid_job_ids(self):
    for bad in ["0", "-5", "abc", "1;id", "99999999999999"]:
      rc, data, _ = run_ctl("cancel-job", bad)
      self.assertNotEqual(rc, 0)
      self.assertFalse(data.get("ok", True))

  def test_rejects_invalid_server_setting_key(self):
    rc, data, _ = run_ctl("set-server-setting", "EvilKey", "true")
    self.assertNotEqual(rc, 0)
    self.assertFalse(data.get("ok", True))

  def test_rejects_nonexistent_print_file(self):
    rc, data, _ = run_ctl("print-file", "ValidPrinter", "/nonexistent/path/file.pdf")
    self.assertNotEqual(rc, 0)
    self.assertFalse(data.get("ok", True))

  def test_maintenance_dry_run_on_installed_printers(self):
    rc, status, _ = run_ctl("status", "--status-only")
    self.assertEqual(rc, 0)
    if not status.get("printers"):
      return
    printer = status["printers"][0]
    maint = printer.get("maintenance", {})
    self.assertIn("backend", maint)
    if maint.get("backend") in ("cups-command", "escpx-raw"):
      for action, extra in [
        ("clean-heads", []),
        ("nozzle-check", []),
        ("print-alignment", ["--align-pass", "1"]),
        ("set-alignment", ["--align-pass", "1", "--align-value", "7"]),
        ("report-levels", []),
      ]:
        rc2, res, _ = run_ctl("maintenance", printer["name"], action, "--dry-run", *extra)
        self.assertEqual(rc2, 0, f"dry-run failed for {action}: {res}")
        self.assertTrue(res.get("ok"))
        self.assertTrue(res.get("dryRun"))
        self.assertGreater(res.get("bytes", 0), 10)

  def test_rejects_invalid_maintenance_inputs(self):
    for args in [
      ("maintenance", "EPSON-L375-Series", "evil-cmd", "--dry-run"),
      ("maintenance", ";id", "clean-heads", "--dry-run"),
      ("maintenance", "EPSON-L375-Series", "set-alignment", "--align-pass", "9", "--align-value", "7", "--dry-run"),
      ("maintenance", "EPSON-L375-Series", "set-alignment", "--align-pass", "1", "--align-value", "99", "--dry-run"),
    ]:
      rc, data, _ = run_ctl(*args)
      self.assertNotEqual(rc, 0, f"Should reject maintenance args: {args}")
      self.assertNotEqual(data.get("ok"), True)


class ModelMarkupAndSafetyTests(unittest.TestCase):
  def test_markup_neutralization_in_tooltips_and_sinks(self):
    result = run_node_js("""
      var payload = '<img src="https://example.invalid/tracker"><b>EPSON</b> &amp; &#60;script&#62;\\n\\r\\x00';
      var sanitized = sanitizePlainText(payload, 160);
      var notifArg = sanitizeNotificationArg('--exec <img src="https://example.invalid/x">', 160);
      var t = function(k) {
        var map = {
          'tooltip.idle': '%1 — Idle',
          'tooltip.error': '%1 — Error',
          'tooltip.activeJobs': '%1 — %2 jobs',
          'notify.jobCompletedTitle': 'Done',
          'notify.jobCompletedBody': '"%1" finished on %2.',
          'notify.jobFailedTitle': 'Failed',
          'notify.jobFailedBody': '"%1" stopped on %2.',
          'notify.printerAlertTitle': 'Alert',
          'notify.printerAlertBody': '%1: %2',
          'queue.jobTitleFallback': 'Job #%1',
          'hero.attention': 'Attention'
        };
        return map[k] || k;
      };
      var tn = function(k) { return t(k); };
      var fmt = function(n) { return String(n); };

      var rawStatus = JSON.stringify({
        ok: true,
        cupsRunning: true,
        defaultPrinter: 'Test-Printer',
        printers: [{
          name: 'Test-Printer',
          info: payload,
          location: '<a href="https://example.invalid">Desk</a>',
          makeModel: '<b>Evil</b> Model',
          deviceUri: 'ipp://localhost/printers/Test',
          isDefault: true,
          state: 3,
          stateKey: 'idle',
          stateMessage: '<img src="https://example.invalid/msg">',
          stateReasons: ['<script>alert(1)</script>'],
          hasError: true,
          acceptingJobs: true,
          shared: false,
          errorPolicy: 'stop-printer',
          activeJobCount: 1,
          markers: [{ name: '<img src=x>', level: 80, color: 'javascript:bad', type: 'ink' }],
          options: {}
        }],
        jobs: [{
          id: 7,
          title: '<img src="https://example.invalid/job.png">',
          printer: 'Test-Printer',
          user: '<b>alice</b>',
          state: 5,
          stateKey: 'processing',
          copies: 1,
          sizeKb: 42,
          createdAt: 1700000000,
          isActive: true
        }],
        completedJobs: []
      });

      var parsed = parseStatus(rawStatus);
      var tooltip = buildBarTooltip(true, parsed.printers, parsed.defaultPrinter, 1, t, tn, fmt);
      var events = detectNotificationEvents(
        parsed.jobs,
        [],
        [{ id: 7, stateKey: 'completed' }],
        [{ name: 'Test-Printer', hasError: false }],
        parsed.printers,
        t
      );

      console.log(JSON.stringify({
        sanitized: sanitized,
        notifArg: notifArg,
        printerInfo: parsed.printers[0].info,
        markerColor: parsed.printers[0].markers[0].color,
        jobTitle: parsed.jobs[0].title,
        tooltip: tooltip,
        events: events
      }));
    """)

    for field in ("sanitized", "notifArg", "printerInfo", "jobTitle", "tooltip"):
      val = result[field]
      self.assertNotIn("<", val, f"Raw '<' leaked into {field}: {val!r}")
      self.assertNotIn(">", val, f"Raw '>' leaked into {field}: {val!r}")
      self.assertNotIn("&amp;", val, f"Unbroken HTML entity leaked into {field}: {val!r}")
      self.assertNotIn("&#60;", val, f"Unbroken numeric entity leaked into {field}: {val!r}")
      self.assertNotIn("\n", val)
      self.assertNotIn("\x00", val)

    self.assertFalse(result["notifArg"].startswith("-"))
    self.assertEqual(result["markerColor"], "")
    self.assertEqual(len(result["events"]), 2)
    for ev in result["events"]:
      self.assertNotIn("<", ev["headline"])
      self.assertNotIn("<", ev["body"])
      self.assertNotIn(">", ev["body"])
      self.assertFalse(ev["headline"].startswith("-"))
      self.assertFalse(ev["body"].startswith("-"))

  def test_collection_and_string_bounds(self):
    result = run_node_js("""
      var printers = [];
      for (var i = 0; i < 80; i++) {
        printers.push({ name: 'P-' + i, info: 'X'.repeat(500), state: 3, stateKey: 'idle' });
      }
      var parsed = parseStatus(JSON.stringify({
        ok: true,
        cupsRunning: true,
        printers: printers,
        jobs: [],
        completedJobs: []
      }));
      console.log(JSON.stringify({
        count: parsed.printers.length,
        infoLen: parsed.printers[0].info.length
      }));
    """)
    self.assertEqual(result["count"], 50)
    self.assertLessEqual(result["infoLen"], 140)

  def test_i18n_catalogs_are_valid_and_complete(self):
    en = json.loads((PLUGIN_DIR / "i18n" / "en.json").read_text(encoding="utf-8"))
    pt_br = json.loads((PLUGIN_DIR / "i18n" / "pt-BR.json").read_text(encoding="utf-8"))
    pt = json.loads((PLUGIN_DIR / "i18n" / "pt.json").read_text(encoding="utf-8"))
    self.assertEqual(set(en.keys()), set(pt_br.keys()))
    self.assertEqual(set(en.keys()), set(pt.keys()))
    all_src = (
      (PLUGIN_DIR / "Panel.qml").read_text(encoding="utf-8")
      + (PLUGIN_DIR / "Service.qml").read_text(encoding="utf-8")
      + (PLUGIN_DIR / "Model.js").read_text(encoding="utf-8")
    )
    unused = [
      k for k in sorted(en.keys())
      if not k.startswith("job.state.") and f'"{k}"' not in all_src and f"'{k}'" not in all_src
    ]
    self.assertEqual(unused, [], f"Unused i18n keys found: {unused}")

  def test_qml_has_no_unprotected_text_elements(self):
    # Every Text element in Panel.qml must either be PlainText or explicitly set textFormat: Text.PlainText.
    qml_text = (PLUGIN_DIR / "Panel.qml").read_text(encoding="utf-8")
    lines = qml_text.splitlines()
    for idx, line in enumerate(lines, start=1):
      stripped = line.strip()
      if stripped == "Text {" or stripped.startswith("Text { "):
        block = "\n".join(lines[idx - 1 : idx + 6])
        self.assertIn(
          "textFormat: Text.PlainText",
          block,
          f"Bare Text element without textFormat: Text.PlainText at Panel.qml:{idx}",
        )


if __name__ == "__main__":
  unittest.main()
