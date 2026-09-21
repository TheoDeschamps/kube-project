# Discovery notes

| Name    | Instance ID         | Public IP      | Private IP | AMI                  |
|---------|----------------------|----------------|------------|-----------------------|
| kube-1  | i-0c067636ae1989867 | 35.181.88.225  | 10.0.0.49  | ami-0774b3849c8afac1c |
| kube-2  | i-03bb50c381dd7dbb2 | (none, stable, private only) | 10.0.0.80 | ami-0774b3849c8afac1c |
| kube-3  | i-051464136ac2626c2 | (none, stable, private only) | 10.0.0.93 | ami-0774b3849c8afac1c |

- Region: **eu-west-3**, AZ: **eu-west-3a** (all 3 nodes).
- Instance type: **t4g.medium** (Graviton / arm64).
- AMI: Amazon Linux 2023, arm64 (`al2023-ami-2023.12.20260914.0-kernel-6.18-arm64`).
- SSH user: **ec2-user** (Amazon Linux default).
- `Name` tags renamed from the AWS-assigned `ec2-group-02-node-{1,2,3}` to `kube-{1,2,3}` for consistency with this project's naming (cosmetic only, no functional change).
- `Project=kube` tag applied to all 3 instances for inventory filtering.
- Inter-node SSH (22) reachable from kube-1 to kube-2/3: **not yet verified** — instances are `stopped` and currently fail to start (`InsufficientInstanceCapacity` for t4g.medium in eu-west-3a). Re-check once the instances can be started.
- SSM connectivity: **not yet verified**, same blocker as above.

## Known blocker (2026-09-21)

`aws ec2 start-instances` fails with `InsufficientInstanceCapacity` for all 3
instances. This is an AWS-side capacity shortage for `t4g.medium` in
`eu-west-3a`, not something fixable from the client side. Mitigation: retry
periodically; escalate to module staff if it persists across multiple
attempts/days, since other groups sharing the same capacity pool are likely
affected too.
