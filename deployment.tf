# ***************** Universidad de los Andes ***********************
# ****** Departamento de Ingeniería de Sistemas y Computación ******
# ********** Arquitectura y diseño de Software - ISIS2503 **********
#
# BITE.co - FinOps Platform - Sprint 3
#
# ASRs implementados:
#   1. INTEGRIDAD     → RDS primary + replica, transacciones atómicas
#   2. DISPONIBILIDAD → Kong Circuit Breaker + health checks activos
#   3. CONFIDENCIALIDAD → Kong JWT Plugin por organización
#
# Instancias EC2 (8 total - bajo límite AWS Academy):
#   acm-kong          (1x) Kong API Gateway + Circuit Breaker + JWT Plugin
#   acm-finops-{a,b,c}(3x) Manejador FinOps   → GET /dashboard/
#   acm-reports-{a,b,c}(3x) Manejador Reportes → GET /reports/generate/
#   acm-orgs          (1x) Manejador Organizaciones + API AUTH
#
# RDS (NO cuenta en límite EC2):
#   acm-db-primary    RDS PostgreSQL 16 (escritura)
#   acm-db-replica    RDS read replica  (lectura)
#
# Otros:
#   acm-cache         EC2 Redis
#   acm-cold-storage  S3 Bucket → Glacier después de 24 meses
#
# FIXES aplicados vs Sprint 2:
#   ✓ NO heredoc anidado → usa printf para .env
#   ✓ NO set -e → no mata instancia si un comando falla
#   ✓ systemd en vez de nohup → Django persiste entre sesiones
#   ✓ CSRF_TRUSTED_ORIGINS = ["http://*","https://*"] → no depende de IP de Kong
#   ✓ backup_retention_period=1 → permite crear réplica RDS
#   ✓ costs_db creada via psql antes de migrar
#   ✓ migrate solo en finops-a → evita conflictos concurrentes
# ******************************************************************

# ─────────────────────────────────────────────
# VARIABLES
# ─────────────────────────────────────────────

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_prefix" {
  description = "Prefix for all AWS resources"
  type        = string
  default     = "acm"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "db_password" {
  description = "PostgreSQL password"
  type        = string
  default     = "isis2503"
  sensitive   = true
}

variable "django_secret_key" {
  description = "Django SECRET_KEY"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────
# PROVIDER Y LOCALS
# ─────────────────────────────────────────────

provider "aws" {
  region = var.region
}

locals {
  project_name = "${var.project_prefix}-cloudmonitor"
  repository   = "https://github.com/JNFERH/arquisoftcloudmonitor.git"
  branch       = "main"
  db_name      = "monitoring_db"
  costs_db     = "costs_db"
  db_user      = "cloudmonitor_user"

  common_tags = {
    Project   = local.project_name
    ManagedBy = "Terraform"
    Sprint    = "3"
  }
}

# ─────────────────────────────────────────────
# AMI
# ─────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────────
# SECURITY GROUPS
# ─────────────────────────────────────────────

resource "aws_security_group" "traffic_kong" {
  name        = "${var.project_prefix}-traffic-kong"
  description = "Kong API Gateway ports 8000 and 8001"

  ingress {
    from_port   = 8000
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-kong" })
}

resource "aws_security_group" "traffic_django" {
  name        = "${var.project_prefix}-traffic-django"
  description = "Django on port 8080"

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-django" })
}

resource "aws_security_group" "traffic_rds" {
  name        = "${var.project_prefix}-traffic-rds"
  description = "PostgreSQL RDS on port 5432"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-rds" })
}

resource "aws_security_group" "traffic_cache" {
  name        = "${var.project_prefix}-traffic-cache"
  description = "Redis on port 6379"

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-cache" })
}

# SSH + egress abierto (necesario para apt, pip, git en todas las instancias)
resource "aws_security_group" "traffic_ssh" {
  name        = "${var.project_prefix}-traffic-ssh"
  description = "SSH and all outbound traffic"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-traffic-ssh" })
}

# ─────────────────────────────────────────────
# S3 - ALMACENAMIENTO EN FRÍO
# ─────────────────────────────────────────────

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "cold_storage" {
  bucket = "${var.project_prefix}-cold-storage-${random_id.bucket_suffix.hex}"
  tags   = merge(local.common_tags, { Name = "${var.project_prefix}-cold-storage" })
}

resource "aws_s3_bucket_lifecycle_configuration" "cold_storage_lifecycle" {
  bucket = aws_s3_bucket.cold_storage.id
  rule {
    id     = "move-to-glacier-after-24-months"
    status = "Enabled"
    transition {
      days          = 730
      storage_class = "GLACIER"
    }
  }
}

# ─────────────────────────────────────────────
# RDS - BASE DE DATOS PRIMARIA
# backup_retention_period=1 es OBLIGATORIO para poder crear réplica
# ─────────────────────────────────────────────

resource "aws_db_instance" "primary" {
  identifier        = "${var.project_prefix}-db-primary"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = local.db_name
  username = local.db_user
  password = var.db_password

  vpc_security_group_ids  = [aws_security_group.traffic_rds.id]
  publicly_accessible     = true
  skip_final_snapshot     = true
  backup_retention_period = 1

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-db-primary"
    Role = "database-primary"
  })
}

