output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "files_bucket" {
  value = module.s3.bucket_id
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "cloudtrail_arn" {
  value = aws_cloudtrail.main.arn
}

output "app_url" {
  value = "http://${aws_instance.app.public_ip}:8080"
}
