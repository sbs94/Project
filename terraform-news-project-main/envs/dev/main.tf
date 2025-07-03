# ─────────────────────────────
# 네트워킹
# ─────────────────────────────

module "vpc" {
  source = "../../modules/networking/vpc"
}

module "subnet" {
  source = "../../modules/networking/subnet"
  vpc_id = module.vpc.vpc_id
  depends_on = [module.vpc]
}

module "igw" {
  source = "../../modules/networking/igw"
  vpc_id = module.vpc.vpc_id
  depends_on = [module.subnet]
}

module "nat" {
  source           = "../../modules/networking/nat"
  public_subnet_id = module.subnet.public_subnet_ids[0]
  depends_on = [module.subnet]
}

module "route" {
  source             = "../../modules/networking/route"
  vpc_id             = module.vpc.vpc_id
  igw_id             = module.igw.igw_id
  public_subnet_ids  = module.subnet.public_subnet_ids
  private_subnet_ids = module.subnet.private_subnet_ids
  nat_gateway_id     = module.nat.nat_gateway_id
  depends_on = [module.nat, module.igw]
}

module "security_group" {
  source = "../../modules/networking/security_group"
  vpc_id = module.vpc.vpc_id
  depends_on = [module.vpc]
}

# ─────────────────────────────
# IAM 및 클러스터
# ─────────────────────────────

module "iam" {
  source = "../../modules/iam"
}

module "eks" {
  source        = "../../modules/eks"
  cluster_name  = "news-cluster"
  subnet_ids    = module.subnet.public_subnet_ids
  eks_role_arn  = module.iam.eks_cluster_role_arn
  node_role_arn = module.iam.eks_node_role_arn

  depends_on = [
    module.subnet,
    module.iam
  ]
}

# ─────────────────────────────
# 데이터베이스
# ─────────────────────────────

module "rds" {
  source             = "../../modules/rds"
  name               = "news-rds"
  subnet_ids         = module.subnet.private_subnet_ids
  instance_class     = "db.t3.micro"
  allocated_storage  = 20
  username           = var.lambda_env["DB_USER"]
  password           = var.lambda_env["DB_PASSWORD"]
  db_name            = var.lambda_env["DB_NAME"]
  security_group_ids = [module.security_group.rds_sg_id]

  depends_on = [
    module.subnet,
    module.security_group
  ]
}

# ─────────────────────────────
# Lambda & Layer
# ─────────────────────────────

module "lambda_layer" {
  source     = "../../modules/lambda/layer"
}

module "sql_initializer" {
  source                   = "../../modules/lambda/sql_initializer"
  lambda_role_arn          = module.iam.lambda_role_arn
  db_host                  = module.rds.rds_endpoint
  db_user                  = var.lambda_env["DB_USER"]
  db_password              = var.lambda_env["DB_PASSWORD"]
  db_name                  = var.lambda_env["DB_NAME"]
  private_subnet_ids       = module.subnet.private_subnet_ids
  lambda_security_group_id = module.security_group.app_sg_id
  pymysql_layer_arn        = module.lambda_layer.pymysql_layer_arn

  depends_on = [
    module.rds,
    module.lambda_layer
  ]
}

module "docker_images" {
  source = "../../modules/lambda/docker_images"

  lambda_exec_role_arn   = module.iam.lambda_role_arn
  private_subnet_ids     = module.subnet.private_subnet_ids
  rds_sg_id              = module.security_group.rds_sg_id
  rds_endpoint           = module.rds.rds_endpoint
  rds_port               = "3306"
  rds_username           = var.lambda_env["DB_USER"]
  rds_db_name            = var.lambda_env["DB_NAME"]
  db_password = var.lambda_env["DB_PASSWORD"]
  docker_image_uri = var.docker_image_uri
}

module "sending_news" {
  source            = "../../modules/lambda/sending_news"
  function_name     = "news-lambda-handler"
  lambda_role_arn   = module.iam.lambda_role_arn
  handler           = "lambda_function.lambda_handler"
  runtime           = "python3.11"
  filename          = "${path.module}/../../zip/lambda_function.zip"
  pymysql_layer_arn = module.lambda_layer.pymysql_layer_arn
  subnet_ids        = module.subnet.private_subnet_ids
  security_group_id = module.security_group.app_sg_id

  environment = merge(
    var.lambda_env,
    {
      DB_HOST = module.rds.rds_endpoint
      SES_SENDER = var.lambda_env["SES_SENDER"]
    }
  )

  depends_on = [
    module.rds,
    module.lambda_layer
  ]
}

module "eventbridge_scheduler" {
  source = "../../modules/lambda/eventbridge_scheduler"

  lambda_schedules = {
    crawler = {
      description          = "Crawler runs every hour"
      schedule_expression  = "cron(50 0-23 ? * MON-FRI *)"
      lambda_function_name = module.docker_images.lambda_function_name
      lambda_function_arn  = module.docker_images.lambda_function_arn
      target_id            = "crawler"
    }
    sending_news = {
      description          = "Send news weekdays at 9AM"
      schedule_expression  = "cron(0 * ? * MON-FRI *)"
      lambda_function_name = module.sending_news.lambda_function_name
      lambda_function_arn  = module.sending_news.lambda_function_arn
      target_id            = "sending-news"
    }
  }
}

# ─────────────────────────────
# Monitoring
# ─────────────────────────────

module "monitoring" {
  source                 = "../../modules/monitoring"
  region                 = "ap-northeast-2"
  rds_instance_id        = module.rds.rds_identifier
  grafana_admin_password = "SuperSecret123"
  lambda_function_names = {
    sending_news = module.sending_news.lambda_function_name
    crawler      = module.docker_images.lambda_function_name
  }
  alert_emails    = [
    "95eksldpf@gmail.com",
    "skdurtlxx@gmail.com",
    "jintonylove@gmail.com",
    "sunyj1225@gmail.com",
    "oosuoos@gmail.com"
  ]

  eks_oidc_provider_arn = module.eks.oidc_provider_arn
  eks_oidc_provider_url = module.eks.oidc_provider_url

  grafana_service_account_name      = "grafana"
  grafana_service_account_namespace = "monitoring"
}

# ─────────────────────────────
# EKS 클러스터 정보 주입용 데이터 소스
# ─────────────────────────────

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "58.0.1"

  depends_on = [module.eks]
}
