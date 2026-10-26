@echo off
cd /d "%~dp0"
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*fpga_live_monitor.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
start "" pythonw "c:\Users\Mert\Desktop\robotkol\fpga_live_monitor.py"
