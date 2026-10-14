@echo off
chcp 65001 >nul
cd /d "%~dp0"
bili_novel_packer.exe --check https://www.linovelib.com/novel/5340/341307.html
pause
