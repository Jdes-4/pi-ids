import time
from database import get_db_connection
from config import SUSPICIOUS_PORTS, BLACKLISTED_IPS


class Detector:
    def __init__(self):
        self.conn = get_db_connection()

    def close(self):
        self.conn.close()

    def _insert_alert(self, packet, severity, reason):
        
        self.conn.execute(
            """
            INSERT INTO alerts (
                timestamp,
                src_ip,
                dst_ip,
                protocol,
                dst_port,
                severity,
                reason,
                packet_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                time.time(),
                packet.get("src_ip"),
                packet.get("dst_ip"),
                packet.get("protocol"),
                packet.get("dst_port"),
                severity,
                reason,
                packet.get("packet_id"),
            ),
        )

        self.conn.commit()

    def detect_packet(self, packet):
        reasons = []

        src_ip = packet.get("src_ip")
        dst_ip = packet.get("dst_ip")
        proto = packet.get("protocol")
        dst_port = packet.get("dst_port")
        flags = packet.get("flags")
        packet_size = packet.get("packet_size", 0)

        if src_ip in BLACKLISTED_IPS or dst_ip in BLACKLISTED_IPS:
            reasons.append("Traffic involves a blacklisted IP")

        if packet_size == 0:
            reasons.append("Zero-length packet")

        if proto == "TCP" and flags == "S" and src_ip and dst_ip and dst_port is not None:
            window = time.time() - 10
            row = self.conn.execute(
                """
                SELECT COUNT(*)
                FROM packets
                WHERE src_ip = ?
                  AND dst_ip = ?
                  AND protocol = 'TCP'
                  AND flags = 'S'
                  AND dst_port = ?
                  AND timestamp > ?
                """,
                (src_ip, dst_ip, dst_port,window),
            ).fetchone()
            if row and row[0] >= 100:
                reasons.append("Potential SYN flood detected")

        if proto == "TCP" and dst_port is not None and dst_port in SUSPICIOUS_PORTS:
            reasons.append(f"Suspicious destination port {dst_port}")

        if dst_port is not None and dst_port == 0:
            reasons.append("Traffic to reserved port 0")

        if proto == "ICMP" and packet_size > 1500:
            reasons.append("Large ICMP packet")

        if proto == "TCP" and flags == "S" and src_ip and dst_ip:
            window = time.time() - 60
            row = self.conn.execute(
                """
                SELECT COUNT(DISTINCT dst_port)
                FROM packets
                WHERE src_ip = ?
                    AND dst_ip = ?
                    AND protocol = 'TCP'
                    AND flags = 'S'
                    AND dst_port IS NOT NULL
                    AND timestamp > ?
                """,
                (src_ip, dst_ip, window),
            ).fetchone()

            if row and row[0] >= 12:
                existing = self.conn.execute(
                    """
                    SELECT id
                    FROM alerts
                    WHERE src_ip = ?
                        AND dst_ip = ?
                        AND reason = 'Port scanning behaviour detected'
                        AND timestamp > ?
                    LIMIT 1
                    """,
                (src_ip, dst_ip, window),
            ).fetchone()

                if not existing:
                    reasons.append("Port scanning behaviour detected")

        if reasons:
            self._insert_alert(packet, "high" if len(reasons) > 1 else "medium", "; ".join(reasons))
            return {"severity": "high" if len(reasons) > 1 else "medium", "reason": "; ".join(reasons)}

        return None
