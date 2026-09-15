#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
python3 Scripts/project.py
xcodebuild -project AWDLToggle.xcodeproj -scheme AWDLToggle \
  -configuration Release -derivedDataPath build/DerivedData \
  SYMROOT="$PWD/build/Products" OBJROOT="$PWD/build/Intermediates.noindex" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ONLY_ACTIVE_ARCH=NO build > build/xcodebuild.log 2>&1 || {
    rg -n 'error:|warning:|BUILD FAILED' build/xcodebuild.log || tail -30 build/xcodebuild.log
    exit 1
  }
codesign --verify --deep --strict 'build/Products/Release/AWDL Toggle.app'
codesign --verify --strict build/Products/Release/AWDLToggleHelper
echo 'Built build/Products/Release/AWDL Toggle.app'
