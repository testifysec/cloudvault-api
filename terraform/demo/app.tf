# The CloudVault GUI itself: one small host running the repo's docker-compose stack
# (api + postgres + minio) on a public IP. Demo only; no TLS, no persistence guarantees.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "CloudVault demo host"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "CloudVault GUI"
    from_port   = 8080
    to_port     = 8080
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

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-app"
  role = aws_iam_role.app.name
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y docker git
    systemctl enable --now docker
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -sSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    git clone --depth 1 https://github.com/cloudvault-dev/cloudvault-api.git /opt/cloudvault
    cd /opt/cloudvault
    docker compose up -d --build
  EOT

  tags = { Name = "${local.name}-app" }
}
