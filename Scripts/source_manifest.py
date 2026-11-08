#!/usr/bin/env python3
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parent.parent
files=[]
for folder in ('Sources','Resources','Scripts','Tests'):
    for path in sorted((root/folder).rglob('*')):
        if path.is_file() and '__pycache__' not in str(path):
            files.append({'path':str(path.relative_to(root)),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
(root/'Verification').mkdir(exist_ok=True)
(root/'Verification/build-input.json').write_text(json.dumps({'version':'1.0.0','files':files},ensure_ascii=False,indent=2)+'\n')
print('Build inputs:',len(files))
