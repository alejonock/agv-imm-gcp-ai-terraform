"""
Cloud Run - OAuth Token Proxy / Gateway
=========================================

Este servicio recibe peticiones cURL simples desde Jira (sin lógica de
tokens) y se encarga de:

  1. Validar que la petición viene de Jira (API Key simple en cabecera).
  2. Obtener un token de identidad (OIDC) firmado por Google para la
     cuenta de servicio del propio servicio Cloud Run, usando el
     servidor de metadatos de GCP (gratis, sin almacenamiento de
     credenciales, sin rotación manual).
  3. Reenviar la petición al backend de IA (FastAPI en Compute Engine,
     detrás de un Internal HTTP(S) Load Balancer) incluyendo el token
     en la cabecera "Authorization: Bearer <token>".
  4. Devolver la respuesta del backend a Jira.

Por qué Cloud Run para esta pieza
----------------------------------
- Tráfico esporádico / a ráfagas (cierre de ticket, /help, /rca):
  Cloud Run escala a CERO instancias cuando no hay tráfico, por lo que
  el coste en los "largos periodos de inactividad" es prácticamente 0.
- No requiere gestionar servidores ni parches.
- La obtención del token OIDC es gratuita y no necesita Secret Manager
  ni bases de datos para cachear/rotar tokens: se solicita "al vuelo"
  al metadata server de la propia instancia/contenedor de Cloud Run.
"""

import os
import logging

from flask import Flask, request, jsonify
import requests
import google.auth.transport.requests
import google.oauth2.id_token

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("oauth-proxy")

# ---------------------------------------------------------------------------
# Configuración (variables de entorno del servicio Cloud Run)
# ---------------------------------------------------------------------------

# URL interna del backend de IA (Internal HTTP(S) Load Balancer -> MIG en GCE)
# Ej: "http://10.0.0.10" o "https://ia-backend.internal"
BACKEND_URL = os.environ.get("BACKEND_URL", "").rstrip("/")

# Clave simple compartida con Jira (Jira no puede manejar OAuth real,
# así que se usa un secreto simple en la cabecera "X-API-Key").
JIRA_API_KEY = os.environ.get("JIRA_API_KEY", "")

# Acciones permitidas (mapea con los comandos /help y /rca, y el cierre
# de ticket)
ALLOWED_ACTIONS = {"help", "rca", "close"}

REQUEST_TIMEOUT_SECONDS = 25


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

def get_identity_token(audience: str) -> str:
    """
    Obtiene un token de identidad (OIDC) firmado por Google para la
    cuenta de servicio asociada al servicio Cloud Run.

    Este token es validado por el backend (ver backend_gce/main.py)
    comprobando la firma de Google y el "audience". No requiere
    almacenar client_id/client_secret en ningún sitio.
    """
    auth_req = google.auth.transport.requests.Request()
    token = google.oauth2.id_token.fetch_id_token(auth_req, audience)
    return token


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"}), 200


@app.route("/invoke-ia", methods=["POST"])
def invoke_ia():
    """
    Endpoint llamado por Jira mediante un cURL simple:

    curl -X POST https://<cloud-run-url>/invoke-ia \
         -H "Content-Type: application/json" \
         -H "X-API-Key: <secreto-compartido>" \
         -d '{"ticket_id": "JIRA-1234", "action": "rca"}'
    """

    # 1) Autenticación simple desde Jira
    api_key = request.headers.get("X-API-Key", "")
    if not JIRA_API_KEY or api_key != JIRA_API_KEY:
        logger.warning("Petición rechazada: API Key inválida")
        return jsonify({"error": "unauthorized"}), 401

    # 2) Validación del payload
    payload = request.get_json(silent=True) or {}
    ticket_id = payload.get("ticket_id")
    action = payload.get("action")

    if not ticket_id or not isinstance(ticket_id, str):
        return jsonify({"error": "El campo 'ticket_id' es obligatorio"}), 400

    if action not in ALLOWED_ACTIONS:
        return jsonify({
            "error": f"El campo 'action' debe ser uno de: {sorted(ALLOWED_ACTIONS)}"
        }), 400

    if not BACKEND_URL:
        logger.error("BACKEND_URL no configurado")
        return jsonify({"error": "backend no configurado"}), 500

    # 3) Obtener token OIDC de Google para llamar al backend
    try:
        id_token = get_identity_token(BACKEND_URL)
    except Exception as exc:  # pragma: no cover
        logger.exception("Error obteniendo el token de identidad")
        return jsonify({"error": "no se pudo obtener el token de autenticación"}), 502

    # 4) Llamar al backend de IA en Compute Engine (via Internal Load Balancer)
    try:
        backend_response = requests.post(
            f"{BACKEND_URL}/process",
            json={"ticket_id": ticket_id, "action": action},
            headers={
                "Authorization": f"Bearer {id_token}",
                "Content-Type": "application/json",
            },
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
    except requests.RequestException as exc:
        logger.exception("Error llamando al backend de IA")
        return jsonify({"error": "el backend de IA no respondió"}), 502

    # 5) Devolver la respuesta a Jira
    try:
        body = backend_response.json()
    except ValueError:
        body = {"raw": backend_response.text}

    return jsonify(body), backend_response.status_code


if __name__ == "__main__":
    # Cloud Run inyecta la variable PORT (por defecto 8080)
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
