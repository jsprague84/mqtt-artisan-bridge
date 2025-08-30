#!/bin/bash
# Quick setup script for MQTT-Artisan Bridge
# Save this as setup.sh and run: chmod +x setup.sh && ./setup.sh

set -e

echo "🚀 Setting up MQTT-Artisan Bridge project..."
echo "============================================="

# Check if we're in the right directory or create it
if [[ ! -f "Cargo.toml" && ! -d "src" ]]; then
    echo "📁 Creating project structure..."
    
    # Create directories
    mkdir -p src config scripts docs tests .github/workflows
    
    echo "✅ Project directories created"
else
    echo "📁 Project structure already exists"
fi

# Create Cargo.toml
echo "📦 Creating Cargo.toml..."
cat > Cargo.toml << 'EOF'
[package]
name = "mqtt-artisan-bridge"
version = "0.1.0"
edition = "2021"
authors = ["Coffee Roaster <roaster@example.com>"]
description = "MQTT to Artisan bridge for ESP32 coffee roaster control"
license = "MIT"
repository = "https://github.com/yourusername/mqtt-artisan-bridge"
keywords = ["mqtt", "artisan", "coffee", "roaster", "esp32"]

[dependencies]
tokio = { version = "1.35", features = ["full"] }
rumqttc = "0.24"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
clap = { version = "4.4", features = ["derive"] }
tokio-serial = "5.4"
log = "0.4"
env_logger = "0.10"
anyhow = "1.0"
crossbeam-channel = "0.5"
signal-hook = "0.3"
signal-hook-tokio = { version = "0.3", features = ["futures-v0_3"] }
chrono = { version = "0.4", features = ["serde"] }

[profile.release]
lto = true
codegen-units = 1
panic = "abort"
strip = true
opt-level = 3
EOF

# Create basic main.rs (simplified version for testing)
echo "📝 Creating src/main.rs..."
cat > src/main.rs << 'EOF'
use anyhow::Result;
use clap::Parser;
use log::{info, error, debug};
use rumqttc::{Client, Connection, Event, MqttOptions, Packet, QoS};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;
use tokio_serial::SerialStream;
use std::sync::Arc;

#[derive(Parser)]
#[command(author, version, about)]
struct Args {
    #[arg(short = 'h', long, default_value = "localhost")]
    mqtt_host: String,
    
    #[arg(short = 'p', long, default_value = "1883")]
    mqtt_port: u16,
    
    #[arg(short = 'd', long, default_value = "esp32_roaster_01")]
    device_id: String,
    
    #[arg(short = 's', long, default_value = "/tmp/ttyV0")]
    serial_port: String,
    
    #[arg(short = 'b', long, default_value = "115200")]
    baud_rate: u32,
    
    #[arg(long)]
    debug: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
struct TelemetryData {
    timestamp: u64,
    bean_temp: f64,
    env_temp: f64,
    rate_of_rise: f64,
    heater_pwm: u8,
    fan_pwm: u8,
    setpoint: f64,
    control_mode: u8,
    heater_enable: u8,
    uptime: u64,
}

async fn run_bridge(args: Args) -> Result<()> {
    info!("Starting MQTT-Artisan Bridge");
    info!("MQTT Broker: {}:{}", args.mqtt_host, args.mqtt_port);
    info!("Device ID: {}", args.device_id);
    info!("Serial Port: {}", args.serial_port);

    // Setup MQTT client
    let mut mqttoptions = MqttOptions::new(
        format!("mqtt-bridge-{}", args.device_id),
        &args.mqtt_host,
        args.mqtt_port,
    );
    mqttoptions.set_keep_alive(Duration::from_secs(30));
    mqttoptions.set_clean_session(true);
    
    let (client, mut connection) = Client::new(mqttoptions, 10);

    // Setup serial port
    let builder = tokio_serial::new(&args.serial_port, args.baud_rate)
        .timeout(Duration::from_millis(1000));
    
    let serial_port = Arc::new(Mutex::new(
        SerialStream::open(&builder)?
    ));

    // Subscribe to telemetry
    let telemetry_topic = format!("roaster/{}/telemetry", args.device_id);
    client.subscribe(&telemetry_topic, QoS::AtMostOnce).await?;
    info!("Subscribed to: {}", telemetry_topic);

    // Shared state for latest telemetry
    let last_telemetry = Arc::new(Mutex::new(None::<TelemetryData>));

    // Start serial sender task
    let serial_clone = Arc::clone(&serial_port);
    let telemetry_clone = Arc::clone(&last_telemetry);
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(1000));
        
