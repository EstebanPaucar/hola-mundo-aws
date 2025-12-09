provider "aws" {
  region = "us-east-1" # Cambia según tu región preferida
}

# 1. VPC y Seguridad (Usamos la default para simplificar, pero en producción crea una propia)
resource "aws_security_group" "web_sg" {
  name        = "hola_mundo_sg"
  description = "Permitir HTTP"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress { # Permitir SSH si necesitas debugear
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

# 2. Launch Template (Define CÓMO son las instancias)
resource "aws_launch_template" "app_lt" {
  name_prefix   = "hola-mundo-lt"
  image_id      = "ami-0ebfd941bbafe70c6" # Amazon Linux 2023 (US-EAST-1). ¡Verifica la AMI en tu región!
  instance_type = "t2.micro"
  
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # Script que se ejecuta al iniciar la instancia (User Data)
  # Aquí instalamos Docker y corremos TU imagen creada en GitHub Actions
  user_data = base64encode(<<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker
              service docker start
              usermod -a -G docker ec2-user
              # REEMPLAZA 'tu_usuario_dockerhub' con tu usuario real
              docker run -d -p 80:80 ehpaucar/hola-mundo-aws:latest
              EOF
  )
}

# 3. Load Balancer (Application Load Balancer)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb" "app_lb" {
  name               = "hola-mundo-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "app_tg" {
  name     = "hola-mundo-tg"
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

# 4. Auto Scaling Group (ASG) - Instancias de 3 a 7
resource "aws_autoscaling_group" "app_asg" {
  name                = "hola-mundo-asg-prod"
  desired_capacity    = 3
  max_size            = 7
  min_size            = 3
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.app_tg.arn]

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }
}

# 5. Scaling Policy: Basada en Tráfico de Red (Network In)
# Te pidieron atacar una regla sobre "concurrencia de tráfico en red"
resource "aws_autoscaling_policy" "network_policy" {
  name                   = "escala-por-red"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageNetworkIn" 
    }
    
    # Ejemplo: Si el tráfico promedio de entrada supera 500,000 bytes, escala.
    # Ajusta este valor bajo para probarlo, o alto para producción.
    target_value = 500000.0 
  }
}