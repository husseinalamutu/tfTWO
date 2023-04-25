terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}


# Create an ami
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_default_vpc" "default" {
}

# Provision the security group
resource "aws_security_group" "greymatter" {
  egress = [{
    cidr_blocks      = ["0.0.0.0/0"]
    description      = ""
    from_port        = 0
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "-1"
    security_groups  = []
    self             = false
    to_port          = 0
  }]

  ingress = [{
    cidr_blocks      = ["0.0.0.0/0"]
    description      = "allow ssh"
    from_port        = 22
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups  = []
    self             = false
    to_port          = 22
    },
    {
      cidr_blocks      = ["0.0.0.0/0"]
      description      = "allow http"
      from_port        = 80
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      protocol         = "tcp"
      security_groups  = []
      self             = false
      to_port          = 80
  }]
}

resource "aws_default_subnet" "default_az1" {
  availability_zone = "us-east-1d"

  tags = {
    Name = "Default subnet for us-east-1d"
  }
}
resource "aws_default_subnet" "default_az2" {
  availability_zone = "us-east-1b"

  tags = {
    Name = "Default subnet for us-east-1b"
  }
}

resource "aws_instance" "nginx" {
  ami = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name = var.key_name
  vpc_security_group_ids = [aws_security_group.greymatter.id]
  user_data = file("nginx.sh")
  tags = { 
    Name  = "NGINX"
  }
}

# Provision Apache-EC2 Instances
resource "aws_instance" "apache" {
  ami = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name = var.key_name
  vpc_security_group_ids = [aws_security_group.greymatter.id]
  user_data = file("apache.sh")
  tags = { 
    Name  = "APACHE"
  }
}

# Create a target group

resource "aws_lb_target_group" "greymatter" {
  name     = "greymatter-lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id = aws_default_vpc.default.id
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    enabled             = true
  }
}

# Attach NGINX Instance to load balancer target group

resource "aws_lb_target_group_attachment" "nginx-instance" {
  target_group_arn = aws_lb_target_group.greymatter.arn
  target_id        = aws_instance.nginx.id
  port             = 80
}

# Attach APACHE Instance to load balancer target group

resource "aws_lb_target_group_attachment" "apache-instance" {
  target_group_arn = aws_lb_target_group.greymatter.arn
  target_id        = aws_instance.apache.id
  port             = 80
}

# Create Load Balancer

resource "aws_lb" "greymatter" {
  name               = "greymatter-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.greymatter.id]
  subnets = [aws_default_subnet.default_az1.id, aws_default_subnet.default_az2.id]
  tags = {
    Name = "greymatterLB"
  }
}

# Create a Load Balancer Listener Resource

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.greymatter.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.greymatter.arn
  }
}

# Add auto scale capabilities to the EC2 instances
resource "aws_launch_template" "greymatter" {
  name_prefix            = "nginx-temp"
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.greymatter.id]
  user_data              = file("nginx.sh")

   tag_specifications {
    resource_type = "instance"
    tags = {
      Name : "nginx-temp"
    }
  }
}

resource "aws_autoscaling_group" "greymatter" {
  name                      = "greymatter"
  availability_zones = ["us-east-1b", "us-east-1d"]
  max_size                  = 10
  min_size                  = 2
  desired_capacity          = 2
  target_group_arns         = [aws_lb_target_group.greymatter.arn]

  launch_template {
    id      = aws_launch_template.greymatter.id
    version = "$Latest"
  }
}

output "lb-dns-name" {
  description = "Load Balancer DNS name"
  value       = aws_lb.greymatter.dns_name
}
