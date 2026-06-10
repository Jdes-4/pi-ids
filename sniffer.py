import logging
import time
import threading
from scapy.all import sniff, IP, TCP, UDP, ICMP
from database import init_db, get_db_connection
from detector import Detector
from config import INTERFACE

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def extract_packet_info(pkt):
    if not pkt.haslayer(IP):
        return None

    ip = pkt[IP]
    protocol = "OTHER"
    src_port = None
    dst_port = None
    flags = None

    if pkt.haslayer(TCP):
        protocol = "TCP"
        src_port = int(pkt[TCP].sport)
        dst_port = int(pkt[TCP].dport)
        flags = str(pkt[TCP].flags)
    elif pkt.haslayer(UDP):
        protocol = "UDP"
        src_port = int(pkt[UDP].sport)
        dst_port = int(pkt[UDP].dport)
    elif pkt.haslayer(ICMP):
        protocol = "ICMP"

    return {
        "timestamp": time.time(),
        "src_ip": ip.src,
        "dst_ip": ip.dst,
        "protocol": protocol,
        "src_port": src_port,
        "dst_port": dst_port,
        "flags": flags,
        "packet_size": len(pkt),
        "summary": pkt.summary(),
    }


def save_packet(packet):
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute(
        """
        INSERT INTO packets (timestamp, src_ip, dst_ip, protocol, src_port, dst_port, flags, packet_size, summary)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            packet["timestamp"],
            packet["src_ip"],
            packet["dst_ip"],
            packet["protocol"],
            packet["src_port"],
            packet["dst_port"],
            packet["flags"],
            packet["packet_size"],
            packet["summary"],
        ),
    )
    packet_id = cursor.lastrowid
    conn.commit()
    conn.close()
    packet["packet_id"] = packet_id
    return packet


def process_packet(pkt, detector):
    packet = extract_packet_info(pkt)
    if packet is None:
        return
    
    if packet ["src_ip"] == "192.168.1.92":
        print(
            f"{packet['src_ip']} -> {packet['dst_ip']} "
            f"{packet['protocol']}:{packet['dst_port']} "
            f"flags={packet['flags']}"
        )

    packet = save_packet(packet)
    alert = detector.detect_packet(packet)
    if alert:
        logging.warning("Alert: %s - %s", packet["src_ip"], alert["reason"])


def start_sniffer():
    print("DEBUG: sniffer started")
    init_db()
    detector = Detector()

    def callback(pkt):
        try:
            process_packet(pkt, detector)
        except Exception as exc:
            logging.exception("Error processing packet: %s", exc)

    
    interfaces = [i.strip() for i in INTERFACE.split(",")]
    logging.info("Starting packet capture on interface: %s", interfaces or "all")

    sniff(
    iface=interfaces,
    prn=callback,
    store=False,
    )


if __name__ == "__main__":
    start_sniffer()
