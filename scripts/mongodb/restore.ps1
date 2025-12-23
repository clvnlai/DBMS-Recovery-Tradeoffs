New-Item -ItemType Directory -Force -Path "results\logs" | Out-Null

mongorestore --uri "mongodb://localhost:27017" --db "myDatabase1" --drop "backups\mongodb\myDatabase1" *>&1 |
  Tee-Object -FilePath "results\logs\mongodb_restore.log"

Write-Host "✅ MongoDB restore completed."
