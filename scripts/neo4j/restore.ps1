$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "results\logs" | Out-Null

neo4j-admin.bat database load dbmsneo4j --from-path="backups\neo4j" --overwrite-destination=true 2>&1 |
  Tee-Object -FilePath "results\logs\neo4j_restore.log"

Write-Host "✅ Neo4j restore completed."
