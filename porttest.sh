#!/bin/bash

START_PORT=${1:-1}
END_PORT=${2:-1024}

echo "Teste ausgehende TCP-Verbindungen zu scanme.nmap.org  (Ports $START_PORT bis $END_PORT)"
echo "-----------------------------------------------------------------------"

for ((port=START_PORT; port<=END_PORT; port++)); do
  echo -ne "Port $port:\t"
  timeout 1 bash -c "echo > /dev/tcp/scanme.nmap.org /$port" 2>/dev/null \
    && echo "✅ offen" \
    || echo "❌ blockiert"
done
