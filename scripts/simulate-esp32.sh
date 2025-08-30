#!/bin/bash

echo "🔬 ESP32 Telemetry Simulator"
echo "Press Ctrl+C to stop"

DEVICE_ID="esp32_roaster_01"
TOPIC="roaster/$DEVICE_ID/telemetry"

counter=0
while true; do
    bean_temp=$(echo "25 + $counter * 0.8" | bc -l 2>/dev/null || echo "25")
    env_temp=$(echo "23 + $counter * 0.3" | bc -l 2>/dev/null || echo "23")
    ror=$(echo "scale=2; $counter * 0.1" | bc -l 2>/dev/null || echo "0")
    
    timestamp=$(date +%s%3N)
    
    json=$(cat << JSON
{
  "timestamp": $timestamp,
  "beanTemp": $bean_temp,
  "envTemp": $env_temp,
  "rateOfRise": $ror,
  "heaterPWM": $((counter % 100)),
  "fanPWM": $((150 + counter % 50)),
  "setpoint": 200.0,
  "controlMode": 1,
  "heaterEnable": 1,
  "uptime": $counter
}
JSON
    )
    
    echo "📡 BT=${bean_temp}°C, ET=${env_temp}°C"
    mosquitto_pub -h localhost -t "$TOPIC" -m "$json" || echo "❌ MQTT publish failed"
    
    ((counter++))
    sleep 2
done
