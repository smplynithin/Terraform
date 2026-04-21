# 🛠️ Step-by-Step Execution Guide
## AWS 3-Tier Web App — Terraform Project

> **Prerequisites assumed:** Intermediate Linux, Git, AWS knowledge
> **Time to complete:** ~90 minutes
> **Cost estimate:** ~$0.50–$1.50/hour on AWS (destroy when done!)

---

## 📋 PHASE 0: System Setup (One-time)

### Step 0.1 — Launch an EC2 Ubuntu Instance (Your Terraform Workstation)

Use an existing Ubuntu EC2 or your local Linux machine.

```bash
# Recommended: t2.micro Ubuntu 22.04 LTS in ap-south-1
# Attach an IAM Role with AdministratorAccess (or create one below)
```

**Create IAM Role for your workstation EC2:**
1. Go to AWS Console → IAM → Roles → Create Role
2. Trusted entity: EC2
3. Policy: `AdministratorAccess` (for learning; restrict in real projects)
4. Name it: `terraform-workstation-role`
5. Attach to your EC2: EC2 Console → Actions → Security → Modify IAM Role

### Step 0.2 — Install Terraform

```bash
# SSH into your workstation EC2
ssh -i your-key.pem ubuntu@<ec2-public-ip>

# Install dependencies
sudo apt-get update -y
sudo apt-get install -y gnupg software-properties-common curl unzip wget git

# Add HashiCorp GPG key
wget -O- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

# Add HashiCorp repo
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

# Install Terraform
sudo apt-get update -y
sudo apt-get install -y terraform

# Verify
terraform --version
# Expected: Terraform v1.x.x
```

### Step 0.3 — Install Vault (for Day 7 secret management)

```bash
# Vault is in the same HashiCorp repo, install directly
sudo apt-get install -y vault

# Verify
vault --version
# Expected: Vault v1.x.x
```

### Step 0.4 — Configure AWS CLI

```bash
# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# If using IAM Role on EC2 (recommended) — no config needed, just verify:
aws sts get-caller-identity
# Expected: JSON with your Account ID, UserID, ARN

# If using IAM User credentials instead:
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name: ap-south-1
# Default output format: json
```

---

## 📁 PHASE 1: Project Scaffold — Create All Files

### Step 1.1 — Create Project Directory Structure

```bash
# Go to home directory
cd ~

# Create full project tree
mkdir -p aws-3tier-webapp/modules/vpc
mkdir -p aws-3tier-webapp/modules/security_groups
mkdir -p aws-3tier-webapp/modules/alb
mkdir -p aws-3tier-webapp/modules/ec2
mkdir -p aws-3tier-webapp/modules/rds
mkdir -p aws-3tier-webapp/modules/s3
mkdir -p aws-3tier-webapp/scripts

# Go into project
cd aws-3tier-webapp

# Verify structure
find . -type d
```

**Expected output:**
```
.
./modules
./modules/vpc
./modules/security_groups
./modules/alb
./modules/ec2
./modules/rds
./modules/s3
./scripts
```

### Step 1.2 — Initialize Git Repository

```bash
cd ~/aws-3tier-webapp

git init
git config user.name "Your Name"
git config user.email "you@example.com"
```

### Step 1.3 — Create .gitignore (Day 4 — First!)

```bash
cat > .gitignore << 'EOF'
# Terraform state - NEVER commit
*.tfstate
*.tfstate.*
.terraform.tfstate.lock.info

# Terraform working directory
.terraform/
.terraform.lock.hcl

# Secret variable files
*.tfvars.local
secrets.tfvars

# Crash logs
crash.log
crash.*.log

# Override files
override.tf
override.tf.json
*_override.tf

# SSH Keys
*.pem
*.key

# Deployment logs (local only)
deployment.log

# OS files
.DS_Store
Thumbs.db
EOF

git add .gitignore
git commit -m "Add .gitignore"
```

---

## ☁️ PHASE 2: AWS Prerequisites (Before Terraform Init)

### Step 2.1 — Create S3 Bucket for Remote State

```bash
# IMPORTANT: Bucket name must be globally unique
# Replace "yourname" with something unique like your name + random number
BUCKET_NAME="terraform-state-nithin-$(date +%s)"
echo "Your bucket name: $BUCKET_NAME"
# Save this name! You'll put it in backend.tf

# Create bucket in ap-south-1
aws s3api create-bucket \
  --bucket $BUCKET_NAME \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1

# Enable versioning (so you can recover old states)
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket $BUCKET_NAME \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket $BUCKET_NAME \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "✅ S3 bucket created: $BUCKET_NAME"
```

