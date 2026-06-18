@echo off
rem PicaKeep CLI 启动器:转调同目录 picakeep.ps1(真正逻辑),复用上层 GUI exe 的 --server。
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0picakeep.ps1" %*
