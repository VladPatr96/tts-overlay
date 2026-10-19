@echo off
rem Запуск оверлея озвучки без мелькающего окна консоли.
start "" /min pwsh -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0tts-overlay.ps1"