### Step 2.2 — Create DynamoDB Table for State Locking

```bash
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1

echo "✅ DynamoDB table created: terraform-state-lock"
```

### Step 2.3 — Create EC2 Key Pair for SSH

```bash
# Create key pair and save private key
aws ec2 create-key-pair \
  --key-name terraform-webapp-key \
  --region ap-south-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/terraform-webapp-key.pem

# Set correct permissions (required for SSH)
chmod 400 ~/.ssh/terraform-webapp-key.pem

echo "✅ Key pair created: terraform-webapp-key"
ls -la ~/.ssh/terraform-webapp-key.pem
```

---

## 📝 PHASE 3: Write All Terraform Files

### Step 3.1 — backend.tf

```bash
# REPLACE the bucket name with YOUR actual bucket name from Step 2.1
cat > backend.tf << 'EOF'
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket         = "REPLACE-WITH-YOUR-BUCKET-NAME"
    key            = "3tier-webapp/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}
EOF
```

```bash
# ⚠️ Edit the file and put your actual bucket name
nano backend.tf
# Replace: REPLACE-WITH-YOUR-BUCKET-NAME
# With:    terraform-state-nithin-1234567890  (your bucket name from Step 2.1)
# Save: Ctrl+O → Enter → Ctrl+X
```

### Step 3.2 — providers.tf

```bash
cat > providers.tf << 'EOF'
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "3TierWebApp"
      Environment = terraform.workspace
      ManagedBy   = "Terraform"
      Owner       = var.owner
    }
  }
}

provider "vault" {
  address = var.vault_address
  token   = var.vault_token
}
EOF
```

### Step 3.3 — variables.tf

```bash
cat > variables.tf << 'EOF'
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "owner" {
  description = "Owner tag value"
  type        = string
  default     = "nithin"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.5.0/24", "10.0.6.0/24"]
}

variable "key_pair_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "terraform-webapp-key"
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "app_port" {
  type    = number
  default = 80
}

variable "enable_deletion_protection" {
  type    = bool
  default = false
}

variable "vault_address" {
  type    = string
  default = "http://127.0.0.1:8200"
}

variable "vault_token" {
  description = "Vault token (set via TF_VAR_vault_token env variable)"
  type        = string
  sensitive   = true
}
EOF
```

### Step 3.4 — locals.tf

```bash
cat > locals.tf << 'EOF'
locals {
  environment = terraform.workspace

  # Day 6: Conditional sizing based on workspace
  ec2_instance_type  = local.environment == "prod" ? "t3.medium" : "t3.micro"
  rds_instance_class = local.environment == "prod" ? "db.t3.medium" : "db.t3.micro"
  rds_multi_az       = local.environment == "prod" ? true : false
  ec2_instance_count = local.environment == "prod" ? 2 : 1

  # Day 2: Functions - format() and lower()
  name_prefix = format("%s-3tier", lower(local.environment))
  bucket_name = lower(format("webapp-assets-%s-%s-%s", local.environment, var.aws_region, "001"))

  common_tags = {
    Environment = local.environment
    Project     = "3TierWebApp"
    ManagedBy   = "Terraform"
  }
}
EOF
```

### Step 3.5 — vault.tf

```bash
cat > vault.tf << 'EOF'
# Day 7: Read DB password from Vault - never hardcode secrets!
data "vault_generic_secret" "db_password" {
  path = "secret/3tier-webapp/${local.environment}/db"
}
EOF
```

### Step 3.6 — main.tf

