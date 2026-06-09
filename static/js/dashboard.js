async function fetchSummary() {
  const response = await fetch('/api/summary');
  if (!response.ok) {
    return;
  }

  const data = await response.json();

  document.getElementById('total-packets').textContent = data.total_packets;
  document.getElementById('total-alerts').textContent = data.total_alerts;

  document.getElementById('latest-alert').textContent = data.latest_alert
    ? `${data.latest_alert.severity}: ${data.latest_alert.reason}`
    : 'No alerts yet';
}

function showIncident(alert) {
  document.getElementById('incident-title').textContent = alert.reason;

  document.getElementById('incident-friendly-summary').textContent =
    `${alert.reason} from ${alert.src_ip} to ${alert.dst_ip}.`;

  let explanation = 'The system detected unusual network activity.';

  if (alert.reason.includes('Port scanning')) {
    explanation =
      'A device attempted to contact multiple ports on the target system in a short period of time. This can indicate reconnaissance before an attack.';
  } else if (alert.reason.includes('SYN flood')) {
    explanation =
      'A high number of TCP connection attempts were detected. This may indicate an attempt to overwhelm a service.';
  } else if (alert.reason.includes('Suspicious destination port')) {
    explanation =
      'Traffic was detected to a port commonly associated with remote access or administrative services.';
  } else if (alert.reason.includes('Large ICMP')) {
    explanation =
      'An unusually large ICMP packet was detected, which may indicate abnormal network probing.';
  }

  document.getElementById('incident-explanation').textContent = explanation;
  document.getElementById('incident-time').textContent = alert.timestamp;
  document.getElementById('incident-severity').textContent = alert.severity;
  document.getElementById('incident-src').textContent = alert.src_ip || '';
  document.getElementById('incident-dst').textContent = alert.dst_ip || '';
  document.getElementById('incident-window').textContent =
    `${alert.first_seen} - ${alert.last_seen}`;
  document.getElementById('incident-count').textContent = alert.trigger_count;
  document.getElementById('incident-ports').textContent =
    alert.ports || 'None recorded';

    const details = document.getElementById('technical-details');
const toggleButton = document.getElementById('toggle-details');

if (details) {
  details.classList.add('hidden');
}

if (toggleButton) {
  toggleButton.textContent = 'Show technical details';
}

document.getElementById('incident-modal').classList.remove('hidden');
  
}

function closeIncident() {
  document.getElementById('incident-modal').classList.add('hidden');
}

function toggleTechnicalDetails() {
  const details = document.getElementById('technical-details');
  const button = document.getElementById('toggle-details');

  details.classList.toggle('hidden');

  button.textContent = details.classList.contains('hidden')
    ? 'Show technical details'
    : 'Hide technical details';
}

async function fetchAlerts() {
  const response = await fetch('/api/alerts');
  if (!response.ok) {
    return;
  }

  const data = await response.json();
  const tbody = document.getElementById('alerts-table');
  tbody.innerHTML = '';

  for (const alert of data.alerts) {
    const row = document.createElement('tr');

    row.innerHTML = `
      <td>${alert.timestamp}</td>
      <td>${alert.severity}</td>
      <td>${alert.reason}</td>
      <td><button class="button secondary view-incident">View Incident</button></td>
    `;

    row.querySelector('.view-incident').addEventListener('click', () => {
      showIncident(alert);
    });

    tbody.appendChild(row);
  }
}

document.addEventListener('DOMContentLoaded', () => {
  const toggleButton = document.getElementById('toggle-details');

  if (toggleButton) {
    toggleButton.addEventListener('click', toggleTechnicalDetails);
  }

  refresh();
  setInterval(refresh, 5000);
});

async function refresh() {
  await Promise.all([fetchSummary(), fetchAlerts()]);
}