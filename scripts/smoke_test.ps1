New-Item -ItemType Directory -Force -Path "results/logs" | Out-Null
"Smoke test OK - $(Get-Date)" | Out-File "results/logs/smoke_test.txt"
Write-Host "Wrote results/logs/smoke_test.txt"

