#!/bin/bash
set -e

echo "Setting up virtual serial ports..."

# Kill existing socat processes
pkill -f "socat.*ttyV" || true
sleep 1

# Create virtual serial port pair
echo "Creating virtual serial port pair..."
socat -d -d pty,raw,echo=0,link=/tmp/ttyV0 pty,raw,echo=0,link=/tmp/ttyV1 &
SOCAT_PID=$!

sleep 2

# Set permissions
chmod 666 /tmp/ttyV0 /tmp/ttyV1 2>/dev/null || true

echo "✅ Virtual serial ports created:"
echo "   Bridge port:  /tmp/ttyV0"
echo "   Artisan port: /tmp/ttyV1"
echo "   socat PID: $SOCAT_PID"

# Save PID and wait
echo $SOCAT_PID > /tmp/socat.pid

cleanup() {
    echo "Cleaning up..."
    kill $SOCAT_PID 2>/dev/null || true
    rm -f /tmp/socat.pid /tmp/ttyV0 /tmp/ttyV1
}

trap cleanup EXIT INT TERM
wait $SOCAT_PID
