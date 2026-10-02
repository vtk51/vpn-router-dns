"""Isolated helper regressions: no production entry point or network commands.

Run with: python3 -m unittest discover -s tests -v
Only uniquely anchored function definitions are extracted from the repository.
All ipset operations are in-memory stubs; filesystem operations stay in a fresh
TemporaryDirectory. No Docker, systemd, root, or production backups are needed.
"""

from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "scripts/rebuild-lists.sh").read_text()


def helper(name, end):
    start = f"\n{name}() {{\n"
    stop = f"\n{end}"
    if SOURCE.count(start) != 1 or SOURCE.count(stop) != 1:
        raise AssertionError(f"ambiguous helper anchors: {name}")
    code = SOURCE[SOURCE.index(start):SOURCE.index(stop, SOURCE.index(start))]
    if not code.rstrip().endswith("}"):
        raise AssertionError(f"incomplete helper extraction: {name}")
    return code


HELPERS = "\n".join([
    helper("write_record", "signal_handler() {"),
    helper("destroy_owned_candidate", "rollback_ipset_if_safe() {"),
    helper("rollback_ipset_if_safe", "restore_dnsmasq_if_safe() {"),
    helper("recover_before_reconcile", "exit_handler() {"),
    helper("exit_handler", 'mkdir -p "$RUNTIME_DIR"'),
])

STUBS = r'''
TXN_RECORD="$TESTROOT/record"
WORK_DIR="$TESTROOT/work"
RUNTIME_DIR="$TESTROOT"
TEMP_SET=vrn_test
VPN_NETS=vpn_nets
TEMP_CREATED=1
SET_PRESENT=1
TEMP_FP=full
PRODUCTION_FP=old
OLD_NETS_FP=old
CANDIDATE_NETS_FP=full
EXPECTED_NETS=1
EXPECTED_DOMAINS=1
PHASE=PREPARE
KEEP_ARTIFACTS=0
CONFIG_INSTALLED=0
CANDIDATE_CREATED=0
CANDIDATE_INSTALLED=0
FINALIZED=0
EXIT_HANDLER_RUNNING=0
DNSMASQ_CANDIDATE=''
TXID=test
OLD_DNSMASQ_HASH=old
CANDIDATE_DNSMASQ_HASH=new
DNSMASQ_ID_BEFORE=old
DNSMASQ_ID_AFTER=new
PY_CALLS=0

blocked() { echo "unexpected external operation: $*" >&2; return 97; }
docker() { blocked docker; }
systemctl() { blocked systemctl; }
iptables() { blocked iptables; }
ip() { blocked ip; }
restore_dnsmasq_if_safe() { blocked restore_dnsmasq; }
ipset() {
  case "$1" in
    list) builtin printf 'Type: hash:net\nHeader: family inet\n' ;;
    destroy)
      [[ "$2" == "$TEMP_SET" ]] || return 97
      [[ "$FAULT" != destroy ]] || return 73
      SET_PRESENT=0 ;;
    swap)
      [[ "$2" == "$TEMP_SET" && "$3" == "$VPN_NETS" ]] || return 97
      saved="$TEMP_FP"; TEMP_FP="$PRODUCTION_FP"; PRODUCTION_FP="$saved" ;;
    *) blocked ipset ;;
  esac
}
ipset_membership_hash() {
  if [[ "$1" == "$VPN_NETS" ]]; then echo "$PRODUCTION_FP"; else echo "$TEMP_FP"; fi
}
ipset_references() { echo 0; }
ipset_entry_count() { echo 1; }
printf() {
  if [[ "$FAULT" == write && "$1" == '%s\n' && "${2:-}" == transaction_id=* ]]; then
    return 73
  fi
  builtin printf "$@"
}
chmod() { [[ "$FAULT" != chmod ]] || return 73; command chmod "$@"; }
mv() { [[ "$FAULT" != mv ]] || return 73; command mv "$@"; }
python3() {
  PY_CALLS=$((PY_CALLS + 1))
  if [[ "$FAULT" == file-fsync && "$PY_CALLS" == 1 ||
        "$FAULT" == directory-fsync && "$PY_CALLS" == 2 ]]; then return 73; fi
  command python3 "$@"
}
rm() {
  # Refuse any accidental extraction drift that would delete outside the fixture.
  for arg in "$@"; do
    case "$arg" in -*) ;; "$TESTROOT"/*) ;; *) blocked rm; return 97 ;; esac
  done
  command rm "$@"
}
snapshot() {
  builtin printf 'result=%s keep=%s temp=%s set=%s record=%s work=%s phase=%s\n' \
    "$RESULT" "$KEEP_ARTIFACTS" "$TEMP_CREATED" "$SET_PRESENT" \
    "$([[ -f "$TXN_RECORD" ]] && echo yes || echo no)" \
    "$([[ -f "$WORK_DIR/snapshot" ]] && echo yes || echo no)" "$PHASE"
}
'''


