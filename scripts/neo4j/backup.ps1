$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path "backups\neo4j","results\logs" | Out-Null

neo4j-admin.bat database dump dbmsneo4j --to-path="backups\neo4j" 2>&1 |
  Tee-Object -FilePath "results\logs\neo4j_backup.log"

Write-Host "✅ Neo4j backup completed."
