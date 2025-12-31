param(
    [string]$Database = "cassandra"
)

$results = @{}
$recordCount = 100000

Write-Host "=== RTO TEST: $Database (100,000 records) ===" -ForegroundColor Cyan

if ($Database -eq "cassandra") {
    
    Write-Host "`n1. SETUP" -ForegroundColor Green
    docker start cass1
    Start-Sleep -Seconds 3
    
    docker exec -it cass1 cqlsh -e "DROP KEYSPACE IF EXISTS testdata;"
    docker exec -it cass1 cqlsh -e "CREATE KEYSPACE testdata WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};"
    docker exec -it cass1 cqlsh -e "USE testdata; CREATE TABLE records (id UUID PRIMARY KEY, name TEXT, value INT, timestamp TEXT);"
    
    Write-Host "`n2. SEEDING $recordCount RECORDS" -ForegroundColor Green
    $seedStart = (Get-Date).Ticks / 10000
    
    # Batch insert - 500 records per CQL statement
    $batchSize = 500
    for ($i = 0; $i -lt $recordCount; $i += $batchSize) {
        $cqlBatch = "BEGIN BATCH "
        $end = [Math]::Min($i + $batchSize, $recordCount)
        
        for ($j = $i; $j -lt $end; $j++) {
            $value = Get-Random -Minimum 1 -Maximum 1000
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $cqlBatch += "INSERT INTO records (id, name, value, timestamp) VALUES (uuid(), 'Record$j', $value, '$timestamp'); "
        }
        
        $cqlBatch += "APPLY BATCH;"
        docker exec cass1 cqlsh -e $cqlBatch -k testdata 2>$null
        
        if ($i % 5000 -eq 0) {
            Write-Host "  Inserted $i / $recordCount..." -ForegroundColor Gray
        }
    }
    
    $seedEnd = (Get-Date).Ticks / 10000
    $results.SeedTime = $seedEnd - $seedStart
    
    $countOutput = docker exec -it cass1 cqlsh -e "SELECT COUNT(*) FROM testdata.records;" 
    $results.RecordCount = $recordCount
    
    $dataDirSize = docker exec cass1 bash -c "du -sb /var/lib/cassandra/data/testdata/records-*/ | awk '{print `$1}'"
    $results.DataSizeMB = [math]::Round([int]$dataDirSize / 1MB, 2)
    
    Write-Host "`nData Size: $($results.DataSizeMB) MB" -ForegroundColor Yellow
    Write-Host "Seed Time: $($results.SeedTime) ms" -ForegroundColor Yellow
    
    Write-Host "`n3. BACKUP" -ForegroundColor Green
    docker exec cass1 bash -c "rm -rf /var/lib/cassandra/data/testdata/records-*/snapshots/test_snap"
    $backupStart = (Get-Date).Ticks / 10000
    docker exec cass1 nodetool snapshot testdata -t test_snap
    $backupEnd = (Get-Date).Ticks / 10000
    $results.BackupTime = $backupEnd - $backupStart
    
    $backupSize = docker exec cass1 bash -c "du -sb /var/lib/cassandra/data/testdata/records-*/snapshots/test_snap/ | awk '{print `$1}'"
    $results.BackupSizeMB = [math]::Round([int]$backupSize / 1MB, 2)
    
    Write-Host "Backup Time: $($results.BackupTime) ms" -ForegroundColor Yellow
    Write-Host "Backup Size: $($results.BackupSizeMB) MB" -ForegroundColor Yellow
    
    Write-Host "`n4. DATA LOSS" -ForegroundColor Green
    docker exec -it cass1 cqlsh -e "TRUNCATE testdata.records;"
    Write-Host "Data truncated" -ForegroundColor Red
    
    Write-Host "`n5. RESTORE" -ForegroundColor Green
    $restoreStart = (Get-Date).Ticks / 10000
    docker exec cass1 bash -c 'for dir in /var/lib/cassandra/data/testdata/records-*/; do if [ -d ${dir}snapshots/test_snap/ ]; then rm -f ${dir}*.db; cp -f ${dir}snapshots/test_snap/*.db ${dir}; fi; done'
    docker exec cass1 nodetool refresh testdata records
    $restoreEnd = (Get-Date).Ticks / 10000
    $results.RestoreTime = $restoreEnd - $restoreStart
    
    Write-Host "Restore Time: $($results.RestoreTime) ms" -ForegroundColor Yellow
    
    Write-Host "`n6. VERIFY" -ForegroundColor Green
    $countOutput = docker exec -it cass1 cqlsh -e "SELECT COUNT(*) FROM testdata.records;" | Select-String -Pattern "\d+"
    $results.RestoredCount = [int]($countOutput.Matches[0].Value)
    $results.IntegrityPercent = [math]::Round(($results.RestoredCount / $results.RecordCount) * 100, 2)
    
    Write-Host "Restored: $($results.RestoredCount) records ($($results.IntegrityPercent)%)" -ForegroundColor Yellow
    
} elseif ($Database -eq "mongodb") {
    
    Write-Host "`n1. SETUP" -ForegroundColor Green
    
    if (-not (docker ps -a --filter "name=mongo1" --format "{{.Names}}")) {
        docker run -d --name mongo1 -p 27017:27017 mongo:latest
        Start-Sleep -Seconds 10
    } else {
        docker start mongo1
        Start-Sleep -Seconds 5
    }
    
    docker exec mongo1 mongosh --eval "use testdata" --eval "db.records.drop()"
    
    Write-Host "`n2. SEEDING $recordCount RECORDS" -ForegroundColor Green
    $seedStart = (Get-Date).Ticks / 10000
    
    # Batch insert - 1000 records per insertMany
    $batchSize = 1000
    for ($i = 0; $i -lt $recordCount; $i += $batchSize) {
        $docs = @()
        $end = [Math]::Min($i + $batchSize, $recordCount)
        
        for ($j = $i; $j -lt $end; $j++) {
            $value = Get-Random -Minimum 1 -Maximum 1000
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $docs += "{name:'Record$j',value:$value,timestamp:'$timestamp'}"
        }
        
        $insertCmd = "db.records.insertMany([" + ($docs -join ",") + "])"
        docker exec mongo1 mongosh --quiet --eval "use testdata" --eval $insertCmd 2>$null
        
        if ($i % 5000 -eq 0) {
            Write-Host "  Inserted $i / $recordCount..." -ForegroundColor Gray
        }
    }
    
    $seedEnd = (Get-Date).Ticks / 10000
    $results.SeedTime = $seedEnd - $seedStart
    
    $countOutput = docker exec mongo1 mongosh --quiet --eval "use testdata" --eval "db.records.countDocuments({})"
    $results.RecordCount = [int]($countOutput | Select-String -Pattern "\d+" | Select-Object -First 1).Matches[0].Value
    
    $sizeOutput = docker exec mongo1 mongosh --quiet --eval "use testdata" --eval "db.records.stats().size"
    $results.DataSizeMB = [math]::Round([int]($sizeOutput | Select-String -Pattern "\d+" | Select-Object -First 1).Matches[0].Value / 1MB, 2)
    
    Write-Host "`nData Size: $($results.DataSizeMB) MB" -ForegroundColor Yellow
    Write-Host "Seed Time: $($results.SeedTime) ms" -ForegroundColor Yellow
    
    Write-Host "`n3. BACKUP" -ForegroundColor Green
    docker exec mongo1 rm -rf /backup
    $backupStart = (Get-Date).Ticks / 10000
    docker exec mongo1 mongodump --db=testdata --collection=records --out=/backup
    $backupEnd = (Get-Date).Ticks / 10000
    $results.BackupTime = $backupEnd - $backupStart
    
    $backupSize = docker exec mongo1 bash -c "du -sb /backup/testdata/ | awk '{print `$1}'"
    $results.BackupSizeMB = [math]::Round([int]$backupSize / 1MB, 2)
    
    Write-Host "Backup Time: $($results.BackupTime) ms" -ForegroundColor Yellow
    Write-Host "Backup Size: $($results.BackupSizeMB) MB" -ForegroundColor Yellow
    
    Write-Host "`n4. DATA LOSS" -ForegroundColor Green
    docker exec mongo1 mongosh --eval "use testdata" --eval "db.records.drop()"
    Write-Host "Collection dropped" -ForegroundColor Red
    
    Write-Host "`n5. RESTORE" -ForegroundColor Green
    $restoreStart = (Get-Date).Ticks / 10000
    docker exec mongo1 mongorestore --db=testdata --collection=records /backup/testdata/records.bson
    $restoreEnd = (Get-Date).Ticks / 10000
    $results.RestoreTime = $restoreEnd - $restoreStart
    
    Write-Host "Restore Time: $($results.RestoreTime) ms" -ForegroundColor Yellow
    
    Write-Host "`n6. VERIFY" -ForegroundColor Green
    $countOutput = docker exec mongo1 mongosh --quiet --eval "use testdata" --eval "db.records.countDocuments({})"
    $results.RestoredCount = [int]($countOutput | Select-String -Pattern "\d+" | Select-Object -First 1).Matches[0].Value
    $results.IntegrityPercent = [math]::Round(($results.RestoredCount / $results.RecordCount) * 100, 2)
    
    Write-Host "Restored: $($results.RestoredCount) records ($($results.IntegrityPercent)%)" -ForegroundColor Yellow
}

