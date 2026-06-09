import sqlite3
from pathlib import Path
from config import DB_PATH


def get_db_connection():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS packets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            src_ip TEXT NOT NULL,
            dst_ip TEXT NOT NULL,
            protocol TEXT NOT NULL,
            src_port INTEGER,
            dst_port INTEGER,
            flags TEXT,
            packet_size INTEGER NOT NULL,
            summary TEXT
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS alerts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            src_ip TEXT,
            dst_ip TEXT,
            protocol TEXT,
            dst_port INTEGER,
            severity TEXT NOT NULL,
            reason TEXT NOT NULL,
            packet_id INTEGER,
            FOREIGN KEY(packet_id) REFERENCES packets(id)
        )
        """
    )
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_packets_src_ip ON packets(src_ip)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_packets_dst_ip ON packets(dst_ip)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_alerts_src_ip ON alerts(src_ip)")
    conn.commit()
    conn.close()
