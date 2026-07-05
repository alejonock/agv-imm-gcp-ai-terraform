"""
Backend de IA - FastAPI sobre Compute Engine (Multi-Zone MIG con GPU)
=======================================================================

Este servicio se ejecuta en cada instancia del Managed Instance Group
(MIG) multi-zona, detrás de un Internal HTTP(S) Load Balancer.

Responsabilidades:
  1. Validar el token OIDC (OAuth 2.0 / OpenID Connect) firmado por
     Google que envía el proxy de Cloud Run en la cabecera
     "Authorization: Bearer <token>".
  2. Verificar que el token pertenece a la cuenta de servicio
     autorizada del proxy Cloud Run (principio de mínimo privilegio).
  3. Recibir únicamente "ticket_id" y "action" y ejecutar la lógica de
     IA correspondiente (que puede usar la GPU de la instancia para
     inferencia).

Por qué OIDC de Google en vez de un servidor OAuth propio
------------------------------------------------------------
- Es la forma estándar de autenticación servicio-a-servicio en GCP.
- No requiere infraestructura adicional (sin servidor de autorización,
  sin base de datos de clientes/tokens, sin rotación manual de
  secretos).
- La verificación se hace con las claves públicas de Google
  (cacheadas automáticamente por la librería google-auth), por lo que
  es prácticamente gratuita y de muy baja latencia.
- Encaja perfectamente con un patrón de tráfico a ráfagas: no hay
  "coste" extra por la autenticación, ni cuellos de botella en un
  servidor de tokens centralizado.
"""

import os
import logging
from typing import Literal

from fastapi import FastAPI, Header, HTTPException, Depends
from pydantic import BaseModel, Field
from google.oauth2 import id_token as google_id_token
from google.auth.transport import requests as google_requests

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ia-backend")

app = FastAPI(title="Backend IA - Resolución de Incidencias", version="1.0.0")

# ---------------------------------------------------------------------------
# Configuración (variables de entorno de la instancia / instance template)
# ---------------------------------------------------------------------------

# Debe coincidir EXACTAMENTE con la URL usada como "audience" al pedir el
# token en el proxy de Cloud Run (normalmente la URL pública del propio
# servicio Cloud Run, ej: https://oauth-proxy-xxxxx-ew.a.run.app)
EXPECTED_AUDIENCE = os.environ.get("https://oauth-proxy-2r5kgbc6ca-ew.a.run.app", "")

# Email de la cuenta de servicio que usa el servicio Cloud Run.
# Solo se aceptan tokens emitidos para esta identidad.
ALLOWED_SERVICE_ACCOUNT = os.environ.get("ALLOWED_SERVICE_ACCOUNT", "")

# Adaptador de transporte reutilizable para verificar tokens contra
# las claves públicas de Google (se cachean automáticamente)
_google_request_adapter = google_requests.Request()


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------

class IARequest(BaseModel):
    ticket_id: str = Field(..., description="ID del ticket de Jira, ej: 'PROJ-1234'")
    action: Literal["help", "rca", "close"] = Field(
        ..., description="Acción solicitada: help | rca | close"
    )


class IAResponse(BaseModel):
    ticket_id: str
    action: str
    result: str


# ---------------------------------------------------------------------------
# Autenticación: verificación del token OIDC
# ---------------------------------------------------------------------------

def verify_oidc_token(authorization: str = Header(default=None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Falta el header 'Authorization: Bearer <token>'")

    token = authorization.split(" ", 1)[1]

    if not EXPECTED_AUDIENCE:
        logger.error("EXPECTED_AUDIENCE no está configurado en el servidor")
        raise HTTPException(status_code=500, detail="Configuración del servidor incompleta")

    try:
        claims = google_id_token.verify_oauth2_token(
            token, _google_request_adapter, audience=EXPECTED_AUDIENCE
        )
    except ValueError as exc:
        logger.warning("Token inválido: %s", exc)
        raise HTTPException(status_code=401, detail="Token inválido o expirado")

    # Verificación adicional: solo aceptar la cuenta de servicio del proxy
    token_email = claims.get("email")
    if ALLOWED_SERVICE_ACCOUNT and token_email != ALLOWED_SERVICE_ACCOUNT:
        logger.warning("Cuenta de servicio no autorizada: %s", token_email)
        raise HTTPException(status_code=403, detail="Cuenta de servicio no autorizada")

    return claims


# ---------------------------------------------------------------------------
# Lógica de IA (placeholder, ejecutable en CPU o GPU)
# ---------------------------------------------------------------------------

def run_ai_inference(ticket_id: str, action: str) -> str:
    """
    Punto de entrada de la lógica de IA.

    En una instancia con GPU (ej. NVIDIA T4 / L4), aquí se cargaría el
    modelo (torch/tensorflow) usando 'cuda' como dispositivo. Se deja
    como placeholder para que el ejercicio sea reproducible sin
    dependencias pesadas.
    """
    if action == "help":
        return (
            f"Sugerencias de resolución para el ticket {ticket_id}: "
            f"revisar logs recientes, comprobar despliegues asociados "
            f"y validar configuración de variables de entorno."
        )
    if action == "rca":
        return (
            f"Análisis de causa raíz (RCA) generado para el ticket {ticket_id}: "
            f"se detectó un patrón recurrente relacionado con timeouts "
            f"en llamadas a servicios externos."
        )
    # action == "close"
    return f"Ticket {ticket_id} cerrado. Resumen generado y adjuntado al ticket."


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/healthz")
def healthz():
    """Usado por el health check del Load Balancer / MIG autohealing."""
    return {"status": "ok"}


@app.post("/process", response_model=IAResponse)
def process(request: IARequest, claims: dict = Depends(verify_oidc_token)):
    logger.info(
        "Petición autorizada de %s -> ticket=%s action=%s",
        claims.get("email"), request.ticket_id, request.action,
    )

    result = run_ai_inference(request.ticket_id, request.action)

    return IAResponse(ticket_id=request.ticket_id, action=request.action, result=result)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
