New-Item -ItemType Directory -Force -Path "results\timings" | Out-Null

$time = Measure-Command { powershell -ExecutionPolicy Bypass -File scripts\mongodb\restore.ps1 }
"mongodb_restore_seconds,$($time.TotalSeconds)" | Out-File "results\timings\mongodb_timings.csv"

Write-Host "✅ Saved results/timings/mongodb_timings.csv"
