#!/bin/bash
# Administrator-run acceptance checks. Only the AWDL interface and this app's
# own installed components are touched. The selected state is restored on exit.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID == 0 ]] || { echo 'Run this script with sudo.' >&2; exit 77; }
workspace="$PWD"
app='/Applications/AWDL Toggle.app/Contents/MacOS/AWDL Toggle'
console_user=$(/usr/bin/stat -f %Su /dev/console)
[[ "$console_user" != root && "$console_user" != loginwindow ]] || { echo 'Run while signed into your desktop.' >&2; exit 1; }
client() { /usr/bin/sudo -H -u "$console_user" "$app" "$@"; }
initial=$(client --status | /usr/bin/plutil -extract enabled raw -o - -)
restore() {
  result=$?
  trap - EXIT
  if [[ ! -x "$app" ]]; then
    /usr/sbin/installer -pkg "$workspace/dist/AWDL-Toggle.pkg" -target / || true
  fi
  if [[ "$initial" == true ]]; then client --on || true; else client --off || true; fi
  exit "$result"
}
trap restore EXIT

/usr/sbin/installer -pkg "$workspace/dist/AWDL-Toggle.pkg" -target /
client --on
[[ "$(client --status | /usr/bin/plutil -extract interfaceUp raw -o - -)" == true ]]
client --off
[[ "$(client --status | /usr/bin/plutil -extract interfaceUp raw -o - -)" == false ]]

for attempt in 1 2 3 4 5; do
  /sbin/ifconfig awdl0 up
  # No arbitrary shell command is exposed through the helper. This independent
  # root process raises the interface, exactly as another system component would.
  /bin/sleep 0.1
  flags=$(/sbin/ifconfig awdl0 | /usr/bin/head -1)
  if [[ "$flags" == *'<UP,'* || "$flags" == *',UP,'* ]]; then
    echo 'FAIL: interface was not suppressed within 100 ms' >&2
    exit 1
  fi
done
echo 'PASS: five independent interface raises suppressed within 100 ms checks'

before=$(/bin/launchctl print system/local.vitaly.AWDLToggle.Helper | /usr/bin/awk '/pid =/ { print $3; exit }')
/bin/launchctl kill SIGKILL system/local.vitaly.AWDLToggle.Helper
for attempt in {1..100}; do
  /bin/sleep 0.2
  after=$(/bin/launchctl print system/local.vitaly.AWDLToggle.Helper | /usr/bin/awk '/pid =/ { print $3; exit }')
  if [[ -n "$after" && "$after" != "$before" ]]; then break; fi
done
[[ -n "$after" && "$after" != "$before" ]]
[[ "$(client --status | /usr/bin/plutil -extract enabled raw -o - -)" == false ]]
[[ "$(client --status | /usr/bin/plutil -extract interfaceUp raw -o - -)" == false ]]
echo 'PASS: helper restarted after SIGKILL and restored Off'

if /usr/bin/sudo -H -u "$console_user" "$workspace/build/Products/Release/AWDL Toggle.app/Contents/MacOS/AWDL Toggle" --status; then
  echo 'FAIL: uninstalled build was accepted' >&2
  exit 1
fi
echo 'PASS: helper rejected an uninstalled build'

/usr/sbin/installer -pkg "$workspace/dist/AWDL-Toggle-Repair.pkg" -target /
[[ "$(client --status | /usr/bin/plutil -extract enabled raw -o - -)" == false ]]
echo 'PASS: repair preserved Off'

/usr/sbin/installer -pkg "$workspace/dist/AWDL-Toggle-Uninstall.pkg" -target /
[[ ! -e '/Applications/AWDL Toggle.app' ]]
[[ ! -e '/Library/PrivilegedHelperTools/local.vitaly.AWDLToggle.Helper' ]]
[[ ! -e '/Library/LaunchDaemons/local.vitaly.AWDLToggle.Helper.plist' ]]
[[ ! -e '/Library/Application Support/AWDL Toggle' ]]
flags=$(/sbin/ifconfig awdl0 | /usr/bin/head -1)
[[ "$flags" == *'<UP,'* || "$flags" == *',UP,'* ]]
echo 'PASS: uninstall restored AWDL and removed custom installed components'

/usr/sbin/installer -pkg "$workspace/dist/AWDL-Toggle.pkg" -target /
echo 'PASS: full live acceptance suite; restoring the initial selection'
