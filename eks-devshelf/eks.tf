module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets   # nodes live in private subnets - no direct internet inbound

  cluster_endpoint_public_access = true   # needed since you're managing this from outside the VPC (your laptop)

  eks_managed_node_groups = {
    devshelf_nodes = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # This is the critical permission that lets nodes pull from ECR -
      # without it every pod sits in ImagePullBackOff forever
      iam_role_additional_policies = {
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }
    }
  }

  tags = {
    Project = "devshelf"
  }
}