```bash
cat > main.tf << 'EOF'
# Day 3: Data sources - dynamically fetch information from AWS
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Module 1: VPC
module "vpc" {
  source = "./modules/vpc"

  name                 = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
  availability_zones   = slice(data.aws_availability_zones.available.names, 0, 2)
  tags                 = local.common_tags
}

# Module 2: Security Groups
module "security_groups" {
  source = "./modules/security_groups"

  name     = local.name_prefix
  vpc_id   = module.vpc.vpc_id
  app_port = var.app_port
  tags     = local.common_tags
}

# Module 3: S3
module "s3" {
  source      = "./modules/s3"
  bucket_name = local.bucket_name
  tags        = local.common_tags
}

# Module 4: RDS (password from Vault)
module "rds" {
  source = "./modules/rds"

  name                 = local.name_prefix
  db_subnet_group_name = module.vpc.db_subnet_group_name
  security_group_id    = module.security_groups.rds_sg_id
  db_username          = var.db_username
  db_password          = data.vault_generic_secret.db_password.data["password"]
  instance_class       = local.rds_instance_class
  multi_az             = local.rds_multi_az
  deletion_protection  = var.enable_deletion_protection
  tags                 = local.common_tags
}

# Module 5: ALB
module "alb" {
  source = "./modules/alb"

  name              = local.name_prefix
  public_subnet_ids = module.vpc.public_subnet_ids
  security_group_id = module.security_groups.alb_sg_id
  app_port          = var.app_port
  vpc_id            = module.vpc.vpc_id
  tags              = local.common_tags
}

# Module 6: EC2 App Servers
module "ec2" {
  source = "./modules/ec2"

  name                 = local.name_prefix
  instance_count       = local.ec2_instance_count
  instance_type        = local.ec2_instance_type
  ami_id               = data.aws_ami.amazon_linux.id
  key_pair_name        = var.key_pair_name
  private_subnet_ids   = module.vpc.private_subnet_ids
  security_group_id    = module.security_groups.ec2_sg_id
  alb_target_group_arn = module.alb.target_group_arn
  db_endpoint          = module.rds.db_endpoint
  s3_bucket_name       = module.s3.bucket_name
  tags                 = local.common_tags
}
EOF
```

### Step 3.7 — outputs.tf

```bash
cat > outputs.tf << 'EOF'
output "alb_dns_name" {
  description = "Open this URL in your browser to see the app"
  value       = module.alb.alb_dns_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "rds_endpoint" {
  value     = module.rds.db_endpoint
  sensitive = true
}

output "s3_bucket_name" {
  value = module.s3.bucket_name
}

output "ec2_instance_ids" {
  value = module.ec2.instance_ids
}

output "environment" {
  value = local.environment
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}
EOF
```

### Step 3.8 — terraform.tfvars

```bash
cat > terraform.tfvars << 'EOF'
aws_region    = "ap-south-1"
owner         = "nithin"
key_pair_name = "terraform-webapp-key"
app_port      = 80
enable_deletion_protection = false
vault_address = "http://127.0.0.1:8200"
# vault_token is NOT here — set via environment variable
EOF
```

---

## 📦 PHASE 4: Write All Module Files

### Step 4.1 — VPC Module

```bash
# modules/vpc/variables.tf
cat > modules/vpc/variables.tf << 'EOF'
variable "name"                 { type = string }
variable "vpc_cidr"             { type = string }
variable "public_subnet_cidrs"  { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "db_subnet_cidrs"      { type = list(string) }
variable "availability_zones"   { type = list(string) }
variable "tags"                 { type = map(string) }
EOF
```

```bash
# modules/vpc/main.tf
cat > modules/vpc/main.tf << 'EOF'
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags = merge(var.tags, { Name = "${var.name}-public-${count.index + 1}", Tier = "Public" })
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = merge(var.tags, { Name = "${var.name}-private-${count.index + 1}", Tier = "Private" })
}

resource "aws_subnet" "db" {
  count             = length(var.db_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = merge(var.tags, { Name = "${var.name}-db-${count.index + 1}", Tier = "Database" })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(var.tags, { Name = "${var.name}-nat" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = merge(var.tags, { Name = "${var.name}-private-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.name}-db-subnet-group"
  subnet_ids = aws_subnet.db[*].id
  tags       = merge(var.tags, { Name = "${var.name}-db-subnet-group" })
}
EOF
```

```bash
# modules/vpc/outputs.tf
cat > modules/vpc/outputs.tf << 'EOF'
output "vpc_id"               { value = aws_vpc.main.id }
output "public_subnet_ids"    { value = aws_subnet.public[*].id }
output "private_subnet_ids"   { value = aws_subnet.private[*].id }
output "db_subnet_ids"        { value = aws_subnet.db[*].id }
output "db_subnet_group_name" { value = aws_db_subnet_group.main.name }
EOF
```

### Step 4.2 — Security Groups Module

