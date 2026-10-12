#!/usr/bin/env python3
"""Package source and instructions without compiled apps, caches or previous archives."""
import pathlib, zipfile
root = pathlib.Path(__file__).resolve().parent.parent
paths = [root/'Package.swift', root/'README.md', root/'.gitignore']
for name in ['Sources', 'Tests', 'scripts', 'docs', 'workflow']:
    folder = root/name
    if folder.exists():
        paths.extend(p for p in folder.rglob('*') if p.is_file() and not any(part.endswith('.app') or part == '__pycache__' for part in p.parts) and p.name not in ['icon.png', '.DS_Store'])
with zipfile.ZipFile(root/'dist/Alfred-Messages-Source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(set(paths)):
        if path.exists(): archive.write(path, path.relative_to(root))
print('Built dist/Alfred-Messages-Source.zip')
