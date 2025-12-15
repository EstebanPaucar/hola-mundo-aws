terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ==========================================
# 1. VARIABLES (Deben coincidir con GitHub Actions)
# ==========================================
variable "aws_access_key_2" { type = string }
variable "aws_secret_key_2" { type = string }
variable "aws_session_token_2" { type = string }

# ==========================================
# 2. PROVEEDORES
# ==========================================

# CUENTA 1: FRONTEND (Credenciales por defecto)
provider "aws" {
  region = "us-east-1"
}

# CUENTA 2: BACKEND (Credenciales pasadas por variable)
provider "aws" {
  alias      = "backend_account"
  region     = "us-east-1"
  access_key = var.aws_access_key_2
  secret_key = var.aws_secret_key_2
  token      = var.aws_session_token_2
}

# ==========================================
# 3. INFRAESTRUCTURA FRONTEND (CUENTA 1)
# ==========================================

# Datos de Red
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Seguridad
resource "aws_security_group" "web_sg" {
  name        = "hola_mundo_sg_v3" # Nombre único
  description = "Frontend SG"
  vpc_id      = data.aws_vpc.default.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress { # SSH opcional
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
}

# Launch Template (FRONTEND)
resource "aws_launch_template" "app_lt" {
  name_prefix   = "frontend-lt-"
  image_id      = "ami-0ebfd941bbafe70c6"
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y docker
    service docker start
    usermod -a -G docker ec2-user
    # IMAGEN DEL FRONTEND
    docker run -d -p 80:80 ehpaucar/hola-mundo-aws:latest
  EOF
  )
}

# Load Balancer Frontend
resource "aws_lb" "app_lb" {
  name               = "frontend-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "app_tg" {
  name     = "frontend-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check { path = "/" }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# ASG Frontend (2 a 3 instancias)
resource "aws_autoscaling_group" "app_asg" {
  name                = "frontend-asg-prod"
  desired_capacity    = 2
  max_size            = 3
  min_size            = 2
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.app_tg.arn]
  
  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }
}

# --- POLÍTICAS DE ESCALADO FRONTEND ---

# 1. Red
resource "aws_autoscaling_policy" "network_policy" {
  name                   = "escala-por-red"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageNetworkIn"
    }
    target_value = 500000.0
  }
}

# 2. CPU
resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "escala-por-cpu"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0 # Bajé a 50 para que sea mas facil de probar
  }
}

# 3. Memoria
resource "aws_autoscaling_policy" "memory_policy" {
  name                   = "escala-por-memoria"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    customized_metric_specification {
      metric_name = "MemoryUtilization"
      namespace   = "CWAgent"
      statistic   = "Average"
    }
    target_value = 60.0
  }
}


# ==========================================
# 4. INFRAESTRUCTURA BACKEND (CUENTA 2)
# ==========================================

# Datos de Red (Cuenta 2)
data "aws_vpc" "backend_default" {
  provider = aws.backend_account
  default  = true
}
data "aws_subnets" "backend_subnets" {
  provider = aws.backend_account
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.backend_default.id]
  }
}

# Seguridad Backend
resource "aws_security_group" "backend_sg" {
  provider    = aws.backend_account
  name        = "backend-sg"
  description = "Backend SG"
  vpc_id      = data.aws_vpc.backend_default.id
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch Template Backend
resource "aws_launch_template" "backend_lt" {
  provider      = aws.backend_account
  name_prefix   = "backend-lt-"
  image_id      = "ami-0ebfd941bbafe70c6"
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.backend_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y docker
    service docker start
    usermod -a -G docker ec2-user
    # OJO: AQUÍ USAMOS LA IMAGEN DEL BACKEND
    docker run -d -p 80:80 ehpaucar/hola-mundo-backend:latest
  EOF
  )
}

# Load Balancer Backend (¡AGREGADO PARA QUE TENGAS URL!)
resource "aws_lb" "backend_lb" {
  provider           = aws.backend_account
  name               = "backend-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.backend_sg.id]
  subnets            = data.aws_subnets.backend_subnets.ids
}

resource "aws_lb_target_group" "backend_tg" {
  provider = aws.backend_account
  name     = "backend-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.backend_default.id
  health_check { path = "/" }
}

resource "aws_lb_listener" "backend_listener" {
  provider          = aws.backend_account
  load_balancer_arn = aws_lb.backend_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }
}

# ASG Backend (Fijo 2 instancias)
resource "aws_autoscaling_group" "backend_asg" {
  provider            = aws.backend_account
  name                = "backend-asg"
  vpc_zone_identifier = data.aws_subnets.backend_subnets.ids
  target_group_arns   = [aws_lb_target_group.backend_tg.arn]
  desired_capacity    = 2
  max_size            = 2
  min_size            = 2
  
  launch_template {
    id      = aws_launch_template.backend_lt.id
    version = "$Latest"
  }
}

# ==========================================
# 5. OUTPUTS FINALES (Para tu reporte)
# ==========================================
output "frontend_dns" {
  value = aws_lb.app_lb.dns_name
  description = "URL del Frontend (Cuenta 1)"
}

output "backend_dns" {
  value = aws_lb.backend_lb.dns_name
  description = "URL del Backend (Cuenta 2)"
}