#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/pm-cache"
.build/release/MessagesHelper live-self-test
app="workflow/Messages Helper.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
cp .build/release/MessagesHelper "$app/Contents/MacOS/MessagesHelper"
/usr/bin/python3 scripts/package.py
codesign --force --sign - --identifier dev.local.alfred-messages.helper "$app"
cp scripts/uninstall.sh workflow/uninstall.sh
cp README.md workflow/README.md
rm -rf workflow/docs; mkdir -p workflow/docs
cp docs/VALIDATION.md docs/FUTURE_WORK.md docs/CONTACT_NAME_AUDIT.md workflow/docs/
chmod +x workflow/run workflow/text-view workflow/uninstall.sh
rm -f dist/Alfred-Messages.alfredworkflow
(cd workflow && /usr/bin/zip -qry ../dist/Alfred-Messages.alfredworkflow . -x '*.DS_Store')
/usr/bin/unzip -t dist/Alfred-Messages.alfredworkflow

/usr/bin/python3 scripts/verify-package.py
/usr/bin/python3 scripts/package-source.py
