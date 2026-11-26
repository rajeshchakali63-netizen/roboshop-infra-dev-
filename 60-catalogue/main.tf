resource "aws_instance" "catalogue" {
  ami           = local.ami_id
  instance_type = "t3.micro"
  subnet_id     = local.private_subnet_id
  vpc_security_group_ids = [local.catalogue_sg_id]
   tags = merge(
    local.common_tags,
    {
        Name = "${local.common_name}-catalogue"
    }
   )
}

  resource "terraform_data" "bootstrap" {
  triggers_replace = [
    aws_instance.catalogue.id
  ]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    password = "DevOps321"
    host        = aws_instance.catalogue.private_ip
  }

  provisioner "file" {
    source      = "${path.module}/bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

   provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/bootstrap.sh",
      "sudo sh /tmp/bootstrap.sh catalogue  ${var.environment} ${var.app_version}"
    ]
  }
}

resource "aws_ec2_instance_state" "catalogue" {
  instance_id = aws_instance.catalogue.id
  state       = "stopped" # Options: "running" or "stopped"
  depends_on = [ terraform_data.bootstrap ]
}

resource "aws_ami_from_instance" "catalogue" {
  name               = "${local.common_name}-catalogue-${var.app_version}-${aws_instance.catalogue.id}"   # roboshop-dev-catalogue-v4-instance_id
  source_instance_id = aws_instance.catalogue.id
  depends_on = [ aws_ec2_instance_state.catalogue ]

  tags = merge(
    local.common_tags,
    {
        Name = "${local.common_name}-catalogue-${var.app_version}-${aws_instance.catalogue.id}"
    }
  )
}

# launch template
resource "aws_launch_template" "catalogue" {
  name = "${local.common_name}-Catalogue"

  image_id = aws_ami_from_instance.catalogue.id
  instance_initiated_shutdown_behavior = "terminate"

  instance_type = "t3.micro"
  vpc_security_group_ids = [local.catalogue_sg_id]
  update_default_version = true
  tag_specifications {
    resource_type = "instance"

    tags = merge(
    local.common_tags,
    {
        Name = "${local.common_name}-catalogue"
    }
   )
  }
  tag_specifications {
    resource_type = "volume"

    tags = merge(
        local.common_tags,
        {
            Name = "${local.common_name}-catalogue"
        }
    )
  }
}

resource "aws_lb_target_group" "catalogue" {
  name        = "${local.common_name}-catalogue"
  target_type = "alb"
  port        = 8080
  protocol    = "TCP"
  vpc_id      = local.vpc_id
  deregistration_delay = 10

   health_check {
    enabled             = true
    path                = "/health"
    port                = "8080"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
    matcher             = "200-299"
  }
}

resource "aws_autoscaling_group" "catalogue" {
  name                = "${local.common_name}-catalogue"
  vpc_zone_identifier = [local.private_subnet_ids] # Replace with your Subnet IDs
  min_size            = 1 # All the time, it should maintain atleast 1
  max_size            = 4 # Autosccaling can create max upto 4 instances
  desired_capacity    = 2 # Start with 2 instances  
  health_check_type   = "EC2" # Change to "ELB" if attaching a Load Balancer

  launch_template {
    id      = aws_launch_template.catalogue.id
    version = "$Latest"
  }

   target_group_arns = [aws_lb_target_group.catalogue.arn]

   instance_refresh{
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["launch_template"]
  }

  dynamic "tag" {
    for_each = merge(
      local.common_tags,
      {
        Name = "${local.common_name}-catalogue"
      }
    )
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    } 
  }
  timeouts {
    delete = "15m"
  }
}

resource "aws_autoscaling_policy" "catalogue" {
  name                   = "${local.common_name}-catalogue"
  autoscaling_group_name = aws_autoscaling_group.catalogue.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

# Forward action

resource "aws_lb_listener_rule" "catalogue" {
  listener_arn = local.backend_alb_listener_arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.catalogue.arn
  }

  condition {
    host_header {
      values = ["catalogue.backend-alb-${var.environment}-${var.domain_name}"]
    }
  }
}

resource "terraform_data" "catalogue_delete" {
  triggers_replace = [
    aws_instance.catalogue.id
  ]
  depends_on = [aws_autoscaling_policy.catalogue]

  provisioner "local-exec" {
    command = "aws ec2 terminate-instances --instance-ids ${aws_instance.catalogue.id}"
  }
}


