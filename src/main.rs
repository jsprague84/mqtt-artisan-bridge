use anyhow::Result;
use clap::Parser;
use log::{info, error, debug};
use rumqttc::{AsyncClient, MqttOptions, QoS, Event, Packet};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::io::AsyncWriteExt;
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
struct TelemetryData {
    timestamp: u64,
    #[serde(rename = "beanTemp")]
    bean_temp: f64,
    #[serde(rename = "envTemp")]
    env_temp: f64,
    #[serde(rename = "rateOfRise")]
    rate_of_rise: f64,
    #[serde(rename = "heaterPWM")]
    heater_pwm: u8,
    #[serde(rename = "fanPWM")]
    fan_pwm: u8,
    setpoint: f64,
    #[serde(rename = "controlMode")]
    control_mode: u8,
    #[serde(rename = "heaterEnable")]
    heater_enable: u8,
    uptime: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let log_level = if args.debug { "debug" } else { "info" };
    env_logger::Builder::from_default_env()
        .filter_level(log_level.parse().unwrap_or(log::LevelFilter::Info))
        .format_timestamp_secs()
        .init();

    info!("MQTT-Artisan Bridge v{}", env!("CARGO_PKG_VERSION"));
    info!("MQTT Broker: {}:{}", args.mqtt_host, args.mqtt_port);
    info!("Device ID: {}", args.device_id);
    info!("Serial Port: {}", args.serial_port);

    let mut mqttoptions = MqttOptions::new(
        format!("mqtt-bridge-{}", args.device_id),
        &args.mqtt_host,
        args.mqtt_port,
    );
    mqttoptions.set_keep_alive(Duration::from_secs(30));
    mqttoptions.set_clean_session(true);
    
    let (client, mut eventloop) = AsyncClient::new(mqttoptions, 10);

    let builder = tokio_serial::new(&args.serial_port, args.baud_rate)
        .timeout(Duration::from_millis(1000));
    
    let serial_port = Arc::new(Mutex::new(
        SerialStream::open(&builder)?
    ));

    let telemetry_topic = format!("roaster/{}/telemetry", args.device_id);
    client.subscribe(&telemetry_topic, QoS::AtMostOnce).await?;
    info!("Subscribed to: {}", telemetry_topic);

    let last_telemetry = Arc::new(Mutex::new(None::<TelemetryData>));

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

    loop {
        match eventloop.poll().await {
            Ok(Event::Incoming(Packet::Publish(publish))) => {
                let topic = &publish.topic;
                let payload = String::from_utf8_lossy(&publish.payload);

                debug!("MQTT RX: {} = {}", topic, payload);

                if topic == &telemetry_topic {
                    match serde_json::from_str::<TelemetryData>(&payload) {
                        Ok(data) => {
                            info!(
                                "Telemetry: BT={:.1}°C, ET={:.1}°C",
                                data.bean_temp, data.env_temp
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
            Ok(_) => {}
            Err(e) => {
                error!("MQTT error: {}", e);
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    }
}
