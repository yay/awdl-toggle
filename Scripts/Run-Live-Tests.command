#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
echo 'AWDL Toggle acceptance checks'
echo 'This briefly toggles AWDL, tests forced re-enabling and helper restart,'
echo 'tests repair/uninstall, then reinstalls the app and restores your choice.'
echo 'Administrator authentication is required; your password is not recorded.'
echo
log="$PWD/build/live-tests.log"
sudo /bin/bash "$PWD/Scripts/live-test.sh" 2>&1 | tee "$log"
result=${PIPESTATUS[0]}
printf '\nTest exit status: %s\nLog: %s\n' "$result" "$log"
read -r -p 'Press Return to close.'
exit "$result"
