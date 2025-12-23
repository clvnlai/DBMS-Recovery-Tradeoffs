New-Item -ItemType Directory -Force -Path "results\verification" | Out-Null

mongosh --quiet --eval "db.getSiblingDB('myDatabase1').myCollection1.countDocuments()" |
  Out-File "results\verification\mongodb_count.txt"

mongosh --quiet --eval "db.getSiblingDB('myDatabase1').myCollection1.findOne()" |
  Out-File "results\verification\mongodb_sample_doc.txt"

Write-Host "✅ MongoDB verification saved."
