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
