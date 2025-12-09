# --- VARIABLES PARA LA CUENTA 2 (BACKEND) ---
variable "access_key_2" { type = string }
variable "secret_key_2" { type = string }
variable "session_token_2" { type = string }

# --- PROVEEDOR 1: CUENTA FRONTEND (Usa tus credenciales de consola actuales) ---
provider "aws" {
  region = "us-east-1"
}

# --- PROVEEDOR 2: CUENTA BACKEND (Usa las variables) ---
provider "aws" {
  alias      = "backend"
  region     = "us-east-1"
  access_key = var.access_key_2
  secret_key = var.secret_key_2
  token      = var.session_token_2
}

# =============================================================================
# INFRAESTRUCTURA CUENTA 1: FRONTEND (Load Balancer + ASG + 3 Políticas)
# =============================================================================

# 1. Datos de Red (Cuenta 1)
data "aws_vpc" "default" {
  default = true
}
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# 2. Seguridad Frontend
resource "aws_security_group" "web_sg" {
  name        = "hola_mundo_sg"
  description = "Frontend SG"
  vpc_id      = data.aws_vpc.default.id
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Launch Template Frontend
resource "aws_launch_template" "app_lt" {
  name_prefix   = "frontend-lt"
  image_id      = "ami-0ebfd941bbafe70c6"
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = base64encode(<<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker
              service docker start
              usermod -a -G docker ec2-user
              docker run -d -p 80:80 ehpaucar/hola-mundo-aws:latest
              EOF
  )
}

# 4. Load Balancer Frontend
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

# 5. ASG Frontend (2 a 3 instancias)
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

# 6. Políticas Frontend (Red, CPU, Memoria)
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
resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "escala-por-cpu"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}
resource "aws_autoscaling_policy" "memory_policy" {
  name                   = "escala-por-memoria"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    customized_metric_specification {
      metric_name = "mem_used_percent"
      namespace   = "CWAgent"
      statistic   = "Average"
    }
    target_value = 80.0
  }
}
