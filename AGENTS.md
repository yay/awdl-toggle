## Committing

After committing always list the commit's name and hash in your response.

## Build and verify

- `python3 Scripts/project.py` regenerates the checked-in Xcode project.
- `Scripts/build.sh` builds the locally signed Release app and helper.
- `Scripts/test.sh` runs tests without modifying the network interface.
- `python3 Scripts/package.py` assembles the local installer and uninstaller packages.
- Live network and installation tests require administrator privileges; never claim those passed from unit tests alone.