```bash
cat > modules/security_groups/variables.tf << 'EOF'
variable "name"     { type = string }
variable "vpc_id"   { type = string }
variable "app_port" { type = number }
variable "tags"     { type = map(string) }
EOF
```

```bash
cat > modules/security_groups/main.tf << 'EOF'
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB Security Group"
  vpc_id      = var.vpc_id

  ingress { from_port = 80;  to_port = 80;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "HTTP" }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "HTTPS" }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }

  tags = merge(var.tags, { Name = "${var.name}-alb-sg" })
}

resource "aws_security_group" "ec2" {
  name        = "${var.name}-ec2-sg"
  description = "EC2 App Server Security Group"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "From ALB only"
  }
  ingress { from_port = 22; to_port = 22; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "SSH" }
  egress  { from_port = 0;  to_port = 0;  protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }

  tags = merge(var.tags, { Name = "${var.name}-ec2-sg" })
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "RDS Security Group"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
    description     = "MySQL from EC2 only"
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }

  tags = merge(var.tags, { Name = "${var.name}-rds-sg" })
}
EOF
```

```bash
cat > modules/security_groups/outputs.tf << 'EOF'
output "alb_sg_id" { value = aws_security_group.alb.id }
output "ec2_sg_id" { value = aws_security_group.ec2.id }
output "rds_sg_id" { value = aws_security_group.rds.id }
EOF
```

### Step 4.3 — ALB Module

```bash
cat > modules/alb/variables.tf << 'EOF'
variable "name"              { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "app_port"          { type = number }
variable "vpc_id"            { type = string }
variable "tags"              { type = map(string) }
EOF
```

```bash
cat > modules/alb/main.tf << 'EOF'
resource "aws_lb" "main" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.public_subnet_ids
  tags               = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_lb_target_group" "main" {
  name     = "${var.name}-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }
  tags = merge(var.tags, { Name = "${var.name}-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}
EOF
```

```bash
cat > modules/alb/outputs.tf << 'EOF'
output "alb_dns_name"     { value = aws_lb.main.dns_name }
output "alb_arn"          { value = aws_lb.main.arn }
output "target_group_arn" { value = aws_lb_target_group.main.arn }
EOF
```

### Step 4.4 — RDS Module

```bash
cat > modules/rds/variables.tf << 'EOF'
variable "name"                 { type = string }
variable "db_subnet_group_name" { type = string }
variable "security_group_id"    { type = string }
variable "db_username"          { type = string }
variable "db_password"          { type = string; sensitive = true }
variable "instance_class"       { type = string }
variable "multi_az"             { type = bool }
variable "deletion_protection"  { type = bool }
variable "tags"                 { type = map(string) }
EOF
```

```bash
cat > modules/rds/main.tf << 'EOF'
resource "aws_db_instance" "main" {
  identifier        = "${var.name}-mysql"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.instance_class
  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  db_name  = "appdb"
  username = var.db_username
  password = var.db_password   # Day 7: From Vault!

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.security_group_id]

  multi_az            = var.multi_az
  publicly_accessible = false
  skip_final_snapshot = true
  deletion_protection = var.deletion_protection

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  tags = merge(var.tags, { Name = "${var.name}-mysql" })
}
EOF
```

```bash
cat > modules/rds/outputs.tf << 'EOF'
output "db_endpoint" { value = aws_db_instance.main.endpoint }
output "db_name"     { value = aws_db_instance.main.db_name }
EOF
```

### Step 4.5 — EC2 Module (with Provisioners)

```bash
cat > modules/ec2/variables.tf << 'EOF'
variable "name"                 { type = string }
variable "instance_count"       { type = number }
variable "instance_type"        { type = string }
variable "ami_id"               { type = string }
variable "key_pair_name"        { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "security_group_id"    { type = string }
variable "alb_target_group_arn" { type = string }
variable "db_endpoint"          { type = string }
variable "s3_bucket_name"       { type = string }
variable "tags"                 { type = map(string) }
EOF
```