# ─────────────────────────────────────────────
# RDS - RÉPLICA DE LECTURA
# NOTA: La réplica NO se puede parar, solo eliminar.
# Para ahorrar créditos: terraform destroy al terminar.
# ─────────────────────────────────────────────

resource "aws_db_instance" "replica" {
  identifier          = "${var.project_prefix}-db-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = "db.t3.micro"

  publicly_accessible = true
  skip_final_snapshot = true

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-db-replica"
    Role = "database-replica"
  })
}

# ─────────────────────────────────────────────
# REDIS - CACHE
# ─────────────────────────────────────────────

resource "aws_instance" "cache" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_cache.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOT
    #!/bin/bash
    apt-get update -y
    apt-get install -y redis-server
    sed -i "s/bind 127.0.0.1 -::1/bind 0.0.0.0/" /etc/redis/redis.conf
    echo "maxmemory-policy allkeys-lru" >> /etc/redis/redis.conf
    systemctl restart redis-server
    systemctl enable redis-server
  EOT

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-cache", Role = "redis-cache" })
}

# ─────────────────────────────────────────────
# KONG - API GATEWAY
# Se despliega vacío. El kong.yml se configura
# automáticamente después del apply con los outputs.
# Ver sección POST-DEPLOY al final del archivo.
# ─────────────────────────────────────────────

resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_kong.id, aws_security_group.traffic_ssh.id]

  user_data = <<-EOT
    #!/bin/bash
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    usermod -aG docker ubuntu
    systemctl enable docker
    systemctl start docker
  EOT

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-kong", Role = "api-gateway" })
}

# ─────────────────────────────────────────────
# SCRIPT COMPARTIDO PARA INSTANCIAS APP
# ─────────────────────────────────────────────
# FIX vs Sprint 2:
#   - printf en vez de heredoc anidado para .env
#   - systemd en vez de nohup (persiste entre sesiones AWS Academy)
#   - CSRF_TRUSTED_ORIGINS con comodín (no depende de IP de Kong)
#   - --ignore-installed para evitar error de pyparsing
#   - NO set -e

