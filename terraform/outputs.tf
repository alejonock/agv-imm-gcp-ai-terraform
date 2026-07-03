# =============================================================================
# outputs.tf
#
# Los "outputs" son valores que Terraform muestra al final de "terraform apply".
# Son útiles para saber qué se creó y qué URLs/IPs usar.
# También sirven para que otros módulos de Terraform consuman estos valores.
# =============================================================================

output "cloud_run_url" {
  description = "URL pública del proxy OAuth en Cloud Run. Esta es la URL que debes configurar en Jira."
  value       = google_cloud_run_v2_service.proxy.uri
}

output "internal_lb_ip" {
  description = "IP interna del Load Balancer. El proxy Cloud Run llama a esta IP para llegar al backend."
  value       = var.ilb_ip
}

output "proxy_service_account" {
  description = "Email de la cuenta de servicio del proxy. Úsala como 'allowed-service-account' en el instance template."
  value       = google_service_account.proxy_sa.email
}

output "backend_service_account" {
  description = "Email de la cuenta de servicio del backend (instancias del MIG)."
  value       = google_service_account.backend_sa.email
}

output "backend_code_bucket" {
  description = "Nombre del bucket donde subir el código del backend FastAPI."
  value       = google_storage_bucket.backend_code.name
}

output "vpc_connector_id" {
  description = "ID del VPC Access Connector usado por Cloud Run."
  value       = google_vpc_access_connector.connector.id
}

output "mig_name" {
  description = "Nombre del Managed Instance Group. Úsalo para hacer rolling updates o ver el estado."
  value       = google_compute_region_instance_group_manager.mig.name
}

output "siguiente_paso" {
  description = "Instrucciones para actualizar el 'expected-audience' del instance template con la URL real de Cloud Run."
  value       = <<-EOT
    ¡Infraestructura desplegada!

    Paso final: actualiza el metadata 'expected-audience' en el instance template con la URL real de Cloud Run:
      ${google_cloud_run_v2_service.proxy.uri}

    Edita terraform.tfvars, cambia cloud_run_image por la imagen correcta y vuelve a ejecutar terraform apply.
    La variable 'expected-audience' en el instance template se actualizará sola en el próximo apply.
  EOT
}