```bash
cat > modules/ec2/main.tf << 'EOF'
resource "aws_instance" "app" {
  count         = var.instance_count
  ami           = var.ami_id
  instance_type = var.instance_type

  subnet_id              = var.private_subnet_ids[count.index % length(var.private_subnet_ids)]
  vpc_security_group_ids = [var.security_group_id]
  key_name               = var.key_pair_name

  user_data = templatefile("${path.root}/scripts/user_data.sh", {
    environment = var.name
    db_endpoint = var.db_endpoint
    s3_bucket   = var.s3_bucket_name
  })

  # Day 5: local-exec - runs on your LOCAL machine after EC2 is created
  provisioner "local-exec" {
    command = <<EOT
echo "========================================" >> deployment.log
echo "✅ EC2 Instance Provisioned!" >> deployment.log
echo "   Instance ID : ${self.id}" >> deployment.log
echo "   Private IP  : ${self.private_ip}" >> deployment.log
echo "   AZ          : ${self.availability_zone}" >> deployment.log
echo "   Time        : $(date)" >> deployment.log
echo "========================================" >> deployment.log
EOT
  }

  # Day 5: local-exec on DESTROY with on_failure handling
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "echo 'DESTROYED: ${self.id} at $(date)' >> deployment.log"
  }

  tags = merge(var.tags, { Name = "${var.name}-app-${count.index + 1}" })
}

resource "aws_lb_target_group_attachment" "app" {
  count            = var.instance_count
  target_group_arn = var.alb_target_group_arn
  target_id        = aws_instance.app[count.index].id
  port             = 80
}
EOF
```

```bash
cat > modules/ec2/outputs.tf << 'EOF'
output "instance_ids" { value = aws_instance.app[*].id }
output "private_ips"  { value = aws_instance.app[*].private_ip }
EOF
```

### Step 4.6 — S3 Module

```bash
cat > modules/s3/variables.tf << 'EOF'
variable "bucket_name" { type = string }
variable "tags"        { type = map(string) }
EOF
```

```bash
cat > modules/s3/main.tf << 'EOF'
resource "aws_s3_bucket" "assets" {
  bucket = var.bucket_name
  tags   = merge(var.tags, { Name = var.bucket_name })
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
EOF
```

```bash
cat > modules/s3/outputs.tf << 'EOF'
output "bucket_name" { value = aws_s3_bucket.assets.bucket }
output "bucket_arn"  { value = aws_s3_bucket.assets.arn }
EOF
```

### Step 4.7 — EC2 Bootstrap Script

```bash
cat > scripts/user_data.sh << 'SCRIPT'
#!/bin/bash
set -e

# Update packages
yum update -y

# Install Nginx
yum install -y nginx

# Create health check endpoint and landing page
mkdir -p /var/www/html

cat > /etc/nginx/conf.d/app.conf << 'NGINX'
server {
    listen 80;
    server_name _;

    location /health {
        return 200 "OK";
        add_header Content-Type text/plain;
    }

    location / {
        root /var/www/html;
        index index.html;
    }
}
NGINX

cat > /var/www/html/index.html << HTML
<!DOCTYPE html>
<html>
<head>
  <title>3-Tier App</title>
  <style>
    body { font-family: Arial; background: #f0f4f8; display: flex; justify-content: center; padding-top: 60px; }
    .card { background: white; padding: 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); max-width: 600px; }
    h1 { color: #2d3748; } p { color: #4a5568; }
    .tag { background: #ebf8ff; color: #2b6cb0; padding: 4px 12px; border-radius: 20px; font-size: 14px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>🚀 3-Tier Web App</h1>
    <p>Successfully deployed via <strong>Terraform!</strong></p>
    <p><span class="tag">Environment: ${environment}</span></p>
    <p>DB Endpoint: ${db_endpoint}</p>
    <p>S3 Bucket: ${s3_bucket}</p>
    <p>Deployed at: $(date)</p>
  </div>
</body>
</html>
HTML

# Start Nginx
systemctl enable nginx
systemctl start nginx

echo "Bootstrap done at $(date)" >> /var/log/tf-provision.log
SCRIPT
```

---

## 🔐 PHASE 5: Set Up HashiCorp Vault (Day 7)

```bash
# Open a new terminal / use tmux
# Start Vault in dev mode (for learning - NOT for production)
vault server -dev -dev-root-token-id="root" &

# Wait 2 seconds
sleep 2

# Export Vault environment variables
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# Verify Vault is running
vault status

# Store DB passwords for each environment (Day 7)
vault kv put secret/3tier-webapp/dev/db  password="DevSecure@123"
vault kv put secret/3tier-webapp/prod/db password="ProdSecure@456"

# Verify secrets were stored
vault kv get secret/3tier-webapp/dev/db
vault kv get secret/3tier-webapp/prod/db

# Set Terraform environment variable for the vault token
# Day 4: This is how you pass secrets WITHOUT putting them in tfvars
export TF_VAR_vault_token="root"
```

