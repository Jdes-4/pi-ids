import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = Path(os.getenv("IDS_DB_PATH", BASE_DIR / "ids_data.sqlite"))
ADMIN_USER = os.getenv("IDS_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.getenv("IDS_ADMIN_PASSWORD", "password")
SECRET_KEY = os.getenv("IDS_SECRET_KEY", "dev-secret-key")
INTERFACE = os.getenv("IDS_INTERFACE", "")

SUSPICIOUS_PORTS = [21, 22, 23, 445, 3389, 5900, 8080]
BLACKLISTED_IPS = [ip.strip() for ip in os.getenv("IDS_BLACKLISTED_IPS", "").split(",") if ip.strip()]