locals {
  # Script base para instancias que NO hacen migraciones
  app_user_data_base = <<-EOT
    #!/bin/bash

    apt-get update -y
    apt-get install -y python3-pip git build-essential libpq-dev python3-dev postgresql-client

    mkdir -p /app
    cd /app
    if [ ! -d arquisoftcloudmonitor ]; then
      git clone ${local.repository} arquisoftcloudmonitor
    fi
    cd /app/arquisoftcloudmonitor
    git fetch origin ${local.branch}
    git checkout ${local.branch}

    printf 'SECRET_KEY=%s\nDB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\nDB_HOST=%s\nDB_PORT=5432\nCOSTS_DB_NAME=%s\nREDIS_HOST=%s\nREDIS_PORT=6379\n' \
      '${var.django_secret_key}' \
      '${local.db_name}' \
      '${local.db_user}' \
      '${var.db_password}' \
      '${aws_db_instance.primary.address}' \
      '${local.costs_db}' \
      '${aws_instance.cache.private_ip}' \
      > /app/arquisoftcloudmonitor/.env

    sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['*']/" /app/arquisoftcloudmonitor/monitoring/settings.py
    echo "CSRF_TRUSTED_ORIGINS = [\"http://*\", \"https://*\"]" >> /app/arquisoftcloudmonitor/monitoring/settings.py

    pip3 install -r /app/arquisoftcloudmonitor/requirements.txt --break-system-packages --ignore-installed
    pip3 install gunicorn --break-system-packages

    printf '[Unit]\nDescription=Django App - BITE.co FinOps\nAfter=network.target\n\n[Service]\nUser=root\nWorkingDirectory=/app/arquisoftcloudmonitor\nExecStart=/usr/bin/python3 manage.py runserver 0.0.0.0:8080\nRestart=always\nRestartSec=5\nStandardOutput=journal\nStandardError=journal\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/django.service

    systemctl daemon-reload
    systemctl enable django
    systemctl start django
  EOT

  # Script para finops-a: hace migraciones + crea costs_db
  app_user_data_with_migrate = <<-EOT
    #!/bin/bash

    apt-get update -y
    apt-get install -y python3-pip git build-essential libpq-dev python3-dev postgresql-client

    mkdir -p /app
    cd /app
    if [ ! -d arquisoftcloudmonitor ]; then
      git clone ${local.repository} arquisoftcloudmonitor
    fi
    cd /app/arquisoftcloudmonitor
    git fetch origin ${local.branch}
    git checkout ${local.branch}

    printf 'SECRET_KEY=%s\nDB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\nDB_HOST=%s\nDB_PORT=5432\nCOSTS_DB_NAME=%s\nREDIS_HOST=%s\nREDIS_PORT=6379\n' \
      '${var.django_secret_key}' \
      '${local.db_name}' \
      '${local.db_user}' \
      '${var.db_password}' \
      '${aws_db_instance.primary.address}' \
      '${local.costs_db}' \
      '${aws_instance.cache.private_ip}' \
      > /app/arquisoftcloudmonitor/.env

    sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['*']/" /app/arquisoftcloudmonitor/monitoring/settings.py
    echo "CSRF_TRUSTED_ORIGINS = [\"http://*\", \"https://*\"]" >> /app/arquisoftcloudmonitor/monitoring/settings.py

    pip3 install -r /app/arquisoftcloudmonitor/requirements.txt --break-system-packages --ignore-installed
    pip3 install gunicorn --break-system-packages

    echo "Esperando RDS..."
    for i in $(seq 1 40); do
      python3 -c "
import psycopg2, sys
try:
    psycopg2.connect(dbname='${local.db_name}',user='${local.db_user}',password='${var.db_password}',host='${aws_db_instance.primary.address}',port=5432)
    sys.exit(0)
except: sys.exit(1)
" && break
      echo "Intento $i/40 - esperando DB..."
      sleep 10
    done

    PGPASSWORD='${var.db_password}' psql \
      -h ${aws_db_instance.primary.address} \
      -U ${local.db_user} \
      -d ${local.db_name} \
      -c "CREATE DATABASE ${local.costs_db};" || true

    cd /app/arquisoftcloudmonitor
    python3 manage.py migrate
    python3 manage.py migrate --database=costs_db

    printf '[Unit]\nDescription=Django App - BITE.co FinOps\nAfter=network.target\n\n[Service]\nUser=root\nWorkingDirectory=/app/arquisoftcloudmonitor\nExecStart=/usr/bin/python3 manage.py runserver 0.0.0.0:8080\nRestart=always\nRestartSec=5\nStandardOutput=journal\nStandardError=journal\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/django.service

    systemctl daemon-reload
    systemctl enable django
    systemctl start django
  EOT
}

# ─────────────────────────────────────────────
# APP SERVERS: FINOPS (3 instancias)
# finops-a: hace migraciones
# finops-b y finops-c: solo instalan y arrancan
# ─────────────────────────────────────────────

resource "aws_instance" "finops_a" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_django.id, aws_security_group.traffic_ssh.id]

  user_data  = local.app_user_data_with_migrate
  depends_on = [aws_db_instance.primary, aws_instance.cache]

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-finops-a"
    Role = "finops"
  })
}

resource "aws_instance" "finops_bc" {
  for_each = toset(["b", "c"])

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_django.id, aws_security_group.traffic_ssh.id]

  user_data  = local.app_user_data_base
  depends_on = [aws_db_instance.primary, aws_instance.cache, aws_instance.finops_a]

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-finops-${each.key}"
    Role = "finops"
  })
}