Write-Host "`n7. FINAL METRICS" -ForegroundColor Green
$results.TotalRTO = $results.BackupTime + $results.RestoreTime
$results.RecoverySpeedMBps = if ($results.RestoreTime -gt 0) { 
    [math]::Round(($results.DataSizeMB / ($results.RestoreTime / 1000)), 2) 
} else { 0 }
$results.StorageOverhead = [math]::Round((($results.BackupSizeMB / $results.DataSizeMB) * 100), 2)

Write-Host "`n========== RESULTS SUMMARY ==========" -ForegroundColor Cyan
Write-Host "Database: $Database"
Write-Host "Records: $($results.RecordCount)"
Write-Host "Data Size: $($results.DataSizeMB) MB"
Write-Host "Backup Time: $($results.BackupTime) ms"
Write-Host "Backup Size: $($results.BackupSizeMB) MB"
Write-Host "Restore Time: $($results.RestoreTime) ms"
Write-Host "Total RTO: $($results.TotalRTO) ms" -ForegroundColor Yellow
Write-Host "Recovery Speed: $($results.RecoverySpeedMBps) MB/s" -ForegroundColor Yellow
Write-Host "Storage Overhead: $($results.StorageOverhead)%" -ForegroundColor Yellow
Write-Host "Data Integrity: $($results.IntegrityPercent)%" -ForegroundColor Yellow
Write-Host "======================================`n" -ForegroundColor Cyan

$results | ConvertTo-Json | Out-File -FilePath "${Database}_100k_results.json"
Write-Host "Results saved to ${Database}_100k_results.json" -ForegroundColor Green