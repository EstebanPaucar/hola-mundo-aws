terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ==========================================
# PROVIDER CONFIGURATION (2 ACCOUNTS)
# ==========================================

# ACCOUNT 1: FRONTEND (Uses standard environment variables)
provider "aws" {
  region = "us-east-1"
}

# ACCOUNT 2: BACKEND (Uses an alias and specific variables)
provider "aws" {
  alias      = "backend_account"
  region     = "us-east-1"
  
  # These variables are populated from GitHub Actions
  access_key = var.aws_access_key_2
  secret_key = var.aws_secret_key_2
  token      = var.aws_session_token_2
}

# Define variables to receive Account 2 credentials
variable "aws_access_key_2" { type = string }
variable "aws_secret_key_2" { type = string }
variable "aws_session_token_2" { type = string }


# ==========================================
# PART A: FRONTEND INFRASTRUCTURE (ACCOUNT 1)
# ==========================================

# 1. Frontend Security
resource "aws_security_group" "frontend_sg" {
  name        = "frontend-sg"
  description = "Allow HTTP for Frontend"

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

# 2. Frontend Launch Template
resource "aws_launch_template" "frontend_lt" {
  name_prefix   = "frontend-lt-"
  image_id      = "ami-0ebfd941bbafe70c6" # Amazon Linux 2023
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.frontend_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y docker
    service docker start
    usermod -a -G docker ec2-user
    # FRONTEND IMAGE
    docker run -d -p 80:80 ehpaucar/hola-mundo-aws:latest
  EOF
  )
}

# 3. Frontend ALB
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb" "frontend_lb" {
  name               = "frontend-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.frontend_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "frontend_tg" {
  name     = "frontend-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check { path = "/" }
}

resource "aws_lb_listener" "frontend_listener" {
  load_balancer_arn = aws_lb.frontend_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }
}

# 4. Frontend ASG (With the 3 requested rules)
resource "aws_autoscaling_group" "frontend_asg" {
  name                = "frontend-asg"
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.frontend_tg.arn]
  desired_capacity    = 2
  min_size            = 2
  max_size            = 3

  launch_template {
    id      = aws_launch_template.frontend_lt.id
    version = "$Latest"
  }
}

# Frontend Scaling Policies
resource "aws_autoscaling_policy" "front_cpu" {
  name                   = "front-cpu-policy"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 50.0
  }
}

resource "aws_autoscaling_policy" "front_net" {
  name                   = "front-net-policy"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageNetworkIn" }
    target_value = 500000.0
  }
}

resource "aws_autoscaling_policy" "front_mem" {
  name                   = "front-mem-policy"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
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
# PART B: BACKEND INFRASTRUCTURE (ACCOUNT 2)
# ==========================================

# 1. Network Data Account 2 (Using provider alias)
data "aws_vpc" "backend_vpc" {
  provider = aws.backend_account 
  default  = true
}

data "aws_subnets" "backend_subnets" {
  provider = aws.backend_account
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.backend_vpc.id]
  }
}

# 2. Backend Security
resource "aws_security_group" "backend_sg" {
  provider    = aws.backend_account
  name        = "backend-sg"
  description = "Allow HTTP Backend"
  vpc_id      = data.aws_vpc.backend_vpc.id

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

# 3. Backend Launch Template
resource "aws_launch_template" "backend_lt" {
  provider      = aws.backend_account
  name_prefix   = "backend-lt-"
  image_id      = "ami-0ebfd941bbafe70c6" # Same ID if both accounts are in us-east-1
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.backend_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y docker
    service docker start
    usermod -a -G docker ec2-user
    # BACKEND IMAGE
    docker run -d -p 80:80 ehpaucar/hola-mundo-backend:latest
  EOF
  )
}

# 4. Backend ALB
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
  vpc_id   = data.aws_vpc.backend_vpc.id
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

# 5. Backend ASG (2 fixed instances as per requirement)
resource "aws_autoscaling_group" "backend_asg" {
  provider            = aws.backend_account
  name                = "backend-asg"
  vpc_zone_identifier = data.aws_subnets.backend_subnets.ids
  target_group_arns   = [aws_lb_target_group.backend_tg.arn]
  desired_capacity    = 2
  min_size            = 2
  max_size            = 2

  launch_template {
    id      = aws_launch_template.backend_lt.id
    version = "$Latest"
  }
}

# ==========================================
# FINAL OUTPUTS
# ==========================================
output "frontend_dns" {
  value = aws_lb.frontend_lb.dns_name
  description = "Frontend URL (Account 1)"
}

output "backend_dns" {
  value = aws_lb.backend_lb.dns_name
  description = "Backend URL (Account 2)"
}