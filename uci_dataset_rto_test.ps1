param(
    [string]$Database = "cassandra",
    [int]$SampleSize = 0
)

Write-Host "=== UCI HOUSEHOLD POWER CONSUMPTION - RTO TEST ===" -ForegroundColor Cyan
Write-Host "Database: $Database`n" -ForegroundColor Yellow

$dataFile = "household_power_consumption.txt"
$dataUrl = "https://archive.ics.uci.edu/ml/machine-learning-databases/00235/household_power_consumption.zip"

if (-not (Test-Path $dataFile)) {
    Write-Host "Downloading dataset..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $dataUrl -OutFile "household_power_consumption.zip"
    Expand-Archive -Path "household_power_consumption.zip" -DestinationPath "." -Force
    Write-Host "Dataset downloaded and extracted`n" -ForegroundColor Green
}

$results = @{}

if ($Database -eq "cassandra") {
    
    Write-Host "1. SETUP & SCHEMA" -ForegroundColor Green
    docker start cass1
    Start-Sleep -Seconds 3
    
    docker exec -it cass1 cqlsh -e "CREATE KEYSPACE IF NOT EXISTS power_data WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};"
    docker exec -it cass1 cqlsh -e @"
USE power_data;
CREATE TABLE IF NOT EXISTS consumption (
    id UUID PRIMARY KEY,
    date TEXT,
    time TEXT,
    global_active_power DECIMAL,
    global_reactive_power DECIMAL,
    voltage DECIMAL,
    global_intensity DECIMAL,
    sub_metering_1 DECIMAL,
    sub_metering_2 DECIMAL,
    sub_metering_3 DECIMAL
);
TRUNCATE consumption;
"@
    
    Write-Host "`n2. IMPORTING DATA" -ForegroundColor Green
    $lines = Get-Content $dataFile | Select-Object -Skip 1
    
    if ($SampleSize -gt 0 -and $SampleSize -lt $lines.Count) {
        $lines = $lines | Select-Object -First $SampleSize
    }
    
    $totalLines = $lines.Count
    Write-Host "Importing $totalLines records..." -ForegroundColor Yellow
    
    $seedStart = (Get-Date).Ticks / 10000
    $batchSize = 100
    $imported = 0
    
    for ($i = 0; $i -lt $totalLines; $i += $batchSize) {
        $batch = $lines[$i..[Math]::Min($i + $batchSize - 1, $totalLines - 1)]
        
        foreach ($line in $batch) {
            $fields = $line -split ';'
            if ($fields.Count -eq 9 -and $fields[2] -ne '?') {
                $cql = "INSERT INTO consumption (id, date, time, global_active_power, global_reactive_power, voltage, global_intensity, sub_metering_1, sub_metering_2, sub_metering_3) VALUES (uuid(), '$($fields[0])', '$($fields[1])', $($fields[2]), $($fields[3]), $($fields[4]), $($fields[5]), $($fields[6]), $($fields[7]), $($fields[8]));"
                docker exec cass1 cqlsh -e $cql -k power_data 2>$null
                $imported++
            }
        }
        
        if ($i % 1000 -eq 0) {
            Write-Host "  Imported $i / $totalLines..." -ForegroundColor Gray
        }
    }
    
    $seedEnd = (Get-Date).Ticks / 10000
    $results.SeedTime = $seedEnd - $seedStart
    $results.RecordCount = $imported
    
    $dataDirSize = docker exec cass1 bash -c "du -sb /var/lib/cassandra/data/power_data/consumption-*/ | cut -f1"
    $results.DataSizeMB = [math]::Round([int]$dataDirSize / 1MB, 2)
    
    Write-Host "`nData imported: $($results.RecordCount) records, $($results.DataSizeMB) MB" -ForegroundColor Yellow
    Write-Host "Seed time: $($results.SeedTime) ms" -ForegroundColor Yellow
    
    Write-Host "`n3. BACKUP" -ForegroundColor Green
    docker exec cass1 bash -c "rm -rf /var/lib/cassandra/data/power_data/consumption-*/snapshots/power_backup"
    $backupStart = (Get-Date).Ticks / 10000
    docker exec cass1 nodetool snapshot power_data -t power_backup
    $backupEnd = (Get-Date).Ticks / 10000
    $results.BackupTime = $backupEnd - $backupStart
    
    $backupSize = docker exec cass1 bash -c "du -sb /var/lib/cassandra/data/power_data/consumption-*/snapshots/power_backup/ | cut -f1"
    $results.BackupSizeMB = [math]::Round([int]$backupSize / 1MB, 2)
    
    Write-Host "Backup Time: $($results.BackupTime) ms, Size: $($results.BackupSizeMB) MB" -ForegroundColor Yellow
    
    Write-Host "`n4. DATA LOSS SIMULATION" -ForegroundColor Green
    docker exec -it cass1 cqlsh -e "TRUNCATE power_data.consumption;"
    Write-Host "Data truncated" -ForegroundColor Red
    
    Write-Host "`n5. RESTORE" -ForegroundColor Green
    $restoreStart = (Get-Date).Ticks / 10000
    docker exec cass1 bash -c 'for dir in /var/lib/cassandra/data/power_data/consumption-*/; do if [ -d ${dir}snapshots/power_backup/ ]; then rm -f ${dir}*.db; cp -f ${dir}snapshots/power_backup/*.db ${dir}; fi; done'
    docker exec cass1 nodetool refresh power_data consumption
    $restoreEnd = (Get-Date).Ticks / 10000
    $results.RestoreTime = $restoreEnd - $restoreStart
    
    Write-Host "Restore Time: $($results.RestoreTime) ms" -ForegroundColor Yellow
    
    Write-Host "`n6. INTEGRITY VERIFICATION" -ForegroundColor Green
    $countOutput = docker exec -it cass1 cqlsh -e "SELECT COUNT(*) FROM power_data.consumption;" | Select-String -Pattern "\d+"
    $results.RestoredCount = [int]($countOutput.Matches[0].Value)
    $results.IntegrityPercent = [math]::Round(($results.RestoredCount / $results.RecordCount) * 100, 2)
    
    Write-Host "Restored: $($results.RestoredCount) / $($results.RecordCount) records ($($results.IntegrityPercent)%)" -ForegroundColor Yellow
    
} elseif ($Database -eq "mongodb") {
    
    Write-Host "1. SETUP & SCHEMA" -ForegroundColor Green
    
    if (-not (docker ps -a --filter "name=mongo1" --format "{{.Names}}")) {
        docker run -d --name mongo1 -p 27017:27017 mongo:latest
        Start-Sleep -Seconds 10
    } else {
        docker start mongo1
        Start-Sleep -Seconds 5
    }
    
    docker exec mongo1 mongosh --eval "use power_data" --eval "db.consumption.drop()"
    
    Write-Host "`n2. IMPORTING DATA" -ForegroundColor Green
    $lines = Get-Content $dataFile | Select-Object -Skip 1
    
    if ($SampleSize -gt 0 -and $SampleSize -lt $lines.Count) {
        $lines = $lines | Select-Object -First $SampleSize
    }
    
    $totalLines = $lines.Count
    Write-Host "Importing $totalLines records..." -ForegroundColor Yellow
    
    $seedStart = (Get-Date).Ticks / 10000
    $batchSize = 1000
    $imported = 0
    
    for ($i = 0; $i -lt $totalLines; $i += $batchSize) {
        $batch = $lines[$i..[Math]::Min($i + $batchSize - 1, $totalLines - 1)]
        $docs = @()
        
        foreach ($line in $batch) {
            $fields = $line -split ';'
            if ($fields.Count -eq 9 -and $fields[2] -ne '?') {
                $doc = @{
                    date = $fields[0]
                    time = $fields[1]
                    global_active_power = [decimal]$fields[2]
                    global_reactive_power = [decimal]$fields[3]
                    voltage = [decimal]$fields[4]
                    global_intensity = [decimal]$fields[5]
                    sub_metering_1 = [decimal]$fields[6]
                    sub_metering_2 = [decimal]$fields[7]
                    sub_metering_3 = [decimal]$fields[8]
                }
                $docs += ($doc | ConvertTo-Json -Compress)
                $imported++
            }
        }
        
        if ($docs.Count -gt 0) {
            $insertCmd = "db.consumption.insertMany([" + ($docs -join ",") + "])"
            docker exec mongo1 mongosh --quiet --eval "use power_data" --eval $insertCmd 2>$null
        }
        
        if ($i % 1000 -eq 0) {
            Write-Host "  Imported $i / $totalLines..." -ForegroundColor Gray
        }
    }
    
    $seedEnd = (Get-Date).Ticks / 10000
    $results.SeedTime = $seedEnd - $seedStart
    $results.RecordCount = $imported
    
    $sizeOutput = docker exec mongo1 mongosh --quiet --eval "use power_data" --eval "db.consumption.stats().size"
    $results.DataSizeMB = [math]::Round([int]($sizeOutput | Select-String -Pattern "\d+" | Select-Object -First 1).Matches[0].Value / 1MB, 2)
    
    Write-Host "`nData imported: $($results.RecordCount) records, $($results.DataSizeMB) MB" -ForegroundColor Yellow
    Write-Host "Seed time: $($results.SeedTime) ms" -ForegroundColor Yellow
    
    Write-Host "`n3. BACKUP" -ForegroundColor Green
    docker exec mongo1 rm -rf /backup
    $backupStart = (Get-Date).Ticks / 10000
    docker exec mongo1 mongodump --db=power_data --collection=consumption --out=/backup
    $backupEnd = (Get-Date).Ticks / 10000
    $results.BackupTime = $backupEnd - $backupStart
    
    $backupSize = docker exec mongo1 bash -c "du -sb /backup/power_data/ | cut -f1"
    $results.BackupSizeMB = [math]::Round([int]$backupSize / 1MB, 2)
    
    Write-Host "Backup Time: $($results.BackupTime) ms, Size: $($results.BackupSizeMB) MB" -ForegroundColor Yellow
    
    Write-Host "`n4. DATA LOSS SIMULATION" -ForegroundColor Green
    docker exec mongo1 mongosh --eval "use power_data" --eval "db.consumption.drop()"
    Write-Host "Collection dropped" -ForegroundColor Red
    
    Write-Host "`n5. RESTORE" -ForegroundColor Green
    $restoreStart = (Get-Date).Ticks / 10000
    docker exec mongo1 mongorestore --db=power_data --collection=consumption /backup/power_data/consumption.bson
    $restoreEnd = (Get-Date).Ticks / 10000
    $results.RestoreTime = $restoreEnd - $restoreStart
    
    Write-Host "Restore Time: $($results.RestoreTime) ms" -ForegroundColor Yellow
    
    Write-Host "`n6. INTEGRITY VERIFICATION" -ForegroundColor Green
    $restoredOutput = docker exec mongo1 mongosh --quiet --eval "use power_data" --eval "db.consumption.countDocuments({})"
    $results.RestoredCount = [int]($restoredOutput | Select-String -Pattern "\d+" | Select-Object -First 1).Matches[0].Value
    $results.IntegrityPercent = [math]::Round(($results.RestoredCount / $results.RecordCount) * 100, 2)
    
    Write-Host "Restored: $($results.RestoredCount) / $($results.RecordCount) records ($($results.IntegrityPercent)%)" -ForegroundColor Yellow
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

$results | ConvertTo-Json | Out-File -FilePath "${Database}_uci_results.json"
Write-Host "Results saved to ${Database}_uci_results.json" -ForegroundColor Green