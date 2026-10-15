#!/usr/bin/env python3
"""删除 docx 里未被正文引用的图片（pandoc --reference-doc 会把模板的 media 全打包进来）。

做法：
  1. 扫 document.xml / header*.xml / footer*.xml，收集真正用到的 r:id / r:embed
  2. 找出 document.xml.rels 里 Type=image 且没被用到的关系
  3. 删掉这些关系条目和它们指向的 media 文件
  4. 重新打包，其余部件字节不变
"""
import re
import sys
import zipfile

src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src)

# --- 1. 收集所有被引用的 rId ---
used = set()
for n in zin.namelist():
    base = n.rsplit("/", 1)[-1]
    if n.endswith(".xml") and (base == "document.xml" or base.startswith(("header", "footer"))):
        used |= set(re.findall(r'r:(?:id|embed|link)="([^"]+)"', zin.read(n).decode("utf-8")))

# --- 2. 找出未使用的 image 关系 ---
rels_name = "word/_rels/document.xml.rels"
rels = zin.read(rels_name).decode("utf-8")
drop_ids, drop_files = set(), set()
for m in re.finditer(r'<Relationship\b[^>]*/>', rels):
    r = m.group(0)
    rid = re.search(r'Id="([^"]+)"', r)
    typ = re.search(r'Type="([^"]+)"', r)
    tgt = re.search(r'Target="([^"]+)"', r)
    if not (rid and typ and tgt):
        continue
    if typ.group(1).endswith("/image") and rid.group(1) not in used:
        drop_ids.add(rid.group(1))
        tgt = tgt.group(1)
        if not tgt.startswith(("http", "/")):
            drop_files.add("word/" + tgt.lstrip("/"))

# --- 3. 重写关系表（删掉这些条目）---
new_rels = re.sub(
    r'<Relationship\b[^>]*/>',
    lambda m: "" if re.search(r'Id="([^"]+)"', m.group(0)).group(1) in drop_ids else m.group(0),
    rels,
)

# --- 4. 重新打包 ---
saved = 0
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename in drop_files:
            saved += item.file_size
            continue
        data = zin.read(item.filename)
        if item.filename == rels_name:
            data = new_rels.encode("utf-8")
        zout.writestr(item, data)

print(f"已生成: {dst}")
print(f"  删除未引用的图片: {len(drop_files)} 个, 省下 {saved/1024/1024:.2f} MB")
for f in sorted(drop_files):
    print(f"    - {f}")
