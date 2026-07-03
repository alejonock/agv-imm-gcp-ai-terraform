# Integración de servicio de IA en GCP

## Estructura del proyecto

```
proyecto-ia-gcp/
├── cloud_run_proxy/          # Proxy OAuth (Flask) → se despliega en Cloud Run
│   ├── main.py
│   ├── requirements.txt
│   └── Dockerfile
├── backend_gce/              # Backend IA (FastAPI) → se despliega en Compute Engine
│   ├── main.py
│   ├── requirements.txt
│   └── startup-script.sh
├── terraform/                # Infraestructura como código
│   ├── main.tf               # Todos los recursos GCP
│   ├── variables.tf          # Definición de variables
│   ├── outputs.tf            # Valores que muestra Terraform al terminar
│   └── terraform.tfvars.example  # Plantilla de configuración
├── cloudbuild.yaml           # Pipeline con Cloud Build
└── .gitignore
```

---

## Primeros pasos (solo la primera vez)

### 1. Requisitos previos

```bash
# Instala gcloud CLI: https://cloud.google.com/sdk/docs/install
gcloud auth login
gcloud config set project TU_PROYECTO_ID

# Instala Terraform: https://developer.hashicorp.com/terraform/install
terraform -version   # debe ser >= 1.6
```

### 2. Crea el bucket del Terraform state (bootstrap)

Terraform guarda un "estado" (registro de qué recursos ya existen). Ese estado vive en un bucket de GCS. Antes de poder usar Terraform principal, hay que crear ese bucket — para eso existe el `bootstrap/`.

```bash
cd terraform/bootstrap

# Copia y edita el archivo de configuración
cp bootstrap.tfvars.example bootstrap.tfvars
# → edita bootstrap.tfvars con tu project_id y el nombre del bucket

terraform init          # descarga el provider (estado local, solo esta vez)
terraform apply         # crea el bucket en GCS
```

Terraform te mostrará el nombre del bucket al terminar. **Apúntalo**, lo usarás en el siguiente paso y como secreto `TF_STATE_BUCKET` en la pipeline.

### 3. Configura tus variables

```bash
cd ../   # vuelve a terraform/
cp terraform.tfvars.example terraform.tfvars
# Edita terraform.tfvars con tus valores reales
```

### 4. Primer despliegue manual

```bash
cd terraform/

# Init: conecta Terraform al state remoto en GCS
# Nota: pasamos el bucket con -backend-config (no está hardcodeado en el código)
terraform init \
  -backend-config="bucket=TU_PROYECTO-tf-state"

terraform validate  # verifica la sintaxis
terraform plan      # muestra qué va a crear (no crea nada todavía)
terraform apply     # ¡CREA la infraestructura!
```

---

## Google Cloud Build

Se usa `cloudbuild.yaml`:

```bash
# Conecta tu repo en GCP Console → Cloud Build → Triggers
# Configura las variables de sustitución:
#   _TF_BACKEND_BUCKET, _BUCKET_NAME, _JIRA_API_KEY, _REGION
```

---

## Cómo probar la integración con Jira

Una vez desplegado, Terraform mostrará la URL de Cloud Run:

```
cloud_run_url = "https://oauth-proxy-xxxxx-ew.a.run.app"
```

Prueba con curl:

```bash
curl -X POST https://oauth-proxy-xxxxx-ew.a.run.app/invoke-ia \
  -H "Content-Type: application/json" \
  -H "X-API-Key: TU_JIRA_API_KEY" \
  -d '{"ticket_id": "PROJ-1234", "action": "rca"}'
```

Respuesta esperada:
```json
{
  "ticket_id": "PROJ-1234",
  "action": "rca",
  "result": "Análisis de causa raíz (RCA) generado para el ticket PROJ-1234..."
}
```

---

## Comandos útiles de Terraform

```bash
terraform plan          # Ver qué cambiaría
terraform apply         # Aplicar cambios
terraform destroy       # ⚠️  Destruye TODA la infraestructura
terraform output        # Ver los outputs (URLs, IPs)
terraform state list    # Ver todos los recursos gestionados por Terraform
```
