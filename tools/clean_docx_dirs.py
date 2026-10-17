#!/usr/bin/env python3
"""Remove directory entries from a docx package.

Some templates (and therefore every docx produced from them) contain ZIP
directory entries such as ``word/media/`` and register them in
``[Content_Types].xml`` as OPC parts.  Word rejects the whole package with
"文件可能已经损坏" even though the XML itself is valid; WPS is more tolerant.

This mirrors what ``strip_unused_media.py`` already does with unused images,
but also covers the empty directory entry and its content-type override.

用法:
    python3 tools/clean_docx_dirs.py input.docx output.docx
"""
import re
import sys
import zipfile

src, dst = sys.argv[1], sys.argv[2]

skipped = []
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.is_dir():
            skipped.append(item.filename)
            continue
        data = zin.read(item.filename)
        if item.filename == "[Content_Types].xml":
            # Drop overrides for directory parts (PartName ends with "/").
            data = re.sub(rb'<Override\b[^>]*PartName="[^"]*/"[^>]*/>', b"", data)
        zout.writestr(item, data)

if skipped:
    print("清理目录条目: " + ", ".join(skipped))
else:
    print("无目录条目需要清理")
