# -*- coding: utf-8 -*-
"""scripts/tests 包标记文件。

有了它，`python -m unittest discover -s scripts/tests -v` 才能把测试目录
当成包来导入（否则 release_manifest / send_release_email 的相对导入路径会找不到）。
"""