class RecoveryTests(unittest.TestCase):
    def run_helper(self, body, fault=""):
        with tempfile.TemporaryDirectory(prefix="vpn-router-recovery-") as directory:
            fixture = Path(directory)
            (fixture / "work").mkdir()
            (fixture / "work/snapshot").write_text("test snapshot\n")
            (fixture / "record").write_text(
                "phase=PREPARE\ntemporary_set=vrn_test\n"
                "candidate_vpn_nets_fingerprint=full\n"
            )
            script = ("set -euo pipefail\nTESTROOT=" + shlex.quote(directory) +
                      "\nFAULT=" + shlex.quote(fault) + STUBS + HELPERS + "\n" + body)
            subprocess.run(["bash", "-n"], input=script, text=True, check=True)
            result = subprocess.run(["bash"], input=script, text=True,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("unexpected external operation", result.stderr)
            return result

    def test_partial_candidate_returns_failure(self):
        result = self.run_helper('''
TEMP_FP=partial
if destroy_owned_candidate; then RESULT=0; else RESULT=$?; fi
snapshot
''')
        self.assertIn("result=1 keep=1 temp=1 set=1 record=yes work=yes", result.stdout)

    def test_exit_retains_partial_candidate_metadata(self):
        result = self.run_helper('''
TEMP_FP=partial
if exit_handler 7; then RESULT=0; else RESULT=$?; fi
snapshot
''')
        self.assertIn("result=7 keep=1 temp=1 set=1 record=yes work=yes", result.stdout)
        self.assertIn("transaction artifacts retained", result.stderr)

    def test_failed_destroy_retains_recovery_state(self):
        result = self.run_helper('''
if recover_before_reconcile; then RESULT=0; else RESULT=$?; fi
snapshot
''', fault="destroy")
        self.assertIn("result=1 keep=1 temp=1 set=1 record=yes work=yes", result.stdout)

    def test_successful_recovery_cleans_artifacts(self):
        result = self.run_helper('''
if recover_before_reconcile; then RESULT=0; else RESULT=$?; fi
snapshot
''')
        self.assertIn("result=0 keep=0 temp=0 set=0 record=no work=no", result.stdout)

    def test_keep_flag_prevents_finalized_cleanup(self):
        result = self.run_helper('''
FINALIZED=1; KEEP_ARTIFACTS=1
if exit_handler 1; then RESULT=0; else RESULT=$?; fi
snapshot
''')
        self.assertIn("result=1 keep=1 temp=1 set=1 record=yes work=yes", result.stdout)

    def test_journal_errors_are_not_masked(self):
        for fault in ("write", "chmod", "file-fsync", "mv", "directory-fsync"):
            with self.subTest(fault=fault):
                result = self.run_helper('''
if ! write_record COMPLETE; then RESULT=1; else RESULT=0; fi
if exit_handler "$RESULT"; then RESULT=0; else RESULT=$?; fi
snapshot
''', fault=fault)
                self.assertIn("result=1 keep=1 temp=1 set=1 record=yes work=yes phase=PREPARE",
                              result.stdout)
                self.assertIn("transaction journal update failed", result.stderr)

    def test_successful_journal_confirms_phase(self):
        result = self.run_helper('''
if write_record COMPLETE; then RESULT=0; else RESULT=$?; fi
[[ "$(awk -F= '$1 == "phase" {print $2}' "$TXN_RECORD")" == COMPLETE ]]
[[ "$(stat -c %a "$TXN_RECORD")" == 600 ]]
snapshot
''')
        self.assertIn("result=0 keep=0 temp=1 set=1 record=yes work=yes phase=COMPLETE",
                      result.stdout)

    def test_rollback_journal_failure_keeps_artifacts(self):
        result = self.run_helper('''
PRODUCTION_FP=full; TEMP_FP=old; PHASE=SWAPPED
if recover_before_reconcile; then RESULT=0; else RESULT=$?; fi
[[ "$PRODUCTION_FP" == old && "$TEMP_FP" == full ]]
snapshot
''', fault="mv")
        self.assertIn("result=1 keep=1 temp=1 set=1 record=yes work=yes phase=SWAPPED",
                      result.stdout)

    def test_successful_rollback_and_cleanup(self):
        result = self.run_helper('''
PRODUCTION_FP=full; TEMP_FP=old; PHASE=SWAPPED
if recover_before_reconcile; then RESULT=0; else RESULT=$?; fi
[[ "$PRODUCTION_FP" == old ]]
snapshot
''')
        self.assertIn("result=0 keep=0 temp=0 set=0 record=no work=no phase=ROLLED_BACK",
                      result.stdout)


if __name__ == "__main__":
    unittest.main()
