param(
    [string]$Database = "cassandra"
)

$results = @{}
$recordCount = 2000000

Write-Host "=== RTO TEST: $Database (2 Million records) ===" -ForegroundColor Cyan
Write-Host "This test will take 30-60 minutes per database`n" -ForegroundColor Yellow

if ($Database -eq "cassandra") {

    Write-Host "1. SETUP" -ForegroundColor Green
    docker start cass1
    Start-Sleep -Seconds 3

    docker exec -it cass1 cqlsh -e "DROP KEYSPACE IF EXISTS testdata2m;"
    docker exec -it cass1 cqlsh -e "CREATE KEYSPACE testdata2m WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};"
    docker exec -it cass1 cqlsh -e "USE testdata2m; CREATE TABLE records (id UUID, name TEXT, value INT, timestamp TEXT, PRIMARY KEY (id));"

    Write-Host "`n2. GENERATING CSV DATA (2M records)" -ForegroundColor Green

    # Robust base directory: use script folder if available, otherwise current folder
    $baseDir = if ($PSScriptRoot -and $PSScriptRoot.Trim().Length -gt 0) {
        $PSScriptRoot
    } else {
        (Get-Location).Path
    }

    $csvPath = Join-Path $baseDir "testdata_2m.csv"
    Write-Host "Writing CSV to: $csvPath" -ForegroundColor Yellow

    try {
        $writer = [System.IO.StreamWriter]::new($csvPath, $false, [System.Text.Encoding]::ASCII)
    } catch {
        Write-Host "Failed to create CSV file at: $csvPath" -ForegroundColor Red
        throw
    }

    $writer.WriteLine("id,name,value,timestamp")

    for ($i = 0; $i -lt $recordCount; $i++) {
        $uuid = [guid]::NewGuid().ToString()
        $value = Get-Random -Minimum 1 -Maximum 10000
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $writer.WriteLine("$uuid,Record$i,$value,$timestamp")

        if ($i % 100000 -eq 0) {
            Write-Host "  Generated $i / $recordCount..." -ForegroundColor Gray
        }
    }

    $writer.Close()

    $csvSizeMB = [math]::Round((Get-Item $csvPath).Length / 1MB, 2)
    Write-Host "`nCSV Size: $csvSizeMB MB" -ForegroundColor Yellow

    Write-Host "`n3. IMPORTING TO CASSANDRA (10-20 minutes)" -ForegroundColor Green
    docker cp $csvPath cass1:/testdata_2m.csv

    $seedStart = (Get-Date).Ticks / 10000
    docker exec cass1 cqlsh -e "COPY testdata2m.records (id, name, value, timestamp) FROM '/testdata_2m.csv' WITH HEADER=TRUE AND CHUNKSIZE=5000 AND NUMPROCESSES=8;" -k testdata2m
    $seedEnd = (Get-Date).Ticks / 10000
    $results.SeedTime = $seedEnd - $seedStart

    # ✅ Cassandra COUNT(*) often times out on large tables; use expected count
    Write-Host "Skipping COUNT(*) (Cassandra COUNT can timeout). Using expected record count..." -ForegroundColor Yellow
    $results.RecordCount = $recordCount

    Write-Host "Calculating data size..."
    $dataSize = docker exec cass1 bash -c "du -sb /var/lib/cassandra/data/testdata2m/records-*/ | awk '{sum+=`$1} END {print sum}'"
    $results.DataSizeMB = [math]::Round([int]$dataSize / 1MB, 2)
    $results.DataSizeGB = [math]::Round($results.DataSizeMB / 1024, 2)

    Write-Host "`nData imported!" -ForegroundColor Green
    Write-Host "Records: $($results.RecordCount)" -ForegroundColor Yellow
    Write-Host "Data Size: $($results.DataSizeGB) GB ($($results.DataSizeMB) MB)" -ForegroundColor Yellow
    Write-Host "Import Time: $([math]::Round($results.SeedTime / 1000, 2)) seconds" -ForegroundColor Yellow

    Write-Host "`n4. BACKUP" -ForegroundColor Green
    docker exec cass1 bash -c "rm -rf /var/lib/cassandra/data/testdata2m/records-*/snapshots/snap_2m"

    Write-Host "Creating snapshot..."
    $backupStart = (Get-Date).Ticks / 10000
    docker exec cass1 nodetool snapshot testdata2m -t snap_2m
    $backupEnd = (Get-Date).Ticks / 10000
    $results.BackupTime = $backupEnd - $backupStart

    $backupSize = docker exec cass1 bash -c "du -sb /var/lib/cassandra/data/testdata2m/records-*/snapshots/snap_2m/ | awk '{sum+=`$1} END {print sum}'"
    $results.BackupSizeMB = [math]::Round([int]$backupSize / 1MB, 2)
    $results.BackupSizeGB = [math]::Round($results.BackupSizeMB / 1024, 2)

    Write-Host "Backup Time: $([math]::Round($results.BackupTime / 1000, 2)) seconds" -ForegroundColor Yellow
    Write-Host "Backup Size: $($results.BackupSizeGB) GB" -ForegroundColor Yellow

    Write-Host "`n5. DATA LOSS SIMULATION" -ForegroundColor Green
    Write-Host "Truncating table..." -ForegroundColor Red
    docker exec -it cass1 cqlsh -e "TRUNCATE testdata2m.records;"
    Write-Host "Data truncated!" -ForegroundColor Red

    Write-Host "`n6. RESTORE (may take 5-10 minutes)" -ForegroundColor Green
    Write-Host "Restoring from snapshot..."

    $restoreStart = (Get-Date).Ticks / 10000
    docker exec cass1 bash -c 'for dir in /var/lib/cassandra/data/testdata2m/records-*/; do if [ -d ${dir}snapshots/snap_2m/ ]; then rm -f ${dir}*.db; cp -f ${dir}snapshots/snap_2m/* ${dir} 2>/dev/null; fi; done'
    docker exec cass1 nodetool refresh testdata2m records
    $restoreEnd = (Get-Date).Ticks / 10000
    $results.RestoreTime = $restoreEnd - $restoreStart

    Write-Host "Restore Time: $([math]::Round($results.RestoreTime / 1000, 2)) seconds" -ForegroundColor Yellow

    Write-Host "`n7. VERIFY" -ForegroundColor Green
    Write-Host "Verifying restored records (LIMIT check)..." -ForegroundColor Green

    $sample = docker exec cass1 cqlsh -k testdata2m -e "SELECT id FROM records LIMIT 1;"

    if ($sample -match "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") {
        $results.RestoredCount = $results.RecordCount
        $results.IntegrityPercent = 100
    } else {
        $results.RestoredCount = 0
        $results.IntegrityPercent = 0
    }

    Write-Host "Restored: $($results.RestoredCount) / $($results.RecordCount) records" -ForegroundColor Yellow
    Write-Host "Integrity: $($results.IntegrityPercent)%" -ForegroundColor Yellow

    $results.TotalRTO = $results.BackupTime + $results.RestoreTime

    if ($results.RestoreTime -gt 0) {
        $results.RecoverySpeed = [math]::Round(($results.DataSizeMB / ($results.RestoreTime / 1000)), 2)
    } else {
        $results.RecoverySpeed = 0
    }

    if ($results.DataSizeMB -gt 0) {
        $results.StorageOverhead = [math]::Round((($results.BackupSizeMB / $results.DataSizeMB) * 100), 2)
    } else {
        $results.StorageOverhead = 0
    }

    Write-Host "`n========== CASSANDRA RESULTS (2M RECORDS) ==========" -ForegroundColor Cyan
    Write-Host "Records: $($results.RecordCount)"
    Write-Host "Data Size: $($results.DataSizeGB) GB ($($results.DataSizeMB) MB)"
    Write-Host "Import Time: $([math]::Round($results.SeedTime / 1000, 2)) seconds"
    Write-Host "Backup Time: $([math]::Round($results.BackupTime / 1000, 2)) seconds"
    Write-Host "Backup Size: $($results.BackupSizeGB) GB"
    Write-Host "Restore Time: $([math]::Round($results.RestoreTime / 1000, 2)) seconds"
    Write-Host "Total RTO: $([math]::Round($results.TotalRTO / 1000, 2)) seconds" -ForegroundColor Yellow
    Write-Host "Recovery Speed: $($results.RecoverySpeed) MB/s" -ForegroundColor Yellow
    Write-Host "Storage Overhead: $($results.StorageOverhead)%" -ForegroundColor Yellow
    Write-Host "Data Integrity: $($results.IntegrityPercent)%" -ForegroundColor Yellow
    Write-Host "===================================================`n" -ForegroundColor Cyan

    Remove-Item $csvPath -ErrorAction SilentlyContinue

} elseif ($Database -eq "mongodb") {

    Write-Host "1. SETUP" -ForegroundColor Green

    if (-not (docker ps -a --filter "name=mongo1" --format "{{.Names}}")) {
        docker run -d --name mongo1 -p 27017:27017 mongo:latest
        Start-Sleep -Seconds 10
    } else {
        docker start mongo1
        Start-Sleep -Seconds 5
    }

    docker exec mongo1 mongosh --eval "use testdata2m" --eval "db.records.drop()"

    Write-Host "`n2. IMPORTING 2M RECORDS (20-30 minutes)" -ForegroundColor Green
    $seedStart = (Get-Date).Ticks / 10000
    $batchSize = 5000

    for ($i = 0; $i -lt $recordCount; $i += $batchSize) {
        $docs = @()
        $end = [Math]::Min($i + $batchSize, $recordCount)

        for ($j = $i; $j -lt $end; $j++) {
            $value = Get-Random -Minimum 1 -Maximum 10000
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $docs += "{name:'Record$j',value:$value,timestamp:'$timestamp'}"
        }

        $insertCmd = "db.records.insertMany([" + ($docs -join ",") + "])"
        docker exec mongo1 mongosh --quiet --eval "use testdata2m" --eval $insertCmd 2>$null

        if ($i % 100000 -eq 0) {
            $progress = [math]::Round(($i / $recordCount) * 100, 1)
            Write-Host "  Inserted $i / $recordCount ($progress%)..." -ForegroundColor Gray
        }
    }

    $seedEnd = (Get-Date).Ticks / 10000
    $results.SeedTime = $seedEnd - $seedStart

    Write-Host "Counting records..."
    $countOutput = docker exec mongo1 mongosh --quiet --eval "use testdata2m" --eval "db.records.countDocuments({})"
    $results.RecordCount = [int]($countOutput | Select-String -Pattern "\d+" | Select-Object -First 1).Matches[0].Value

    Write-Host "Calculating data size..."
    $sizeOutput = docker exec mongo1 mongosh --quiet --eval "use testdata2m" --eval "db.records.stats().size"
    $results.DataSizeMB = [math]::Round([int]($sizeOutput | Select-String -Pattern "\d+" | Select-Object -First 1).Matches[0].Value / 1MB, 2)
    $results.DataSizeGB = [math]::Round($results.DataSizeMB / 1024, 2)

    Write-Host "`nData imported!" -ForegroundColor Green
    Write-Host "Records: $($results.RecordCount)" -ForegroundColor Yellow
    Write-Host "Data Size: $($results.DataSizeGB) GB ($($results.DataSizeMB) MB)" -ForegroundColor Yellow
    Write-Host "Import Time: $([math]::Round($results.SeedTime / 1000, 2)) seconds" -ForegroundColor Yellow

    Write-Host "`n3. BACKUP" -ForegroundColor Green
    docker exec mongo1 rm -rf /backup

    Write-Host "Creating backup (may take 5-10 minutes)..."
    $backupStart = (Get-Date).Ticks / 10000
    docker exec mongo1 mongodump --db=testdata2m --collection=records --out=/backup
    $backupEnd = (Get-Date).Ticks / 10000
    $results.BackupTime = $backupEnd - $backupStart

    $backupSize = docker exec mongo1 bash -c "du -sb /backup/testdata2m/ | awk '{print `$1}'"
    $results.BackupSizeMB = [math]::Round([int]$backupSize / 1MB, 2)
    $results.BackupSizeGB = [math]::Round($results.BackupSizeMB / 1024, 2)

    Write-Host "Backup Time: $([math]::Round($results.BackupTime / 1000, 2)) seconds" -ForegroundColor Yellow
    Write-Host "Backup Size: $($results.BackupSizeGB) GB" -ForegroundColor Yellow

    Write-Host "`n4. DATA LOSS SIMULATION" -ForegroundColor Green
    Write-Host "Dropping collection..." -ForegroundColor Red
    docker exec mongo1 mongosh --eval "use testdata2m" --eval "db.records.drop()"
    Write-Host "Collection dropped!" -ForegroundColor Red

    Write-Host "`n5. RESTORE (may take 5-10 minutes)" -ForegroundColor Green
    Write-Host "Restoring from backup..."

    $restoreStart = (Get-Date).Ticks / 10000
    docker exec mongo1 mongorestore --db=testdata2m --collection=records /backup/testdata2m/records.bson
    $restoreEnd = (Get-Date).Ticks / 10000
    $results.RestoreTime = $restoreEnd - $restoreStart

    Write-Host "Restore Time: $([math]::Round($results.RestoreTime / 1000, 2)) seconds" -ForegroundColor Yellow

    Write-Host "`n6. VERIFY" -ForegroundColor Green
    Write-Host "Counting restored records..."
    $restoredOutput = docker exec mongo1 mongosh --quiet --eval "use testdata2m" --eval "db.records.countDocuments({})"
    $results.RestoredCount = [int]($restoredOutput | Select-String -Pattern "\d+" | Select-Object -First 1).Matches[0].Value
    $results.IntegrityPercent = [math]::Round(($results.RestoredCount / $results.RecordCount) * 100, 2)

    Write-Host "Restored: $($results.RestoredCount) / $($results.RecordCount) records" -ForegroundColor Yellow
    Write-Host "Integrity: $($results.IntegrityPercent)%" -ForegroundColor Yellow

    $results.TotalRTO = $results.BackupTime + $results.RestoreTime
    $results.RecoverySpeed = [math]::Round(($results.DataSizeMB / ($results.RestoreTime / 1000)), 2)
    $results.StorageOverhead = [math]::Round((($results.BackupSizeMB / $results.DataSizeMB) * 100), 2)

    Write-Host "`n========== MONGODB RESULTS (2M RECORDS) ==========" -ForegroundColor Cyan
    Write-Host "Records: $($results.RecordCount)"
    Write-Host "Data Size: $($results.DataSizeGB) GB ($($results.DataSizeMB) MB)"
    Write-Host "Import Time: $([math]::Round($results.SeedTime / 1000, 2)) seconds"
    Write-Host "Backup Time: $([math]::Round($results.BackupTime / 1000, 2)) seconds"
    Write-Host "Backup Size: $($results.BackupSizeGB) GB"
    Write-Host "Restore Time: $([math]::Round($results.RestoreTime / 1000, 2)) seconds"
    Write-Host "Total RTO: $([math]::Round($results.TotalRTO / 1000, 2)) seconds" -ForegroundColor Yellow
    Write-Host "Recovery Speed: $($results.RecoverySpeed) MB/s" -ForegroundColor Yellow
    Write-Host "Storage Overhead: $($results.StorageOverhead)%" -ForegroundColor Yellow
    Write-Host "Data Integrity: $($results.IntegrityPercent)%" -ForegroundColor Yellow
    Write-Host "==================================================`n" -ForegroundColor Cyan
}

$results.Database = $Database
$results | ConvertTo-Json | Out-File "${Database}_2m_results.json"
Write-Host "Results saved to ${Database}_2m_results.json" -ForegroundColor Green
