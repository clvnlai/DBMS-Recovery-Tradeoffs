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

docker exec -it cass1 cqlsh -e "SELECT * FROM dbms.people;"

Write-Host "`n2. BACKUP" -ForegroundColor Green
docker exec cass1 bash -c "rm -rf /var/lib/cassandra/data/dbms/people-*/snapshots/rto_test"
docker exec cass1 nodetool snapshot dbms -t rto_test
Write-Host "Backup completed"

Write-Host "`n3. DATA LOSS" -ForegroundColor Green
docker exec -it cass1 cqlsh -e "TRUNCATE dbms.people;"
Write-Host "`nData after truncate:" -ForegroundColor Yellow
docker exec -it cass1 cqlsh -e "SELECT count(*) FROM dbms.people;"