---

## 🚀 PHASE 6: Terraform Workflow (Days 1, 2, 4, 6)

### Step 6.1 — Format and Validate (Day 2)

```bash
cd ~/aws-3tier-webapp

# Auto-format all .tf files (Day 2: terraform fmt)
terraform fmt -recursive

# Validate syntax and logic (Day 2: debugging)
terraform validate
# Expected: Success! The configuration is valid.
```

### Step 6.2 — Initialize Terraform (Day 1 + Day 4)

```bash
# Download providers + configure S3 backend
terraform init

# Expected output:
# Initializing the backend...
# Successfully configured the backend "s3"!
# Initializing provider plugins...
# - Installing hashicorp/aws v5.x.x...
# - Installing hashicorp/vault v3.x.x...
# Terraform has been successfully initialized!
```

### Step 6.3 — Create and Switch to Dev Workspace (Day 6)

```bash
# See current workspaces (only 'default' exists)
terraform workspace list

# Create and switch to 'dev' workspace
terraform workspace new dev

# Verify you're in dev
terraform workspace show
# Expected: dev
```

### Step 6.4 — Plan the Deployment (Day 1)

```bash
# Preview all resources that will be created
terraform plan -out=dev.tfplan

# Read the plan output carefully:
# + means CREATE (green)
# ~ means MODIFY (yellow)
# - means DESTROY (red)

# Count the resources:
# Should be ~25-30 resources
```

### Step 6.5 — Apply (Deploy!) — Day 1

```bash
# Apply the saved plan
terraform apply dev.tfplan

# This will take 10-15 minutes (RDS takes longest)
# Watch the progress - each resource shows as it's created

# When done, you'll see outputs:
# alb_dns_name = "dev-3tier-alb-xxxxxxxx.ap-south-1.elb.amazonaws.com"
# environment  = "dev"
# s3_bucket_name = "webapp-assets-dev-ap-south-1-001"
```

### Step 6.6 — Verify the Deployment

```bash
# See all outputs
terraform output

# Open the app URL in browser (copy alb_dns_name from output)
ALB_URL=$(terraform output -raw alb_dns_name)
echo "Your app URL: http://$ALB_URL"

# Test health check
curl http://$ALB_URL/health
# Expected: OK

# Test the app
curl http://$ALB_URL/
# Expected: HTML page

# Check deployment log (created by local-exec provisioner)
cat deployment.log

# View Terraform state
terraform state list

# Inspect a specific resource
terraform state show module.vpc.aws_vpc.main
terraform state show module.alb.aws_lb.main
```

---

## 🔁 PHASE 7: Workspace Switch to PROD (Day 6)

```bash
# Switch to prod workspace
terraform workspace new prod
terraform workspace show
# Expected: prod

# In prod: t3.medium EC2, db.t3.medium RDS, Multi-AZ, 2 EC2s
# Run plan to see the difference
terraform plan -out=prod.tfplan

# Notice in the plan:
# instance_type = "t3.medium"  (was t3.micro in dev)
# multi_az      = true         (was false in dev)
# count         = 2            (was 1 in dev)

# Apply prod (separate state file from dev!)
terraform apply prod.tfplan

# Switch back to dev anytime
terraform workspace select dev
terraform output   # Shows dev outputs

terraform workspace select prod
terraform output   # Shows prod outputs
```

---

## 🧪 PHASE 8: Explore State and Modules (Day 3 & 4)

```bash
# Day 4: State commands
terraform state list              # List all resources
terraform state show module.rds.aws_db_instance.main   # Full details

# Day 3: Verify module outputs are flowing correctly
terraform output rds_endpoint     # Sensitive - shows [sensitive]
terraform output -raw rds_endpoint  # Shows actual value

# Day 4: The state is stored in S3, not locally
aws s3 ls s3://YOUR-BUCKET-NAME/3tier-webapp/
# You'll see: terraform.tfstate (per workspace, it's namespaced)

# Check DynamoDB lock table
aws dynamodb scan --table-name terraform-state-lock --region ap-south-1
# During apply, you'll see a LockID entry
```

---

## 🔧 PHASE 9: Make a Change (Terraform Lifecycle)

