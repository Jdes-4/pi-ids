import threading
import time
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, session, jsonify, g
from database import init_db, get_db_connection
from config import SECRET_KEY, ADMIN_USER, ADMIN_PASSWORD_HASH
from sniffer import start_sniffer
from werkzeug.security import check_password_hash

app = Flask(__name__, template_folder="templates", static_folder="static")
app.secret_key = SECRET_KEY
sniffer_thread = None

app.config["SESSION_COOKIE_SECURE"] =True
app.config["SESSION_COOKIE_HTTPONLY"]=True
app.config["SESSION_COOKIE_SAMESITE"]="Lax"

init_db() 
def get_db():
    if "db" not in g:
        g.db = get_db_connection()
    return g.db


@app.teardown_appcontext
def close_db(exception=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def login_required(view):
    def wrapped_view(*args, **kwargs):
        if not session.get("authenticated"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)

    wrapped_view.__name__ = view.__name__
    return wrapped_view


@app.before_request
def ensure_sniffer():
    global sniffer_thread
    if sniffer_thread is None:
        sniffer_thread = threading.Thread(target=start_sniffer, daemon=True)
        sniffer_thread.start()


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")
        if (
            username == ADMIN_USER
            and check_password_hash(
                ADMIN_PASSWORD_HASH,
                password
            )
            
        ):
            session["authenticated"] = True
            return redirect(url_for("dashboard"))
        error = "Invalid credentials"
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
@login_required
def dashboard():
    return render_template("index.html")

@app.route("/reset")
@login_required
def reset():
    conn = get_db()

    conn.execute("DELETE FROM packets")
    conn.execute("DELETE FROM alerts")

    conn.execute("DELETE FROM sqlite_sequence WHERE name='packets';")
    conn.execute("DELETE FROM sqlite_sequence WHERE name='alerts';")
    conn.commit()

    return redirect(url_for("dashboard"))


@app.route("/api/summary")
@login_required
def api_summary():
    conn = get_db()
    total_packets = conn.execute("SELECT COUNT(*) FROM packets").fetchone()[0]
    total_alerts = conn.execute(
    """
    SELECT COUNT(*)
    FROM (
        SELECT
            src_ip,
            dst_ip,
            CAST(timestamp / 120 AS INTEGER) AS incident_window
        FROM alerts
        GROUP BY src_ip, dst_ip, incident_window
    )
    """
).fetchone()[0]
    latest_alert = conn.execute(
        "SELECT timestamp, severity, reason FROM alerts ORDER BY timestamp DESC LIMIT 1"
    ).fetchone()
    latest_alert_data = None
    if latest_alert:
        latest_alert_data = {
           # "timestamp": datetime.fromtimestamp(latest_alert[0]).strftime("%d/%m/%Y %H:%M:%S"),
            "severity": latest_alert[1],
            "reason": latest_alert[2],
        }
    return jsonify(
        {
            "total_packets": total_packets,
            "total_alerts": total_alerts,
            "latest_alert": latest_alert_data,
        }
    )

@app.route("/api/alerts")
@login_required
def api_alerts():
    conn = get_db()

    rows = conn.execute(
        """
        SELECT
            src_ip,
            dst_ip,
            CAST(timestamp / 120 AS INTEGER) AS incident_window,
            MIN(timestamp) AS first_seen,
            MAX(timestamp) AS last_seen,
            COUNT(*) AS trigger_count,
            GROUP_CONCAT(DISTINCT protocol) AS protocols,
            GROUP_CONCAT(DISTINCT dst_port) AS ports,
            GROUP_CONCAT(reason, '; ') AS reasons
        FROM alerts
        GROUP BY src_ip, dst_ip, incident_window
        ORDER BY last_seen DESC
        LIMIT 25
        """
    ).fetchall()

    alerts = []

    for row in rows:
        reasons = row[8] or ""

        if "Port scanning" in reasons:
            main_reason = "Port scanning behaviour detected"
            severity = "high"
        elif "SYN flood" in reasons:
            main_reason = "Potential SYN flood detected"
            severity = "high"
        elif "Suspicious destination port" in reasons:
            main_reason = "Suspicious destination port activity"
            severity = "medium"
        elif "Large ICMP" in reasons:
            main_reason = "Large ICMP packet detected"
            severity = "medium"
        else:
            main_reason = "Suspicious network activity"
            severity = "medium"

        alerts.append(
            {
                "timestamp": datetime.fromtimestamp(row[4]).strftime("%d/%m/%Y %H:%M:%S"),
                "severity": severity,
                "reason": main_reason,
                "src_ip": row[0],
                "dst_ip": row[1],
                "first_seen": datetime.fromtimestamp(row[3]).strftime("%H:%M:%S"),
                "last_seen": datetime.fromtimestamp(row[4]).strftime("%H:%M:%S"),
                "trigger_count": row[5],
                "protocols": row[6],
                "ports": row[7],
                "all_reasons": reasons,
            }
        )

    return jsonify({"alerts": alerts})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5005, debug=False)
