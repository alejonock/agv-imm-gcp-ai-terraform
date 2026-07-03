#!/bin/bash
# ---------------------------------------------------------------------------
# Startup script para las instancias del Managed Instance Group (MIG)
#
# - Instala Python y dependencias del backend FastAPI.
# - Descarga el código de la aplicación (en este ejemplo desde un bucket
#   de Cloud Storage; en producción se podría usar una imagen de disco
#   personalizada para arrancar más rápido).
# - Configura un servicio systemd que mantiene el backend corriendo en
#   el puerto 8000.
# - Si la instancia tiene GPU asignada, instala los drivers de NVIDIA
#   automáticamente (script oficial de Google).
# ---------------------------------------------------------------------------
set -euo pipefail

APP_DIR="/opt/ia-backend"
EXPECTED_AUDIENCE="$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/expected-audience")"
ALLOWED_SERVICE_ACCOUNT="$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/allowed-service-account")"
APP_SOURCE_BUCKET="$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/app-source-bucket")"

# ------------------------------------------------------------------
# 1) Dependencias del sistema
# ------------------------------------------------------------------
apt-get update -y
apt-get install -y python3-venv python3-pip curl

# ------------------------------------------------------------------
# 2) (Opcional) Drivers de GPU - solo si la instancia tiene GPU
#    El instance template puede o no incluir un acelerador (guestAccelerator)
# ------------------------------------------------------------------
if curl -s -H "Metadata-Flavor: Google" \
   "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/" \
   | grep -qi "gpu" 2>/dev/null; then
  echo "GPU detectada, instalando drivers NVIDIA..."
  curl -fsSL https://raw.githubusercontent.com/GoogleCloudPlatform/compute-gpu-installation/main/linux/install_gpu_driver.py \
    -o /tmp/install_gpu_driver.py || true
  python3 /tmp/install_gpu_driver.py || echo "Instalación de driver GPU omitida/erronea (continuar)"
fi

# ------------------------------------------------------------------
# 3) Código de la aplicación
# ------------------------------------------------------------------
mkdir -p "${APP_DIR}"
gsutil -m cp -r "gs://${APP_SOURCE_BUCKET}/backend_gce/*" "${APP_DIR}/"

python3 -m venv "${APP_DIR}/venv"
"${APP_DIR}/venv/bin/pip" install --no-cache-dir -r "${APP_DIR}/requirements.txt"

# ------------------------------------------------------------------
# 4) Servicio systemd
# ------------------------------------------------------------------
cat > /etc/systemd/system/ia-backend.service <<EOF
[Unit]
Description=Backend IA - FastAPI
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment="EXPECTED_AUDIENCE=${EXPECTED_AUDIENCE}"
Environment="ALLOWED_SERVICE_ACCOUNT=${ALLOWED_SERVICE_ACCOUNT}"
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --workers 2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ia-backend
systemctl restart ia-backend
