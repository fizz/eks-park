# The AWS side of what eks-park needs, scoped to one cluster wherever the API
# allows it. Describe and List calls do not support resource scoping, so those
# are "*"; every call that changes something is pinned to the cluster's own
# nodegroups, instances, ASGs, load balancers and record.

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

variable "cluster_name" {
  description = "The EKS cluster eks-park parks."
  type        = string
}

variable "name" {
  description = "Name of the IAM policy. Defaults to eks-park-<cluster_name>."
  type        = string
  default     = null
}

variable "state_param" {
  description = "SSM parameter eks-park keeps its record in. Must match --state-param."
  type        = string
  default     = null
}

variable "delete_lbs" {
  description = "Grant what --delete-lbs needs: deleting the cluster's load balancers and moving their DNS records."
  type        = bool
  default     = false
}

variable "hosted_zone_ids" {
  description = "Route53 zones --delete-lbs may change. Empty means every zone in the account."
  type        = list(string)
  default     = []
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  p           = data.aws_partition.current.partition
  region      = data.aws_region.current.region
  account     = data.aws_caller_identity.current.account_id
  state_param = coalesce(var.state_param, "/eks-park/${var.cluster_name}")
  zone_arns = length(var.hosted_zone_ids) > 0 ? [
    for z in var.hosted_zone_ids : "arn:${local.p}:route53:::hostedzone/${z}"
  ] : ["arn:${local.p}:route53:::hostedzone/*"]
}

data "aws_iam_policy_document" "this" {
  statement {
    sid = "Read"
    actions = [
      "eks:DescribeCluster",
      "eks:ListNodegroups",
      "eks:DescribeNodegroup",
      "autoscaling:DescribeAutoScalingGroups",
      "tag:GetResources",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeInstanceHealth",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "Nodegroups"
    actions = ["eks:UpdateNodegroupConfig"]
    resources = [
      "arn:${local.p}:eks:${local.region}:${local.account}:nodegroup/${var.cluster_name}/*/*",
    ]
  }

  # Managed nodegroup instances and ASGs carry eks:cluster-name.
  statement {
    sid       = "Instances"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:${local.p}:ec2:${local.region}:${local.account}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/eks:cluster-name"
      values   = [var.cluster_name]
    }
  }

  statement {
    sid       = "AutoscalerTag"
    actions   = ["autoscaling:DeleteTags", "autoscaling:CreateOrUpdateTags"]
    resources = ["arn:${local.p}:autoscaling:${local.region}:${local.account}:autoScalingGroup:*:autoScalingGroupName/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/eks:cluster-name"
      values   = [var.cluster_name]
    }
  }

  statement {
    sid       = "Record"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["arn:${local.p}:ssm:${local.region}:${local.account}:parameter${local.state_param}"]
  }

  dynamic "statement" {
    for_each = var.delete_lbs ? [1] : []
    content {
      sid       = "DeleteLoadBalancers"
      actions   = ["elasticloadbalancing:DeleteLoadBalancer"]
      resources = ["arn:${local.p}:elasticloadbalancing:${local.region}:${local.account}:loadbalancer/*"]
      condition {
        test     = "StringEquals"
        variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
        values   = [var.cluster_name]
      }
    }
  }

  dynamic "statement" {
    for_each = var.delete_lbs ? [1] : []
    content {
      sid       = "DnsRead"
      actions   = ["route53:ListHostedZones", "route53:GetChange", "cloudfront:ListDistributions"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.delete_lbs ? [1] : []
    content {
      sid       = "DnsWrite"
      actions   = ["route53:ListResourceRecordSets", "route53:ChangeResourceRecordSets"]
      resources = local.zone_arns
    }
  }
}

resource "aws_iam_policy" "this" {
  name        = coalesce(var.name, "eks-park-${var.cluster_name}")
  description = "Park and unpark EKS cluster ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.this.json
}

output "policy_arn" {
  value = aws_iam_policy.this.arn
}

output "policy_json" {
  value = data.aws_iam_policy_document.this.json
}