# ─────────────────────────────────────────────
# APP SERVERS: REPORTES (3 instancias)
# ─────────────────────────────────────────────

resource "aws_instance" "reports" {
  for_each = toset(["a", "b", "c"])

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_django.id, aws_security_group.traffic_ssh.id]

  user_data  = local.app_user_data_base
  depends_on = [aws_db_instance.primary, aws_instance.cache, aws_instance.finops_a]

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-reports-${each.key}"
    Role = "reports"
  })
}

# ─────────────────────────────────────────────
# APP SERVER: ORGANIZACIONES (1 instancia)
# ─────────────────────────────────────────────

resource "aws_instance" "orgs" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.traffic_django.id, aws_security_group.traffic_ssh.id]

  user_data  = local.app_user_data_base
  depends_on = [aws_db_instance.primary, aws_instance.cache, aws_instance.finops_a]

  tags = merge(local.common_tags, { Name = "${var.project_prefix}-orgs", Role = "organizations" })
}

# ─────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────

output "kong_public_ip" {
  description = "IP pública de Kong (acceder via http://<ip>:8000)"
  value       = aws_instance.kong.public_ip
}

output "finops_a_public_ip" {
  value = aws_instance.finops_a.public_ip
}

output "finops_a_private_ip" {
  value = aws_instance.finops_a.private_ip
}

output "finops_bc_public_ips" {
  value = { for k, v in aws_instance.finops_bc : k => v.public_ip }
}

output "finops_bc_private_ips" {
  value = { for k, v in aws_instance.finops_bc : k => v.private_ip }
}

output "reports_public_ips" {
  value = { for k, v in aws_instance.reports : k => v.public_ip }
}

output "reports_private_ips" {
  value = { for k, v in aws_instance.reports : k => v.private_ip }
}

output "orgs_public_ip" {
  value = aws_instance.orgs.public_ip
}

output "orgs_private_ip" {
  value = aws_instance.orgs.private_ip
}

output "db_primary_endpoint" {
  description = "Endpoint RDS primaria (escritura)"
  value       = aws_db_instance.primary.address
}

output "db_replica_endpoint" {
  description = "Endpoint RDS réplica (lectura)"
  value       = aws_db_instance.replica.address
}

output "cache_private_ip" {
  value = aws_instance.cache.private_ip
}

output "cold_storage_bucket" {
  value = aws_s3_bucket.cold_storage.bucket
}

# ─────────────────────────────────────────────
# POST-DEPLOY: CONFIGURAR KONG
# ─────────────────────────────────────────────
# Después del apply, corre terraform output y usa las IPs para:
#
# ssh ubuntu@<kong_public_ip>
#
# Crear kong.yml con las IPs privadas de los outputs y correr:
#
# sudo docker network create kong-net
# sudo docker run -d --name kong --user root --network=kong-net \
#   -v "$(pwd):/kong/declarative/" \
#   -e "KONG_DATABASE=off" \
#   -e "KONG_DECLARATIVE_CONFIG=/kong/declarative/kong.yml" \
#   -e "KONG_PROXY_ACCESS_LOG=/dev/stdout" \
#   -e "KONG_ADMIN_ACCESS_LOG=/dev/stdout" \
#   -e "KONG_PROXY_ERROR_LOG=/dev/stderr" \
#   -e "KONG_ADMIN_ERROR_LOG=/dev/stderr" \
#   -e "KONG_ADMIN_LISTEN=0.0.0.0:8001" \
#   -e "KONG_ADMIN_GUI_URL=http://localhost:8002" \
#   -p 8000:8000 -p 8001:8001 -p 8002:8002 \
#   kong/kong-gateway:2.7.2.0-alpine
#
# Para que Kong arranque automáticamente:
# sudo tee /etc/systemd/system/kong-docker.service > /dev/null << 'EOF'
# [Unit]
# Description=Kong API Gateway
# After=docker.service
# Requires=docker.service
# [Service]
# Restart=always
# ExecStart=/usr/bin/docker start -a kong
# ExecStop=/usr/bin/docker stop kong
# [Install]
# WantedBy=multi-user.target
# EOF
# sudo systemctl daemon-reload
# sudo systemctl enable kong-docker
