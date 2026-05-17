# ecr.tf — container registry for this region.
#
# ECR is a regional service; each region gets its own repository. cloud-up.sh
# pushes the same image tag to every region's repo.

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "2.4.0" # exact pin (case-study reproducibility); was ~> 2.3

  repository_name                 = var.name_prefix
  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true # DevSecOps signal — scan on push

  repository_lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain last 10 images; expire older"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
