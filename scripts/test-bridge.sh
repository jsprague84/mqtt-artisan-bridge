#!/bin/bash
set -e

echo "🧪 Testing MQTT Bridge Setup"
echo "============================="

# Check Mosquitto
echo "Checking MQTT broker..."
if pgrep mosquitto > /dev/null; then
    echo "✅ Mosquitto is running"
else
    echo "❌ Mosquitto not running. Start with: sudo systemctl start mosquitto"
    exit 1
fi

# Test MQTT
echo "Testing MQTT connectivity..."
timeout 5 mosquitto_sub -h localhost -t test -C 1 > /dev/null 2>&1 &
sleep 1
if mosquitto_pub -h localhost -t test -m hello 2>/dev/null; then
    echo "✅ MQTT broker is responsive"
else
    echo "❌ MQTT broker not responding"
    exit 1
fi

# Check build
echo "Testing build..."
if cargo check --quiet; then
    echo "✅ Code compiles successfully"
else
    echo "❌ Build failed"
    exit 1
fi

echo ""
echo "🎉 All tests passed!"
echo ""
echo "Next steps:"
echo "1. Setup virtual ports: ./scripts/setup-virtual-ports.sh &"
echo "2. Build: cargo build --release"
echo "3. Run bridge: ./target/release/mqtt-artisan-bridge --debug"
echo "4. Test ESP32: ./scripts/simulate-esp32.sh"
