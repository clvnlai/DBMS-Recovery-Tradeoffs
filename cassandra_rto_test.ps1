Write-Host "=== CASSANDRA RTO TEST ===" -ForegroundColor Cyan

Write-Host "`n1. SEEDING DATA" -ForegroundColor Green
docker start cass1
Start-Sleep -Seconds 3

docker exec -it cass1 cqlsh -e "CREATE KEYSPACE IF NOT EXISTS dbms WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};"
docker exec -it cass1 cqlsh -e "USE dbms; CREATE TABLE IF NOT EXISTS people (id UUID PRIMARY KEY, name TEXT, age INT);"
docker exec -it cass1 cqlsh -e "TRUNCATE dbms.people;"
docker exec -it cass1 cqlsh -e "INSERT INTO people (id, name, age) VALUES (uuid(), 'Alice', 25);" -k dbms
docker exec -it cass1 cqlsh -e "INSERT INTO people (id, name, age) VALUES (uuid(), 'Bob', 30);" -k dbms
docker exec -it cass1 cqlsh -e "INSERT INTO people (id, name, age) VALUES (uuid(), 'Charlie', 35);" -k dbms

Write-Host "`nData seeded:" -ForegroundColor Yellow
docker exec -it cass1 cqlsh -e "SELECT * FROM dbms.people;"

Write-Host "`n2. BACKUP" -ForegroundColor Green
docker exec cass1 bash -c "rm -rf /var/lib/cassandra/data/dbms/people-*/snapshots/rto_test"
$BACKUP_START = (Get-Date).Ticks / 10000
docker exec cass1 nodetool snapshot dbms -t rto_test
$BACKUP_END = (Get-Date).Ticks / 10000
$BACKUP_TIME = $BACKUP_END - $BACKUP_START
Write-Host "Backup Time: $BACKUP_TIME ms" -ForegroundColor Yellow

Write-Host "`n3. DATA LOSS" -ForegroundColor Green
docker exec -it cass1 cqlsh -e "TRUNCATE dbms.people;"
Write-Host "`nData after truncate:" -ForegroundColor Yellow
docker exec -it cass1 cqlsh -e "SELECT count(*) FROM dbms.people;"

Write-Host "`n4. RESTORE" -ForegroundColor Green
$RESTORE_START = (Get-Date).Ticks / 10000
docker exec cass1 bash -c 'for dir in /var/lib/cassandra/data/dbms/people-*/; do if [ -d ${dir}snapshots/rto_test/ ]; then rm -f ${dir}*.db; cp -f ${dir}snapshots/rto_test/*.db ${dir}; fi; done'
docker exec cass1 nodetool refresh dbms people
$RESTORE_END = (Get-Date).Ticks / 10000
$RESTORE_TIME = $RESTORE_END - $RESTORE_START
Write-Host "Restore Time: $RESTORE_TIME ms" -ForegroundColor Yellow

Write-Host "`n5. VERIFY" -ForegroundColor Green
docker exec -it cass1 cqlsh -e "SELECT * FROM dbms.people;"

Write-Host "`n6. RTO RESULTS" -ForegroundColor Green
$TOTAL_RTO = $BACKUP_TIME + $RESTORE_TIME
Write-Host "Backup Time: $BACKUP_TIME ms"
Write-Host "Restore Time: $RESTORE_TIME ms"
Write-Host "Total RTO: $TOTAL_RTO ms" -ForegroundColor Cyan