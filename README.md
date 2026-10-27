# eks-park

Switch an EKS cluster's compute off for a while, and back on exactly as it was.

The control plane bills whether anything runs or not, but nodes are most of the cost of a quiet cluster. Scaling a managed nodegroup to zero looks like one API call. In practice it fails in four ways, and `eks-park` handles each:

- **The cluster-autoscaler brings the nodes back.** A minimum and desired size of 0 do not constrain it, and EKS rejects a maximum of 0. A full park scales the autoscaler to 0. A partial park cannot do that, because the nodegroups that stay up still need it. So it removes the autoscaler's auto-discovery tag from the parked nodegroups' ASGs instead, and unpark puts the tag back.
- **The drain deadlocks.** Scaling to 0 drains the nodes, and a drain stops at the first pod with an `emptyDir` or a PodDisruptionBudget that allows 0 disruptions. Park terminates the instances after it sets the size.
- **The sizes get lost.** Park records each nodegroup's scaling config in one SSM parameter before it changes anything. Unpark takes no sizes, and the person who unparks does not need to be the person who parked. A second park of a parked cluster keeps the recorded sizes. It does not overwrite them with zeros.
- **A load balancer bills with nothing behind it.** With `--delete-lbs`, park deletes the cluster's load balancers that have no healthy targets. First it moves their DNS records to a parked page and waits for Route53 to report the change `INSYNC`. Unpark moves the records back to the load balancer that the controller rebuilds.

Park also suspends the CronJobs that would have nowhere to run, so a weekend of missed schedules does not all fire at once on unpark. Before it changes anything, it checks that every image outside ECR can still be pulled.

## Usage

```bash
eks-park status my-cluster --region us-east-1
eks-park park   my-cluster --region us-east-1 --dry-run
eks-park park   my-cluster --region us-east-1 --delete-lbs
eks-park park   my-cluster --region us-east-1 --only batch,gpu
eks-park unpark my-cluster --region us-east-1
eks-park check  my-cluster --region us-east-1
```

| Option | Effect |
|---|---|
| `--region R` | AWS region. Defaults to `$AWS_REGION`. Every call names it. |
| `--context C` | kubectl context. Defaults to the cluster name. |
| `--state-param P` | SSM parameter for the record. Defaults to `/eks-park/<cluster>`. |
| `--only a,b` | Park only these nodegroups. |
| `--except a,b` | Park every nodegroup except these. |
| `--delete-lbs` | Delete load balancers with no healthy targets, after their DNS records point at a parked page. |
| `--parked-page D` | The CloudFront domain to point records at. Without it, eks-park looks for the distribution whose comment is `Parked page for <zone>`. |
| `--zone Z` | Look for records only in this hosted zone. Repeatable. |
| `--allow-dangling` | Delete a load balancer even when one of its records has no parked page to move to. |
| `--skip-image-check` | Do not check that images can still be pulled. |
| `--timeout S` | How long to wait for instances, nodes and load balancers. Default 600. |
| `--pod-settle S` | How long pods get to start after unpark before the check. Default 300. |
| `--no-check` | Unpark without the pod check. Run `eks-park check` once your other steps finish. |
| `--dry-run` | Print every change and make none. |

Unpark reads everything from the record. You do not repeat the park options.

## Unpark exit code

A cold start is noisy. Pods stay Pending while nodes join, pull images, and crash once or twice while their dependencies come up. None of that is a failure, and an unpark that exits 1 on it teaches people to ignore the exit code.

So unpark waits up to `--pod-settle` seconds, then exits 1 only for pods that will never start on their own:

- **An image that does not exist:** `InvalidImageName`, or a pull refused as not found. A rate limit or a network error is not in this group.
- **A volume in a zone with no node.** The scheduler reports `volume node affinity conflict`, and the pod stays Pending until a node comes up in that zone. [eks-pv-az](https://github.com/fizz/eks-pv-az) finds and fixes these.

Pods still starting at the deadline are listed as a warning, and the exit code stays 0.

When something should run between unpark and the check, for example a step that moves stranded volumes, use `unpark --no-check` and then `check`. Do not let the check fail on pods that the next step is about to fix: a failed step skips the steps after it.

## Running it from GitHub Actions

[`examples/github-actions/park.yml`](examples/github-actions/park.yml) is a dispatch-only workflow with `status`, `park` and `unpark`, and a dry run by default. With it, anyone with write access to the repo can unpark the cluster. It runs one job at a time per cluster, so a park and an unpark cannot race.

The role it assumes needs two grants:

- **AWS:** [`terraform/iam-policy`](terraform/iam-policy) builds a policy scoped to one cluster. `ec2:TerminateInstances` and the ASG tag calls are allowed only on resources tagged `eks:cluster-name=<cluster>`. `DeleteLoadBalancer` is allowed only on load balancers tagged `elbv2.k8s.aws/cluster=<cluster>`, and only with `delete_lbs = true`.

  ```hcl
  module "eks_park" {
    source       = "github.com/fizz/eks-park//terraform/iam-policy?ref=v1.0.0"
    cluster_name = "my-cluster"
    delete_lbs   = true
  }
  ```

- **Kubernetes:** [`examples/rbac.yaml`](examples/rbac.yaml) defines the ClusterRole. Bind it through an EKS access entry with the Kubernetes group `eks-park`.

Pin the role's OIDC trust to `refs/heads/main`. Then the workflow file on the default branch is the only one that can assume the role.

## Requirements

- `bash` 4.4 or later (macOS ships 3.2; `brew install bash`)
- `aws` (CLI v2)
- `jq`
- `kubectl`
- `crane`, for the image check. It is optional: without it, eks-park prints a warning and skips the check.

## Limits

- **Managed nodegroups only.** Self-managed node groups and Karpenter are not handled.
- **The autoscaler tag works with auto-discovery only.** A cluster-autoscaler given explicit `--nodes` flags ignores the tag.
- **CronJob placement on a partial park checks `nodeSelector` only.** A CronJob that needs required node affinity or a toleration can be suspended when it could have run.
- **`--delete-lbs` skips in-tree Service load balancers.** The in-tree controller runs in the control plane, which a park does not stop, and it would rebuild the load balancer at once.

## Related

- [terraform-aws-parked-page](https://github.com/fizz/terraform-aws-parked-page): the parked page that `--delete-lbs` points DNS at.
- [eks-pv-az](https://github.com/fizz/eks-pv-az): finds pods held Pending by a volume in a zone with no node.
- [fargate-park](https://github.com/fizz/fargate-park): the same idea for ECS on Fargate.

## License

MIT