        loop {
            interval.tick().await;
            
            let data = {
                let guard = telemetry_clone.lock().await;
                guard.clone()
            };
            
            if let Some(telemetry) = data {
                let artisan_data = format!("{:.1},{:.1}\n", telemetry.bean_temp, telemetry.env_temp);
                
                let mut port = serial_clone.lock().await;
                if let Err(e) = port.write_all(artisan_data.as_bytes()).await {
                    error!("Serial write error: {}", e);
                } else {
                    debug!("Sent to Artisan: {}", artisan_data.trim());
                }
            }
        }
    });

    info!("Bridge started successfully");

    // Main MQTT event loop
    loop {
        match connection.poll().await {
            Ok(Event::Incoming(Packet::Publish(publish))) => {
                let topic = &publish.topic;
                let payload = String::from_utf8_lossy(&publish.payload);

                debug!("MQTT RX: {} = {}", topic, payload);

                if topic == &telemetry_topic {
                    match serde_json::from_str::<TelemetryData>(&payload) {
                        Ok(data) => {
                            debug!(
                                "Telemetry: BT={:.1}°C, ET={:.1}°C, ROR={:.2}°C/min",
                                data.bean_temp, data.env_temp, data.rate_of_rise
                            );
                            
                            let mut guard = last_telemetry.lock().await;
                            *guard = Some(data);
                        }
                        Err(e) => {
                            error!("Failed to parse telemetry: {}", e);
                        }
                    }
                }
            }
            Ok(Event::Incoming(Packet::ConnAck(_))) => {
                info!("MQTT connected successfully");
            }
            Err(e) => {
                error!("MQTT error: {}", e);
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
            _ => {}
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // Setup logging
    let log_level = if args.debug { "debug" } else { "info" };
    env_logger::Builder::from_default_env()
        .filter_level(log_level.parse().unwrap_or(log::LevelFilter::Info))
        .format_timestamp_secs()
        .init();

    info!("MQTT-Artisan Bridge v{}", env!("CARGO_PKG_VERSION"));

    run_bridge(args).await
}
EOF

# Create config file
echo "⚙️  Creating config/bridge.json..."
cat > config/bridge.json << 'EOF'
{
  "mqtt_host": "localhost",
  "mqtt_port": 1883,
  "device_id": "esp32_roaster_01",
  "serial_port": "/tmp/ttyV0",
  "baud_rate": 115200,
  "log_level": "info"
}
EOF

# Create virtual port setup script
echo "🔌 Creating scripts/setup-virtual-ports.sh..."
cat > scripts/setup-virtual-ports.sh << 'EOF'
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
EOF

chmod +x scripts/setup-virtual-ports.sh

# Create ESP32 simulator
echo "📡 Creating scripts/simulate-esp32.sh..."
cat > scripts/simulate-esp32.sh << 'EOF'
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
EOF

chmod +x scripts/simulate-esp32.sh

# Create test script
echo "🧪 Creating scripts/test-bridge.sh..."
cat > scripts/test-bridge.sh << 'EOF'
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
EOF

chmod +x scripts/test-bridge.sh

# Create README
echo "📖 Creating README.md..."
cat > README.md << 'EOF'
# MQTT-Artisan Bridge

A Rust-based bridge that connects ESP32 coffee roaster controllers to Artisan roasting software via MQTT.

## Quick Start

1. **Install prerequisites:**
   ```bash
   sudo apt install mosquitto mosquitto-clients socat
   sudo systemctl start mosquitto
   ```

2. **Setup project:**
   ```bash
   ./scripts/test-bridge.sh  # Verify setup
   ```

3. **Build:**
   ```bash
   cargo build --release
   ```

4. **Run:**
   ```bash
   # Terminal 1: Setup virtual ports
   ./scripts/setup-virtual-ports.sh &
   
   # Terminal 2: Run bridge
   ./target/release/mqtt-artisan-bridge --debug
   
   # Terminal 3: Test with simulator
   ./scripts/simulate-esp32.sh
   
   # Terminal 4: Check output
   cat /tmp/ttyV1
   ```

## Configuration

Configure Artisan to use serial port `/tmp/ttyV1` at 115200 baud.

## MQTT Topics

- `roaster/{device_id}/telemetry` - Temperature data from ESP32
- Bridge outputs BT,ET format to serial port for Artisan

## License

MIT License
EOF

# Create .gitignore
cat > .gitignore << 'EOF'
/target/
Cargo.lock
*.log
/tmp/
.DS_Store
EOF

echo ""
echo "✅ Project setup complete!"
echo ""
echo "📁 Files created:"
echo "   📦 Cargo.toml"
echo "   🦀 src/main.rs"
echo "   ⚙️  config/bridge.json"
echo "   🔧 scripts/setup-virtual-ports.sh"
echo "   🔬 scripts/simulate-esp32.sh"
echo "   🧪 scripts/test-bridge.sh"
echo "   📖 README.md"
echo ""
echo "🚀 Next steps:"
echo "   1. Run tests: ./scripts/test-bridge.sh"
echo "   2. If tests pass, continue with the README instructions"
echo "   3. Initialize git: git init && git add . && git commit -m 'Initial commit'"
echo ""
echo "📚 Check README.md for detailed usage instructions"
