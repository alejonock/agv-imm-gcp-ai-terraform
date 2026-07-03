# =============================================================================
# variables.tf
#
# Aquí defines TODOS los valores configurables del proyecto.
# Los valores reales van en terraform.tfvars (nunca lo subas a Git si tiene
# secretos). Para los que tienen "default", no es obligatorio ponerlos en
# terraform.tfvars.
# =============================================================================

# ---------------- State bucket -----------------------------------------------
# Nombre del bucket que guarda el Terraform state.
# Se crea una sola vez con terraform/bootstrap/main.tf.
# En la pipeline se pasa como -backend-config="bucket=$state_bucket_name".

variable "state_bucket_name" {
  description = "Nombre del bucket de GCS donde se guarda el Terraform state (creado con bootstrap/)"
  type        = string
}

# ---------------- Proyecto y región -----------------------------------------

variable "project_id" {
  description = "ID de tu proyecto en GCP (ej: 'mi-proyecto-123')"
  type        = string
}

variable "region" {
  description = "Región de GCP donde se despliega todo"
  type        = string
  default     = "europe-west1"
}

# ---------------- Red --------------------------------------------------------

variable "vpc_name" {
  description = "Nombre de la VPC que se creará"
  type        = string
  default     = "ia-vpc"
}

variable "subnet_name" {
  description = "Nombre de la subred principal"
  type        = string
  default     = "ia-subnet"
}

variable "subnet_cidr" {
  description = "Rango CIDR de la subred principal (ej: '10.10.0.0/24')"
  type        = string
  default     = "10.10.0.0/24"
}

variable "proxy_subnet_cidr" {
  description = "Rango CIDR de la subred del proxy interno del Load Balancer (debe ser /24 o mayor)"
  type        = string
  default     = "10.10.1.0/24"
}

variable "ilb_ip" {
  description = "IP estática del Internal Load Balancer (debe estar dentro de subnet_cidr)"
  type        = string
  default     = "10.10.0.100"
}

# ---------------- Compute Engine / MIG ---------------------------------------

variable "machine_type" {
  description = "Tipo de máquina virtual del backend (n1-* es obligatorio para usar GPU T4)"
  type        = string
  default     = "e2-medium"
}

variable "mig_min_replicas" {
  description = "Número mínimo de instancias del MIG (mínimo 1 para garantizar disponibilidad)"
  type        = number
  default     = 1
}

variable "mig_max_replicas" {
  description = "Número máximo de instancias del MIG (autoscaling hasta este valor)"
  type        = number
  default     = 6
}

variable "mig_target_cpu" {
  description = "Porcentaje de CPU que dispara el autoscaling (0.6 = 60%)"
  type        = number
  default     = 0.6
}

# ---------------- Cloud Run --------------------------------------------------

variable "cloud_run_service_name" {
  description = "Nombre del servicio Cloud Run (proxy OAuth)"
  type        = string
  default     = "oauth-proxy"
}

variable "cloud_run_image" {
  description = "Imagen Docker del proxy (ej: 'gcr.io/mi-proyecto/oauth-proxy:latest'). Se construye en la pipeline."
  type        = string
}

variable "jira_api_key" {
  description = "Clave secreta compartida con Jira para autenticación (ponla en terraform.tfvars, no en el código)"
  type        = string
  sensitive   = true # Terraform no la mostrará en los logs
}

# ---------------- Storage (código del backend) --------------------------------

variable "bucket_name" {
  description = "Nombre del bucket de Cloud Storage donde se guarda el código del backend"
  type        = string
}
