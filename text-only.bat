@echo off
chcp 65001 >nul
cd /d "%~dp0"
bili_novel_packer.exe --text-only
pause
