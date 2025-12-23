New-Item -ItemType Directory -Force -Path "backups\mongodb","results\logs" | Out-Null
mongodump --uri "mongodb://localhost:27017" --db "myDatabase1" --out "backups\mongodb" 2>&1 |
  Tee-Object -FilePath "results\logs\mongodb_backup.log"
Write-Host "✅ MongoDB backup completed."