```bash
# Switch to dev workspace
terraform workspace select dev

# Example: Change the owner tag
# Edit terraform.tfvars
nano terraform.tfvars
# Change: owner = "nithin-updated"

# Plan shows only the tag change (no recreation)
terraform plan
# Should show: ~ update in-place (not destroy/recreate)

# Apply just the tag change
terraform apply -auto-approve

# Example: Scale EC2 (change local in locals.tf)
# Edit locals.tf - change ec2_instance_count for dev to 2
nano locals.tf
# ec2_instance_count = local.environment == "prod" ? 2 : 2

terraform plan    # Shows 1 new EC2 to add
terraform apply   # Adds the new EC2
```

---

## 🧹 PHASE 10: Cleanup (Destroy Resources)

```bash
# ⚠️ IMPORTANT: Always destroy when done learning to avoid AWS charges

# Destroy dev environment
terraform workspace select dev
terraform destroy
# Type "yes" when prompted
# Takes ~10-15 min

# Destroy prod environment
terraform workspace select prod
terraform destroy
# Type "yes" when prompted

# Delete S3 bucket and DynamoDB table (manual cleanup)
aws s3 rb s3://YOUR-BUCKET-NAME --force
aws dynamodb delete-table --table-name terraform-state-lock --region ap-south-1
aws ec2 delete-key-pair --key-name terraform-webapp-key --region ap-south-1
```

---

## ❗ Common Errors & Fixes

### Error 1: S3 Bucket Already Exists
```
Error: BucketAlreadyExists
Fix: Change bucket name in backend.tf to something more unique
     BUCKET_NAME="terraform-state-$(whoami)-$(date +%s)"
```

### Error 2: Vault Not Running
```
Error: Failed to read vault secret
Fix:
  vault server -dev -dev-root-token-id="root" &
  export VAULT_ADDR='http://127.0.0.1:8200'
  export VAULT_TOKEN='root'
  export TF_VAR_vault_token='root'
```

### Error 3: No Space Left on State Lock
```
Error: Error acquiring the state lock
Fix:
  terraform force-unlock <LOCK-ID>
  (get LOCK-ID from the error message)
```

### Error 4: AMI Not Found
```
Error: No AMI found for filter
Fix: The data source fetches the latest Amazon Linux 2023 - 
     check if al2023 is available in ap-south-1
     Run: aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-*-x86_64" --region ap-south-1 --query 'Images[0].ImageId'
```

### Error 5: Key Pair Not Found
```
Error: InvalidKeyPair.NotFound
Fix: Verify the key exists:
     aws ec2 describe-key-pairs --region ap-south-1
     If missing, re-run Step 2.3
```

### Error 6: DB subnet group already exists (re-run)
```
Error: DBSubnetGroupAlreadyExists
Fix: terraform state rm module.vpc.aws_db_subnet_group.main
     Then terraform apply again
```

---

## ✅ Final Checklist

```
[ ] Phase 0: Terraform, Vault, AWS CLI installed
[ ] Phase 1: All files created, .gitignore committed
[ ] Phase 2: S3 bucket, DynamoDB table, Key pair created
[ ] Phase 3: Root .tf files written (backend, providers, variables, locals, vault, main, outputs, tfvars)
[ ] Phase 4: All 6 modules written (vpc, security_groups, alb, rds, ec2, s3)
[ ] Phase 5: Vault running, secrets stored, TF_VAR_vault_token set
[ ] Phase 6: terraform init → fmt → validate → workspace new dev → plan → apply
[ ] Phase 7: Workspace new prod → plan (see size difference) → apply
[ ] Phase 8: Explored state commands and S3 remote state
[ ] Phase 9: Made a change, saw plan diff, applied
[ ] Phase 10: Destroyed both environments, cleaned up AWS resources
```

---

## 💡 Tips for Interviews

When asked "Tell me about a Terraform project you did":

> "I built a production-grade 3-tier AWS architecture using Terraform — a VPC with public/private/DB subnets across 2 AZs, an Application Load Balancer, EC2 instances behind it running Nginx, and an RDS MySQL database. I used 6 custom modules to keep the code reusable, S3 + DynamoDB for remote state and locking, workspaces for dev and prod environments with conditional sizing using expressions, remote-exec and local-exec provisioners for bootstrapping and deployment logging, and HashiCorp Vault to manage database secrets securely. The project covered IaC fundamentals, state management, collaboration practices, and secret management."
```
